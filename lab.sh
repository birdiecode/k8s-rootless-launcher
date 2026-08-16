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
START_TIMEOUT="${START_TIMEOUT:-120}"
START_NGINX="${START_NGINX:-1}"

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

require_runtime_files() {
    local file

    for file in \
        "$BIN_DIR/etcd" \
        "$BIN_DIR/kubectl" \
        "$K8S_DIR/_output/bin/kube-apiserver" \
        "$K8S_DIR/_output/bin/kube-controller-manager" \
        "$K8S_DIR/_output/bin/kubelet"; do
        [[ -x "$file" ]] || die "Нет исполняемого файла $file. Сначала выполни: $0 init"
    done

    [[ -f "$PNFROOT_DIR/pnfroot.py" ]] || die "Нет $PNFROOT_DIR/pnfroot.py"
    [[ -f "$PROXY_DIR/main.py" ]] || die "Нет $PROXY_DIR/main.py"
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
        "cd '$LAB_DIR' && exec bash -lc '$command 2>&1 | tee .state/k8s/$name.log'"
}

kubectl_lab() {
    KUBECONFIG="$LAB_DIR/.state/k8s/etc/admin.kubeconfig" \
        "$BIN_DIR/kubectl" "$@"
}

wait_until() {
    local description="$1"
    shift
    local deadline=$((SECONDS + START_TIMEOUT))

    while ! "$@" >/dev/null 2>&1; do
        (( SECONDS < deadline )) || die "Истекло время ожидания: $description"
        sleep 1
    done

    log "Готово: $description"
}

etcd_ready() {
    curl -fsS --max-time 2 http://127.0.0.1:2379/health | grep -q '"health":"true"'
}

api_ready() {
    kubectl_lab get --raw=/readyz 2>/dev/null | grep -q '^ok$'
}

runtime_ready() {
    [[ -S "$LAB_DIR/.state/k8s/run/pnfroot.sock" ]]
}

node_ready() {
    [[ "$(kubectl_lab get node node1 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

start_lab() {
    require_cmd tmux
    require_cmd curl
    check_layout
    prepare_lab
    require_runtime_files

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log "Сессия tmux '$SESSION' уже существует. Проверяю кластер."
        status_lab
        return
    fi

    mkdir -p "$LAB_DIR/.state/k8s/run"
    log "Запуск Kubernetes в tmux-сессии '$SESSION'..."

    tmux new-session \
        -d \
        -s "$SESSION" \
        -n "etcd" \
        "cd '$LAB_DIR' && exec bash -lc 'make etcd 2>&1 | tee .state/k8s/etcd.log'"

    wait_until "etcd" etcd_ready

    tmux_window "apiserver" "make apiserver"
    wait_until "kube-apiserver" api_ready

    log "Применение bootstrap RBAC и токена kube-proxy..."
    make -C "$LAB_DIR" manifest-bootstrap

    tmux_window "controller" "make controller-manager"
    tmux_window "netservice" "make netservice"
    wait_until "сетевой сервис" test -S "$LAB_DIR/.state/k8s/run/net.unix"

    tmux_window "runtime" "make runtime"
    wait_until "CRI pnfroot" runtime_ready

    tmux_window "kubelet" "make kubelet"
    wait_until "нода node1 Ready" node_ready

    tmux_window "kube-proxy" "make kube-proxy"

    if [[ "$START_NGINX" == "1" ]]; then
        log "Запуск проверочного nginx..."
        kubectl_lab apply -f "$LAB_DIR/manifests/smoke/nginx-rootless.yaml"
        kubectl_lab wait --for=condition=Ready pod/nginx-rootless \
            --timeout="${START_TIMEOUT}s"
    fi

    log "Кластер запущен."
    kubectl_lab get nodes,pods,svc -o wide
    if [[ "$START_NGINX" == "1" ]]; then
        log "nginx: http://$(hostname -I 2>/dev/null | awk '{print $1}'):30080/"
    fi
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
        if [[ -x "$BIN_DIR/kubectl" && -f "$LAB_DIR/.state/k8s/etc/admin.kubeconfig" ]]; then
            kubectl_lab get nodes,pods,svc -o wide || true
        fi
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
  $0            Запустить весь кластер и nginx одной командой
  $0 up         То же, что start
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

case "${1:-start}" in
    init)
        init_all
        ;;
    start|up)
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
