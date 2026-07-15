#!/bin/bash
set -euo pipefail
#===============================================================================
# PaddleOCR v6 Server — 一键部署脚本
#===============================================================================
# 用法:
#   ./setup.sh             自动检测 GPU/CPU 并部署
#   ./setup.sh --gpu       强制 GPU 模式（自动检测 CUDA 版本）
#   ./setup.sh --cpu       强制 CPU 模式
#   ./setup.sh --cuda 12.4 指定 CUDA 版本（GPU 模式）
#   ./setup.sh --rebuild   强制重新构建镜像
#   ./setup.sh --down      停止并移除服务
#   ./setup.sh --help      显示帮助
#
# 示例:
#   ./setup.sh                     # RTX 4090 → GPU + CUDA 12.6
#   ./setup.sh --cuda 11.8         # RTX 3060 → GPU + CUDA 11.8
#   ./setup.sh --cpu               # 无 GPU 机器 → CPU
#===============================================================================

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${CYAN}${BOLD}[setup]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "  ${NC} $1"; }

# ── 项目根目录 ──
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# ── 默认值 ──
MODE="auto"
CUDA_VERSION=""
REBUILD=false
DOWN=false

usage() {
    cat <<EOF
${BOLD}PaddleOCR v6 Server — 一键部署脚本${NC}

${BOLD}用法:${NC}
  ./setup.sh             自动检测 GPU/CPU 并部署
  ./setup.sh --gpu       强制 GPU 模式（自动检测 CUDA 版本）
  ./setup.sh --cpu       强制 CPU 模式
  ./setup.sh --cuda X    指定 CUDA 版本: 11.8 / 12.1 / 12.4 / 12.6
  ./setup.sh --rebuild   强制重新构建镜像
  ./setup.sh --down      停止并移除所有服务
  ./setup.sh --help      显示帮助

${BOLD}示例:${NC}
  ./setup.sh                     # RTX 4090 → GPU + CUDA 12.6
  ./setup.sh --cuda 11.8         # RTX 3060 → GPU + CUDA 11.8
  ./setup.sh --cpu               # 无 GPU 服务器 → CPU

${BOLD}环境变量（可选）:${NC}
  PUBLIC_URL_BASE       文件上传服务外部访问地址
                         默认: http://<服务器IP>:8091
  API_KEYS              MCP Server 认证密钥（逗号分隔）
                         默认: sk-paddleocr-local
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu)    MODE="gpu"; shift ;;
        --cpu)    MODE="cpu"; shift ;;
        --cuda)   CUDA_VERSION="$2"; MODE="gpu"; shift 2 ;;
        --rebuild) REBUILD=true; shift ;;
        --down)   DOWN=true; shift ;;
        --help|-h) usage ;;
        *) err "未知参数: $1。使用 --help 查看帮助" ;;
    esac
done

# ╔══════════════════════════════════════════════════════════╗
# ║  Banner                                                  ║
# ╚══════════════════════════════════════════════════════════╝
cat << "EOF"

   ____       _      _          ____ ___ ___  ___  ___
  |  _ \ __ _| | ___| |__      / ___/ _ \| _ )/ _ \| _ \
  | |_) / _` | |/ _ \ '_ \    | |  | | | | _ \ | | |   /
  |  __/ (_| | |  __/ | | |   | |__| |_| | |_) |_| | |\ \
  |_|__ \__,_|_|\___|_| |_|___\____\___/|____/\___/|_| \_\
  | _ \__ _| |_| |_ ___ _ __ (_)_  _(_)___ _ _| |
  |  _/ _` | ' \  _/ -_) '  \| | || | / _ \ '_|_|
  |_| \__,_|_||_\__\___|_|_|_|_|\_,_|_\___/_| (_)

EOF

echo -e "${CYAN}${BOLD}  PaddleOCR v6 Server — 一键部署${NC}"
echo ""

# ╔══════════════════════════════════════════════════════════╗
# ║  1. 环境检测                                              ║
# ╚══════════════════════════════════════════════════════════╝
echo -e "${BOLD}── 1. 环境检测 ──${NC}"

# ── Docker ──
command -v docker >/dev/null 2>&1 \
    || err "Docker 未安装。请先安装: https://docs.docker.com/engine/install/"
DOCKER_VER=$(docker --version 2>&1 | sed 's/Docker version //; s/, build.*//')
ok "Docker: ${DOCKER_VER}"

# ── Docker Compose ──
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    COMPOSE_VER=$(docker compose version 2>&1 | grep -oP 'version \K\S+' || docker compose version 2>&1)
    ok "Compose: ${COMPOSE_VER}"
elif docker-compose --version >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    COMPOSE_VER=$(docker-compose --version | grep -oP 'version \K\S+')
    ok "Compose: ${COMPOSE_VER}"
else
    err "Docker Compose 未安装"
fi

# ── 系统架构 ──
ARCH=$(uname -m)
log "架构: ${ARCH}"
case "$ARCH" in
    x86_64)  ok "x86_64 — 完全支持" ;;
    aarch64|arm64)
        warn "ARM64 检测: Docker 无法直通 GPU，将使用 CPU 模式"
        [ "$MODE" != "cpu" ] && warn "如使用 Mac Apple Silicon，请确保 Docker Desktop 已安装"
        MODE="cpu"
        ;;
    *) warn "未知架构: ${ARCH}，可能不兼容，仅支持 CPU 模式" ;;
esac

# ╔══════════════════════════════════════════════════════════╗
# ║  2. 硬件检测 & 模式选择                                    ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 2. 硬件检测 ──${NC}"

# ── GPU 检测函数 ──
detect_nvidia_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then return 1; fi
    local info
    info=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1) || return 1
    [ -z "$info" ] && return 1
    echo "$info"
}

detect_cuda_version() {
    nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || true
}

# ── 确定模式 ──
GPU_INFO=""
DETECTED_CUDA=""

if [ "$MODE" = "gpu" ] || [ "$MODE" = "auto" ]; then
    GPU_INFO=$(detect_nvidia_gpu || true)
    if [ -n "$GPU_INFO" ]; then
        MODE="gpu"
        DETECTED_CUDA=$(detect_cuda_version)
        log "GPU: ${GPU_INFO}"
        [ -n "$DETECTED_CUDA" ] && log "CUDA: ${DETECTED_CUDA}"

        # 优先 CLI 指定的 CUDA 版本，否则用检测到的
        [ -z "$CUDA_VERSION" ] && CUDA_VERSION="$DETECTED_CUDA"
        [ -z "$CUDA_VERSION" ] && CUDA_VERSION="12.6"

        ok "GPU 模式 · CUDA ${CUDA_VERSION}"
    elif [ "$MODE" = "gpu" ]; then
        err "指定了 --gpu 但未检测到 NVIDIA GPU（nvidia-smi 不可用）"
    else
        MODE="cpu"
        ok "CPU 模式（未检测到 NVIDIA GPU）"
    fi
fi

# ── CUDA → 基础镜像 / wheel 频道 映射表 ──
declare -A CUDA_IMAGE_MAP CUDA_CHANNEL_MAP
CUDA_IMAGE_MAP=(
    [11.8]="nvidia/cuda:11.8.0-runtime-ubuntu22.04"
    [12.1]="nvidia/cuda:12.1.0-runtime-ubuntu22.04"
    [12.4]="nvidia/cuda:12.4.1-runtime-ubuntu22.04"
    [12.6]="nvidia/cuda:12.6.3-runtime-ubuntu22.04"
)
CUDA_CHANNEL_MAP=(
    [11.8]=cu118
    [12.1]=cu121
    [12.4]=cu124
    [12.6]=cu126
)

# ╔══════════════════════════════════════════════════════════╗
# ║  3. GPU 模式: nvidia 容器运行时检查                        ║
# ╚══════════════════════════════════════════════════════════╝
if [ "$MODE" = "gpu" ]; then
    echo ""
    echo -e "${BOLD}── 3. GPU 运行时检查 ──${NC}"

    NCT_PKG=false
    NCT_OK=false

    # 检查 nvidia-container-toolkit 包是否安装
    if command -v nvidia-ctk &>/dev/null; then
        NCT_PKG=true
    elif dpkg -l nvidia-container-toolkit &>/dev/null 2>&1; then
        NCT_PKG=true
    elif rpm -q nvidia-container-toolkit &>/dev/null 2>&1; then
        NCT_PKG=true
    fi

    # 真正验证：Docker 是否已注册 nvidia 运行时
    if docker info 2>&1 | grep -q "Runtimes:.*nvidia"; then
        NCT_OK=true
    fi

    if [ "$NCT_OK" = true ]; then
        ok "nvidia 运行时已就绪"
    elif [ "$NCT_PKG" = true ]; then
        warn "nvidia-container-toolkit 已安装，但 Docker 尚未注册 nvidia 运行时"
        warn "原因通常是安装后未重启 Docker"
        echo ""
        read -r -p "  是否自动重启 Docker？ [Y/n] " restart_docker
        if [[ ! "$restart_docker" =~ ^[Nn]$ ]]; then
            log "重启 Docker..."
            sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true
            sleep 3
            if docker info 2>&1 | grep -q "Runtimes:.*nvidia"; then
                ok "Docker 已重启，nvidia 运行时已就绪"
                NCT_OK=true
            else
                err "重启 Docker 后 nvidia 运行时仍未生效，请手动检查后重试"
            fi
        else
            err "请手动执行 sudo systemctl restart docker 后重新运行 ./setup.sh"
        fi
        # NCT_OK 如果仍为 false 走不到这里，上面已 err 退出
    else
        warn "nvidia-container-toolkit 未安装，GPU 容器无法使用"
        echo ""
        # apt 系系统 → 一键安装
        if command -v apt-get &>/dev/null; then
            read -r -p "  是否自动安装 nvidia-container-toolkit 并重启 Docker？ [Y/n] " do_install
            if [[ ! "$do_install" =~ ^[Nn]$ ]]; then
                log "添加 NVIDIA 容器仓库..."
                curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
                distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
                curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
                    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null || true
                log "安装 nvidia-container-toolkit..."
                sudo apt-get update -y -qq && sudo apt-get install -y -qq nvidia-container-toolkit
                log "重启 Docker..."
                sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true
                sleep 3
                if docker info 2>&1 | grep -q "Runtimes:.*nvidia"; then
                    ok "安装完成，nvidia 运行时已就绪"
                    NCT_OK=true
                else
                    err "安装完成但 nvidia 运行时未生效，请手动执行 sudo systemctl restart docker 后重试"
                fi
            else
                err "请手动安装 nvidia-container-toolkit 后重新运行 ./setup.sh"
            fi
        else
            echo "  ${BOLD}请根据你的发行版安装 nvidia-container-toolkit:${NC}"
            echo ""
            echo "  Ubuntu/Debian:"
            echo "    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \\"
            echo "      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
            echo "    distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)"
            echo "    curl -fsSL https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list \\"
            echo "      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \\"
            echo "      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
            echo "    sudo apt-get update -y && sudo apt-get install -y nvidia-container-toolkit"
            echo "    sudo systemctl restart docker"
            echo ""
            echo "  CentOS/RHEL:"
            echo "    sudo yum install -y nvidia-container-toolkit"
            echo "    sudo systemctl restart docker"
            echo ""
            err "安装完成后重新运行 ./setup.sh"
        fi
    fi
fi

# ╔══════════════════════════════════════════════════════════╗
# ║  4. 配置生成                                               ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 4. 配置生成 ──${NC}"

ENV_FILE="$PROJECT_DIR/.env"

# ── 自动获取本机 IP ──
detect_ip() {
    if [ -n "${PUBLIC_URL_BASE:-}" ]; then
        echo "$PUBLIC_URL_BASE"
        return
    fi
    if [ -f "$ENV_FILE" ]; then
        local existing
        existing=$(grep -oP '^PUBLIC_URL_BASE=\K.*' "$ENV_FILE" 2>/dev/null || true)
        [ -n "$existing" ] && echo "$existing" && return
    fi
    local ip
    ip=$(ip route get 1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo "http://${ip}:8091"
}

# ── 生成 .env（保留已有值） ──
generate_env() {
    local mode="${MODE}"
    local cuda_ver="${CUDA_VERSION:-12.6}"
    local wheel_ch="${CUDA_CHANNEL_MAP[$cuda_ver]:-cu126}"
    local dockerfile="docker/Dockerfile.gpu"

    [ "$mode" = "cpu" ] && dockerfile="docker/Dockerfile.cpu"

    # 读取现有 .env 中的值
    local existing_public_url=""
    local existing_api_keys=""
    if [ -f "$ENV_FILE" ]; then
        existing_public_url=$(grep -oP '^PUBLIC_URL_BASE=\K.*' "$ENV_FILE" 2>/dev/null || true)
        existing_api_keys=$(grep -oP '^API_KEYS=\K.*' "$ENV_FILE" 2>/dev/null || true)
    fi

    local pub_url="${existing_public_url:-$(detect_ip)}"
    local api_keys="${existing_api_keys:-sk-paddleocr-local}"

    cat > "$ENV_FILE" <<ENVEOF
# ═══════════════════════════════════════════════════════════
# PaddleOCR v6 Server — 环境配置
# 自动生成 by setup.sh | 模式: ${mode} | CUDA: ${cuda_ver}
# ═══════════════════════════════════════════════════════════

# 部署模式（由 setup.sh 管理，请勿手动修改）
PADDLE_DOCKERFILE=${dockerfile}
PADDLE_OCR_DEVICE=${mode}
PADDLE_WHEEL_CHANNEL=${wheel_ch}
CUDA_VERSION=${cuda_ver}

# API 认证密钥（逗号分隔可配置多个）
API_KEYS=${api_keys}

# 文件上传服务外部访问地址（LLM 调用上传时使用的地址）
PUBLIC_URL_BASE=${pub_url}
ENVEOF
    ok ".env 已生成 (模式: ${mode})"
}

generate_env

# ── GPU 模式: 生成 docker-compose.override.yml ──
OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"

if [ "$MODE" = "gpu" ]; then
    cat > "$OVERRIDE_FILE" <<YAMLEOF
# ═══════════════════════════════════════════════════════════
# GPU 模式 Override — 自动生成 by setup.sh
# 仅在 GPU 模式下启用 NVIDIA 容器运行时
# ═══════════════════════════════════════════════════════════

services:
  paddleocr:
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - CUDA_VISIBLE_DEVICES=0
      - ENABLE_HPI=true
      - USE_TENSORRT=true
      - TRT_PRECISION=fp16
YAMLEOF
    ok "docker-compose.override.yml 已生成 (GPU runtime)"
else
    if [ -f "$OVERRIDE_FILE" ]; then
        rm -f "$OVERRIDE_FILE"
        ok "已移除 GPU override 配置"
    fi
fi

# ╔══════════════════════════════════════════════════════════╗
# ║  5. 停止已有服务                                            ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 5. 服务管理 ──${NC}"

if [ "$DOWN" = true ]; then
    log "正在停止并移除服务..."
    $COMPOSE_CMD -f docker-compose.yml down 2>/dev/null || true
    if [ -f "$OVERRIDE_FILE" ]; then
        $COMPOSE_CMD -f docker-compose.yml -f "$OVERRIDE_FILE" down 2>/dev/null || true
    fi
    rm -f "$OVERRIDE_FILE"
    ok "所有服务已停止并移除"
    exit 0
fi

# 检查是否有正在运行的容器
RUNNING_CONTAINERS=$($COMPOSE_CMD ps -q 2>/dev/null || true)
if [ -n "$RUNNING_CONTAINERS" ]; then
    warn "已有服务在运行"
    read -r -p "  是否重新部署（将重启服务）？ [y/N] " redeploy
    if [[ "$redeploy" =~ ^[Yy]$ ]]; then
        log "停止已有服务..."
        $COMPOSE_CMD -f docker-compose.yml down 2>/dev/null || true
        if [ -f "$OVERRIDE_FILE" ]; then
            $COMPOSE_CMD -f docker-compose.yml -f "$OVERRIDE_FILE" down 2>/dev/null || true
        fi
        ok "已停止"
    else
        err "已取消"
    fi
fi

# ╔══════════════════════════════════════════════════════════╗
# ║  6. 构建镜像                                               ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 6. 构建镜像 ──${NC}"

BUILD_ARGS=()

if [ "$MODE" = "gpu" ] && [ -n "${CUDA_VERSION:-}" ]; then
    base_image="${CUDA_IMAGE_MAP[$CUDA_VERSION]:-}"
    wheel_ch="${CUDA_CHANNEL_MAP[$CUDA_VERSION]:-cu126}"
    if [ -n "$base_image" ]; then
        BUILD_ARGS+=(--build-arg "BASE_IMAGE=${base_image}")
        BUILD_ARGS+=(--build-arg "PADDLE_WHEEL_CHANNEL=${wheel_ch}")
        log "基础镜像: ${base_image}"
        log "Paddle 频道: ${wheel_ch}"
    else
        # CUDA 版本超出映射表，用最接近的兼容版本
        warn "CUDA ${CUDA_VERSION} 不在预设映射表中，尝试 cu126 兼容版本"
        BUILD_ARGS+=(--build-arg "BASE_IMAGE=nvidia/cuda:12.6.3-runtime-ubuntu22.04")
        BUILD_ARGS+=(--build-arg "PADDLE_WHEEL_CHANNEL=cu126")
        log "基础镜像: nvidia/cuda:12.6.3-runtime-ubuntu22.04 (兼容回退)"
        log "Paddle 频道: cu126 (兼容回退)"
    fi
fi

if [ "$REBUILD" = true ]; then
    log "强制重新构建（--rebuild）..."
    $COMPOSE_CMD build --no-cache "${BUILD_ARGS[@]}"
else
    log "构建镜像中..."
    $COMPOSE_CMD build "${BUILD_ARGS[@]}"
fi
ok "镜像构建完成"

# ╔══════════════════════════════════════════════════════════╗
# ║  7. 启动服务                                               ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 7. 启动服务 ──${NC}"

if [ -f "$OVERRIDE_FILE" ]; then
    $COMPOSE_CMD -f docker-compose.yml -f "$OVERRIDE_FILE" up -d
else
    $COMPOSE_CMD up -d
fi
ok "服务已启动"

# ╔══════════════════════════════════════════════════════════╗
# ║  8. 健康检查                                               ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${BOLD}── 8. 健康检查 ──${NC}"

MAX_RETRIES=30
WAIT_SECONDS=2
HEALTHY=false

for i in $(seq 1 $MAX_RETRIES); do
    if $COMPOSE_CMD ps 2>/dev/null | grep -q "paddleocr-v6.*Up"; then
        HEALTHY=true
        break
    fi
    if [ $((i % 5)) -eq 0 ]; then
        log "等待服务启动... (${i}/${MAX_RETRIES})"
        $COMPOSE_CMD logs --tail=5 paddleocr 2>/dev/null || true
    fi
    sleep $WAIT_SECONDS
done

if [ "$HEALTHY" = true ]; then
    ok "PaddleOCR v6 MCP Server 运行中"
else
    warn "服务仍在启动中（超时），请手动检查:"
    info "$COMPOSE_CMD logs paddleocr"
fi

# ╔══════════════════════════════════════════════════════════╗
# ║  9. 部署信息输出                                           ║
# ╚══════════════════════════════════════════════════════════╝
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  部署完成                                        ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

SERVER_IP=$(detect_ip | sed 's|http://||;s|:8091||')

cat <<STATUS
${BOLD}服务状态${NC}

  MCP Server（OCR 推理）
    地址:         http://0.0.0.0:8090
    外部访问:     http://${SERVER_IP}:8090

  文件上传服务
    地址:         http://0.0.0.0:8091
    上传接口:     POST http://${SERVER_IP}:8091/upload
    健康检查:     GET  http://${SERVER_IP}:8091/health

${BOLD}常用命令${NC}

  查看日志:       ${COMPOSE_CMD} logs -f paddleocr
  重启服务:       ${COMPOSE_CMD} restart paddleocr
  停止服务:       ${COMPOSE_CMD} down
  重新构建:       ./setup.sh --rebuild

${BOLD}上传测试${NC}

  curl -X POST http://${SERVER_IP}:8091/upload \\
    -F "file=@test.png"

  将返回的 local_path 传给 MCP 的 ocr 工具即可。

STATUS

# ── GPU 信息 ──
if [ "$MODE" = "gpu" ]; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
    echo -e "  ${BOLD}GPU${NC}         ${GPU_NAME:-N/A} · ${GPU_MEM:-N/A}"
    echo ""
fi

log "部署完成！"
