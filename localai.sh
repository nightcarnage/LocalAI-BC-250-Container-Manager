#!/usr/bin/env bash
set -euo pipefail

################################################################################
# LOCALAI FEDERATION MANAGER
# Professional Release Version
################################################################################

# --- DYNAMIC HOST DISCOVERY ---
if [ -f /etc/os-release ]; then
    source /etc/os-release
    HOST_VERSION="${VERSION_ID}" 
else
    HOST_VERSION="43"
fi

BASE_IMAGE="fedora:${HOST_VERSION}"

# --- CONFIGURATION ---
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="localai-federated-matched:latest"
LOCALAI_VERSION="v3.9.0"

MASTER_ID="${APP_DIR}/.master_node_id"
FED_ID="${APP_DIR}/.fed_node_id"
WORKER_ID="${APP_DIR}/.worker_node_id"

# ATTENTION: The TOKEN/API_KEY below is static.
# This is intended for local development and private networks.
# Do NOT deploy this container to a public-facing IP without changing this 
# or implementing external auth.
RAW_TOKEN=$(cat <<EOF
b3RwOgogIGRodDoKICAgIGludGVydmFsOiAzNjAKICAgIGtleTogWEp4VGRjWmhadk94eG5Sb3UwNU42OHlsS1Q5UE5mTDdsYTJEZHI1QlhVUgogICAgbGVuZ3RoOiA0MwogIGNyeXB0bzoKICAgIGludGVydmFsOiA5MDAwCiAgICBrZXk6IHpwOUdtbmZ3UERhTVZvZUxrQmNYQ1ZQSnVWMzVLdlV6aGhYemhub2lFdU8KICAgIGxlbmd0aDogNDMKcm9vbTogRDBZNkNscWtqRFZqNjdVNXNXc3BmQU9BcENpUkUzQlJnZFJVS0xoRTJwTwpyZW5kZXp2b3VzOiBZOUxzZzBGV3BWcjVZSFRSaFgxeGxaSTVYcGxoUnVxWkpJaDM0M0lLazJCCm1kbnM6IHdqa2Y4aGhQdjlLRlpBQ1RsUDFNaTdVdEppd3BjVUNaOTg0bzdZaXluTWYKbWF4X21lc3NhZ2Vfc2l6ZTogMjA5NzE1MjAK
EOF
)
STATIC_TOKEN=$(echo "$RAW_TOKEN" | tr -d '\n ')

MODELS_DIR="${APP_DIR}/models"
BACKENDS_DIR="${APP_DIR}/backends"
mkdir -p "${MODELS_DIR}" "${BACKENDS_DIR}"

# --- HELPERS ---

get_node_name() {
    local ID_FILE="$1"
    local PREFIX="$2"
    if [ ! -f "$ID_FILE" ]; then
        local SUFFIX=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
        local NEW_NAME="${PREFIX}-$(hostname)-${SUFFIX}"
        echo "$NEW_NAME" > "$ID_FILE"
    fi
    cat "$ID_FILE"
}

build_image() {
    if [[ "$(podman images -q ${IMAGE_NAME} 2> /dev/null)" == "" ]]; then
        echo "[*] Building container image..."
        cat > Containerfile <<EOF
FROM ${BASE_IMAGE}
RUN dnf -y upgrade --refresh && \\
    dnf -y install ca-certificates curl jq tar gzip mesa-vulkan-drivers \\
    vulkan-loader vulkan-tools mesa-dri-drivers libdrm pciutils procps-ng findutils which \\
    && dnf clean all
RUN set -eux; \\
    arch="\$(uname -m)"; \\
    [ "\$arch" = "x86_64" ] && la_arch="amd64" || la_arch="arm64"; \\
    url="https://github.com/mudler/LocalAI/releases/download/${LOCALAI_VERSION}/local-ai-${LOCALAI_VERSION}-linux-\${la_arch}"; \\
    mkdir -p /opt/localai; \\
    curl -fL "\$url" -o /opt/localai/local-ai; \\
    chmod +x /opt/localai/local-ai
ENV MODELS_PATH=/models LOCALAI_BACKENDS_PATH=/backends XDG_RUNTIME_DIR=/tmp \\
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.x86_64.json \\
    LOCALAI_FORCE_META_BACKEND_CAPABILITY=vulkan LOCALAI_P2P=true
WORKDIR /opt/localai
RUN printf '#!/bin/bash\nrm -rf /backends/vulkan-llama-cpp/lib\nexec /opt/localai/local-ai "\$@"\n' > /entrypoint.sh && chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF
        podman build -t "${IMAGE_NAME}" -f Containerfile .
    fi
}

# --- COMMAND LOGIC ---

run_install() {
    echo "[!] Applying Network Tuning and Hardened Firewall Rules..."
    echo "net.core.rmem_max=7500000" | sudo tee /etc/sysctl.d/10-localai-p2p.conf
    echo "net.core.wmem_max=7500000" | sudo tee -a /etc/sysctl.d/10-localai-p2p.conf
    sudo sysctl --system
    sudo setsebool -P container_use_devices true 2>/dev/null || true

    if command -v firewall-cmd &> /dev/null; then
        echo "[*] Opening firewall..."
        sudo firewall-cmd --permanent --add-port={8080-8081/tcp,4001/tcp,4001/udp,12345-12346/tcp,3000/tcp,8000/tcp}
        sudo firewall-cmd --permanent --add-service={mdns,llmnr}
        sudo firewall-cmd --reload
    fi
    build_image
}

run_master() {
    build_image
    local NAME="localai"
    local NODE_ID=$(get_node_name "$MASTER_ID" "master")
    echo "[*] Launching Master Node: $NODE_ID"
    podman run --replace -d --name "$NAME" --net host --restart always --device /dev/dri \
      --group-add keep-groups --security-opt label=disable \
      -e LOCALAI_P2P_TOKEN="${STATIC_TOKEN}" \
      -e FEDERATED_SERVER_NAME="$NODE_ID" \
      -v "${MODELS_DIR}:/models:Z" -v "${BACKENDS_DIR}:/backends:Z" \
      "${IMAGE_NAME}" run --address 0.0.0.0:8080 --p2p
}

run_fed() {
    build_image
    local NAME="localai-fed"
    local NODE_ID=$(get_node_name "$FED_ID" "fed")
    echo "[*] Launching Federated Node: $NODE_ID"
    podman run --replace -d --name "$NAME" --net host --restart always --device /dev/dri \
      --group-add keep-groups --security-opt label=disable \
      -e LOCALAI_P2P_TOKEN="${STATIC_TOKEN}" \
      -e FEDERATED_SERVER_NAME="$NODE_ID" \
      -v "${MODELS_DIR}:/models:Z" -v "${BACKENDS_DIR}:/backends:Z" \
      "${IMAGE_NAME}" run --address 0.0.0.0:8081 --p2p --federated
}

run_worker() {
    build_image
    local NAME="localai-worker"
    local NODE_ID=$(get_node_name "$WORKER_ID" "worker")
    echo "[*] Launching Worker Node: $NODE_ID"
    podman run --replace -d --name "$NAME" --net host --restart always --device /dev/dri \
      --group-add keep-groups --security-opt label=disable \
      -e LOCALAI_P2P_TOKEN="${STATIC_TOKEN}" \
      -e FEDERATED_SERVER_NAME="$NODE_ID" \
      -e LOCALAI_RUNNER_PORT=12346 \
      -v "${MODELS_DIR}:/models:Z" -v "${BACKENDS_DIR}:/backends:Z" \
      "${IMAGE_NAME}" worker p2p-llama-cpp-rpc --runner-port 12346
}

run_stop() {
    local TARGET="${1:-all}"
    case "$TARGET" in
        master) podman stop localai 2>/dev/null || true ;;
        fed)    podman stop localai-fed 2>/dev/null || true ;;
        worker) podman stop localai-worker 2>/dev/null || true ;;
        all)    podman stop $(podman ps -a --filter "name=localai" --format "{{.Names}}") 2>/dev/null || true ;;
    esac
}

run_debug() {
    local TARGET="${1:-}"
    case "$TARGET" in
        master) podman logs -f localai ;;
        fed)    podman logs -f localai-fed ;;
        worker) podman logs -f localai-worker ;;
        *) echo "Usage: $0 debug {master|fed|worker}"; exit 1 ;;
    esac
}

run_shell() {
    local TARGET="${1:-}"
    case "$TARGET" in
        master) podman exec -it localai bash ;;
        fed)    podman exec -it localai-fed bash ;;
        worker) podman exec -it localai-worker bash ;;
        *) echo "Usage: $0 shell {master|fed|worker}"; exit 1 ;;
    esac
}

# --- EXECUTION ENGINE ---

if [ $# -eq 0 ]; then
    echo "Usage: $0 {install|master|fed|worker|status|stop [target]|debug [target]|shell [target]|uninstall}"
    exit 1
fi

# We loop through all arguments. If a command needs a sub-argument (like stop worker), 
# it checks if the next argument is a valid target.
while [[ $# -gt 0 ]]; do
    case "$1" in
        install) run_install; shift ;;
        master)  run_master; shift ;;
        fed)     run_fed; shift ;;
        worker)  run_worker; shift ;;
        status)
            echo "--- Active Nodes ---"
            podman ps --filter "name=localai"
            shift ;;
        stop)
            # Check if next arg is a specific target, else default to 'all'
            if [[ ${2:-} =~ ^(master|fed|worker)$ ]]; then
                run_stop "$2"; shift 2
            else
                run_stop "all"; shift
            fi ;;
        debug)
            run_debug "${2:-}"; shift 2 ;;
        shell)
            run_shell "${2:-}"; shift 2 ;;
        uninstall)
            run_stop "all"
            podman rmi -f "${IMAGE_NAME}" 2>/dev/null || true
            rm -f "$MASTER_ID" "$FED_ID" "$WORKER_ID" Containerfile; shift ;;
        *) echo "Unknown command: $1"; exit 1 ;;
    esac
done
