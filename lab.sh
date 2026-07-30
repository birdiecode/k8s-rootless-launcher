#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$ROOT_DIR/k8s-rootless-lab"
PNFROOT_DIR="$ROOT_DIR/pnfroot"
PROXY_DIR="$ROOT_DIR/pnfroot-kube-proxy"
K8S_DIR="$ROOT_DIR/kubernetes-pnf"

VENV_DIR="$ROOT_DIR/.venv"
BIN_DIR="$LAB_DIR/.local/bin"
SESSION="rlk8s"
ETCD_VERSION="${ETCD_VERSION:-3.7.1}"

log() {
    printf '\033[1;34m[rlk8s]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[rlk8s error]\033[0m %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

check_layout() {
    [[ -d "$LAB_DIR" ]] || die "Нет каталога $LAB_DIR"
    [[ -d "$PNFROOT_DIR" ]] || die "Нет каталога $PNFROOT_DIR"
    [[ -d "$PROXY_DIR" ]] || die "Нет каталога $PROXY_DIR"
    [[ -d "$K8S_DIR" ]] || die "Нет каталога $K8S_DIR"
}

init_submodules() {
    require_cmd git
    log "Инициализация и обновление submodule..."
    git -C "$ROOT_DIR" submodule sync --recursive
    git -C "$ROOT_DIR" submodule update --init --recursive
}

create_venv() {
    require_cmd python3

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "Создание virtualenv: $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi

    log "Обновление pip..."
    "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel

    log "Установка pnfroot..."
    "$VENV_DIR/bin/python" -m pip install -e "$PNFROOT_DIR"

    log "Установка pnfroot-kube-proxy..."
    if [[ -f "$PROXY_DIR/pyproject.toml" || -f "$PROXY_DIR/setup.py" ]]; then
        "$VENV_DIR/bin/python" -m pip install -e "$PROXY_DIR"
    else
        log "У pnfroot-kube-proxy нет pyproject.toml/setup.py — пропускаю pip install."
    fi
}

install_etcd() {
    require_cmd tar
    mkdir -p "$BIN_DIR"

    local machine arch archive url tmp_dir
    machine="$(uname -m)"

    case "$machine" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "Неподдерживаемая архитектура для etcd: $machine" ;;
    esac

    archive="etcd-v${ETCD_VERSION}-linux-${arch}.tar.gz"
    url="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${archive}"
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    log "Скачивание etcd v${ETCD_VERSION} для linux/${arch}..."

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --progress-bar "$url" -o "$tmp_dir/$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 -O "$tmp_dir/$archive" "$url"
    else
        die "Для скачивания etcd нужен curl или wget"
    fi

    tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"

    local extracted="$tmp_dir/etcd-v${ETCD_VERSION}-linux-${arch}"
    install -m 0755 "$extracted/etcd" "$BIN_DIR/etcd"
    install -m 0755 "$extracted/etcdctl" "$BIN_DIR/etcdctl"

    if [[ -f "$extracted/etcdutl" ]]; then
        install -m 0755 "$extracted/etcdutl" "$BIN_DIR/etcdutl"
    fi

    log "etcd установлен в $BIN_DIR"
    "$BIN_DIR/etcd" --version | head -n 1
}

build_kubernetes() {
    require_cmd make
    mkdir -p "$BIN_DIR"

    log "Сборка kubectl, kubelet и kube-controller-manager..."
    make -C "$K8S_DIR" \
        WHAT="cmd/kubectl cmd/kubelet cmd/kube-controller-manager cmd/kube-apiserver"

    cp "$K8S_DIR/_output/bin/kubectl" "$BIN_DIR/"
    cp "$K8S_DIR/_output/bin/kubelet" "$BIN_DIR/"
    cp "$K8S_DIR/_output/bin/kube-apiserver" "$BIN_DIR/"
    cp "$K8S_DIR/_output/bin/kube-controller-manager" "$BIN_DIR/"

    log "Kubernetes-бинарники скопированы в $BIN_DIR"
}

prepare_lab() {
    check_layout
    mkdir -p "$BIN_DIR"

    log "Подготовка каталогов..."
    make -C "$LAB_DIR" bootstrap

    if [[ ! -f "$LAB_DIR/.state/k8s/etc/admin.kubeconfig" ]]; then
        log "PKI ещё нет — генерирую..."
        make -C "$LAB_DIR" generate-pki
    else
        log "PKI уже существует."
    fi
}

init_all() {
    init_submodules
    check_layout
    create_venv
    prepare_lab

    if [[ ! -x "$BIN_DIR/kubelet" ||
          ! -x "$BIN_DIR/kubectl" ||
          ! -x "$BIN_DIR/kube-controller-manager" ]]; then
        build_kubernetes
    else
        log "Kubernetes-бинарники уже существуют. Сборка пропущена."
    fi

    log "Инициализация завершена."
}

tmux_window() {
    local name="$1"
    local command="$2"

    tmux new-window \
        -t "$SESSION" \
        -n "$name" \
        "cd '$LAB_DIR' && source '$VENV_DIR/bin/activate' && exec $command"
}

start_lab() {
    require_cmd tmux
    check_layout

    [[ -x "$VENV_DIR/bin/python" ]] ||
        die "Virtualenv не создан. Сначала запусти: $0 init"

    [[ -x "$BIN_DIR/etcd" ]] ||
        die "etcd не установлен. Выполни: $0 install-etcd"

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        die "Сессия tmux '$SESSION' уже запущена."
    fi

    log "Запуск стенда в tmux..."

    tmux new-session \
        -d \
        -s "$SESSION" \
        -n "etcd" \
        "cd '$LAB_DIR' && source '$VENV_DIR/bin/activate' && exec make etcd"

    tmux_window "apiserver" "make apiserver"

    log "Ожидание запуска API server..."
    sleep 3

    # manifest-bootstrap должен выполняться после запуска API server.
    tmux_window "bootstrap" "bash -lc 'sleep 2; make manifest-bootstrap; exec bash'"

    tmux_window "controller" "make controller-manager"
    tmux_window "netservice" "make netservice"
    tmux_window "runtime" "make runtime"
    tmux_window "kubelet" "make kubelet"
    tmux_window "kube-proxy" "make kube-proxy"

    log "Стенд запущен."
    log "Подключиться: tmux attach -t $SESSION"
}

stop_lab() {
    require_cmd tmux

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux kill-session -t "$SESSION"
        log "Стенд остановлен."
    else
        log "Сессия '$SESSION' не запущена."
    fi
}

status_lab() {
    require_cmd tmux

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log "Стенд запущен."
        tmux list-windows -t "$SESSION"
    else
        log "Стенд остановлен."
        return 1
    fi
}

update_all() {
    init_submodules

    log "Обновление всех submodule до веток, указанных в .gitmodules..."
    git -C "$ROOT_DIR" submodule update --remote --merge --recursive

    create_venv
    log "Submodule и Python-зависимости обновлены."
}

usage() {
    cat <<EOF
Использование:
  $0 init       Инициализировать submodule, venv, PKI и бинарники
  $0 start      Запустить стенд в tmux
  $0 stop       Остановить стенд
  $0 restart    Перезапустить стенд
  $0 status     Показать состояние tmux-сессии
  $0 attach     Подключиться к tmux
  $0 update     Обновить submodule и Python-зависимости
  $0 build-k8s  Пересобрать Kubernetes-бинарники
  $0 install-etcd [версия]  Скачать etcd в .local/bin
EOF
}

case "${1:-}" in
    init)
        init_all
        ;;
    start)
        start_lab
        ;;
    stop)
        stop_lab
        ;;
    restart)
        stop_lab
        start_lab
        ;;
    status)
        status_lab
        ;;
    attach)
        require_cmd tmux
        exec tmux attach -t "$SESSION"
        ;;
    update)
        update_all
        ;;
    build-k8s)
        check_layout
        build_kubernetes
        ;;
    install-etcd)
        if [[ -n "${2:-}" ]]; then
            ETCD_VERSION="$2"
        fi
        install_etcd
        ;;
    *)
        usage
        exit 1
        ;;
esac
