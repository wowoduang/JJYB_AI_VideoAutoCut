#!/usr/bin/env bash
# ============================================================
#  JJYB_AI智剪 v2.0 - 一键部署脚本
#  支持: Ubuntu/Debian, CentOS/RHEL/Fedora, macOS
#  用法: chmod +x deploy.sh && ./deploy.sh
# ============================================================

set -e

# -------------------- 颜色输出 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[成功]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*"; }
step()  { echo -e "\n${CYAN}===== $* =====${NC}"; }

# -------------------- 全局变量 --------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/venv"
PYTHON_CMD=""
PIP_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
APP_PORT="${APP_PORT:-5000}"
APP_HOST="${APP_HOST:-0.0.0.0}"
INSTALL_MODE="${1:-full}"   # full | basic | run
USE_GPU="${USE_GPU:-auto}"  # auto | yes | no

# -------------------- 帮助信息 --------------------
show_help() {
    echo ""
    echo "JJYB_AI智剪 v2.0 - 一键部署脚本"
    echo ""
    echo "用法: ./deploy.sh [模式] [选项]"
    echo ""
    echo "模式:"
    echo "  full    完整安装（默认）: 系统依赖 + Python依赖 + FFmpeg + 启动"
    echo "  basic   基础安装: 仅安装必需依赖（不含AI大模型库如torch）"
    echo "  run     仅启动: 跳过安装步骤，直接启动应用"
    echo ""
    echo "环境变量:"
    echo "  APP_PORT=5000      应用端口（默认5000）"
    echo "  APP_HOST=0.0.0.0   监听地址（默认0.0.0.0）"
    echo "  USE_GPU=auto       GPU支持: auto/yes/no（默认auto自动检测）"
    echo "  PIP_MIRROR=URL     pip镜像源（默认阿里云）"
    echo ""
    echo "示例:"
    echo "  ./deploy.sh                        # 完整安装并启动"
    echo "  ./deploy.sh basic                  # 仅安装基础依赖"
    echo "  ./deploy.sh run                    # 跳过安装，直接启动"
    echo "  APP_PORT=8080 ./deploy.sh          # 使用8080端口"
    echo "  USE_GPU=no ./deploy.sh             # 强制CPU模式（跳过GPU相关包）"
    echo ""
    exit 0
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
fi

# -------------------- 检测操作系统 --------------------
detect_os() {
    step "检测操作系统"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_NAME="${PRETTY_NAME}"
    elif [ "$(uname)" = "Darwin" ]; then
        OS_ID="macos"
        OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '')"
    else
        OS_ID="unknown"
        OS_NAME="$(uname -s)"
    fi
    info "操作系统: ${OS_NAME}"
}

# -------------------- 检测/安装 Python --------------------
find_python() {
    step "检测 Python"
    # 按优先级查找 Python 3.10 > 3.11 > 3.9 > 3.12 > python3 > python
    for cmd in python3.10 python3.11 python3.9 python3.12 python3 python; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local ver
            ver="$("$cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")"
            local major minor
            major="$(echo "$ver" | cut -d. -f1)"
            minor="$(echo "$ver" | cut -d. -f2)"
            if [ "$major" = "3" ] && [ "$minor" -ge 9 ] && [ "$minor" -le 12 ]; then
                PYTHON_CMD="$cmd"
                ok "找到 Python: $($cmd --version) (路径: $(command -v $cmd))"
                return 0
            fi
        fi
    done

    warn "未找到 Python 3.9-3.12，尝试自动安装..."
    install_python
}

install_python() {
    case "$OS_ID" in
        ubuntu|debian|pop|linuxmint)
            sudo apt-get update -qq
            sudo apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip
            PYTHON_CMD="python3.10"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y python3.10 python3.10-devel python3-pip
            else
                sudo yum install -y python3 python3-devel python3-pip
            fi
            PYTHON_CMD="python3.10"
            [ ! command -v python3.10 >/dev/null 2>&1 ] && PYTHON_CMD="python3"
            ;;
        macos)
            if command -v brew >/dev/null 2>&1; then
                brew install python@3.10
                PYTHON_CMD="python3.10"
            else
                err "请先安装 Homebrew (https://brew.sh) 或手动安装 Python 3.10"
                exit 1
            fi
            ;;
        *)
            err "无法自动安装 Python，请手动安装 Python 3.9-3.12"
            err "下载地址: https://www.python.org/downloads/"
            exit 1
            ;;
    esac

    if ! command -v "$PYTHON_CMD" >/dev/null 2>&1; then
        err "Python 安装失败，请手动安装"
        exit 1
    fi
    ok "Python 安装完成: $($PYTHON_CMD --version)"
}

# -------------------- 安装系统依赖 --------------------
install_system_deps() {
    step "安装系统依赖"

    case "$OS_ID" in
        ubuntu|debian|pop|linuxmint)
            info "安装系统包 (apt)..."
            sudo apt-get update -qq
            sudo apt-get install -y \
                ffmpeg \
                git \
                curl \
                build-essential \
                libsndfile1 \
                libsm6 libxext6 libxrender-dev \
                libgl1-mesa-glx \
                libglib2.0-0 \
                2>/dev/null || warn "部分系统包安装失败，可能不影响使用"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            info "安装系统包 (yum/dnf)..."
            if command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y ffmpeg git curl gcc gcc-c++ make \
                    libsndfile libSM libXext mesa-libGL glib2 \
                    2>/dev/null || warn "部分系统包安装失败"
            else
                sudo yum install -y epel-release
                sudo yum install -y ffmpeg git curl gcc gcc-c++ make \
                    libsndfile libSM libXext mesa-libGL glib2 \
                    2>/dev/null || warn "部分系统包安装失败"
            fi
            ;;
        macos)
            info "安装系统包 (brew)..."
            if command -v brew >/dev/null 2>&1; then
                brew install ffmpeg git curl libsndfile 2>/dev/null || warn "部分 brew 包安装失败"
            else
                warn "未检测到 Homebrew，跳过系统包安装"
                warn "请手动安装 FFmpeg: https://ffmpeg.org/download.html"
            fi
            ;;
        *)
            warn "未知操作系统，跳过系统依赖安装"
            warn "请确保已安装: FFmpeg, git, curl"
            ;;
    esac

    # 验证 FFmpeg
    if command -v ffmpeg >/dev/null 2>&1; then
        ok "FFmpeg 已就绪: $(ffmpeg -version 2>&1 | head -1)"
    else
        warn "FFmpeg 未安装，视频处理功能将不可用"
        warn "安装方法: https://ffmpeg.org/download.html"
    fi
}

# -------------------- 创建虚拟环境 --------------------
setup_venv() {
    step "配置 Python 虚拟环境"

    if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/python" ]; then
        info "虚拟环境已存在: ${VENV_DIR}"
    else
        info "创建虚拟环境: ${VENV_DIR}"
        "$PYTHON_CMD" -m venv "$VENV_DIR" || {
            warn "venv 创建失败，尝试安装 python3-venv 后重试..."
            case "$OS_ID" in
                ubuntu|debian|pop|linuxmint)
                    local pyver
                    pyver="$("$PYTHON_CMD" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
                    sudo apt-get install -y "python${pyver}-venv" 2>/dev/null || true
                    ;;
            esac
            "$PYTHON_CMD" -m venv "$VENV_DIR"
        }
        ok "虚拟环境创建完成"
    fi

    # 激活虚拟环境
    source "$VENV_DIR/bin/activate"
    ok "虚拟环境已激活: $(python --version)"

    # 升级 pip
    info "升级 pip..."
    pip install --upgrade pip -q -i "$PIP_MIRROR" 2>/dev/null || pip install --upgrade pip -q
}

# -------------------- 安装 Python 依赖 --------------------
install_python_deps() {
    step "安装 Python 依赖 (模式: ${INSTALL_MODE})"

    source "$VENV_DIR/bin/activate"

    if [ "$INSTALL_MODE" = "basic" ]; then
        info "基础模式: 安装核心Web依赖（不含AI大模型库）"
        pip install -q -i "$PIP_MIRROR" \
            'flask>=3.0.0' \
            'flask-socketio>=5.3.0' \
            'flask-cors>=4.0.0' \
            'python-socketio>=5.10.0' \
            'eventlet>=0.34.0' \
            'pyyaml>=6.0.0' \
            'python-dotenv>=1.0.0' \
            'requests>=2.31.0' \
            'pillow>=10.0.0' \
            'loguru>=0.7.0' \
            'psutil>=5.9.0' \
            'edge-tts>=6.1.0' \
            'pyttsx3>=2.90' \
            2>/dev/null || {
                warn "部分包通过镜像安装失败，尝试默认源..."
                pip install -q \
                    'flask>=3.0.0' 'flask-socketio>=5.3.0' 'flask-cors>=4.0.0' \
                    'python-socketio>=5.10.0' 'eventlet>=0.34.0' 'pyyaml>=6.0.0' \
                    'python-dotenv>=1.0.0' 'requests>=2.31.0' 'pillow>=10.0.0' \
                    'loguru>=0.7.0' 'psutil>=5.9.0' 'edge-tts>=6.1.0' 'pyttsx3>=2.90'
            }
    else
        info "完整模式: 安装所有依赖 (requirements.txt)"

        # GPU 检测
        local torch_extra=""
        if [ "$USE_GPU" = "auto" ]; then
            if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
                info "检测到 NVIDIA GPU，将安装 CUDA 版 PyTorch"
                torch_extra="--extra-index-url https://download.pytorch.org/whl/cu121"
            else
                info "未检测到 NVIDIA GPU，安装 CPU 版 PyTorch"
                torch_extra="--extra-index-url https://download.pytorch.org/whl/cpu"
            fi
        elif [ "$USE_GPU" = "yes" ]; then
            torch_extra="--extra-index-url https://download.pytorch.org/whl/cu121"
        else
            torch_extra="--extra-index-url https://download.pytorch.org/whl/cpu"
        fi

        # 先安装 PyTorch（单独安装以便选择CPU/GPU版本）
        info "安装 PyTorch..."
        pip install -q $torch_extra \
            'torch>=2.0.0' 'torchvision>=0.15.0' 'torchaudio>=2.0.0' \
            2>/dev/null || warn "PyTorch 安装失败，AI功能可能受限"

        # 安装其余依赖
        info "安装其他依赖..."
        pip install -q -i "$PIP_MIRROR" -r "$SCRIPT_DIR/requirements.txt" \
            2>/dev/null || {
                warn "部分包通过镜像安装失败，尝试默认源..."
                pip install -q -r "$SCRIPT_DIR/requirements.txt" 2>/dev/null || \
                    warn "部分依赖安装失败，可能不影响核心功能"
            }
    fi

    ok "Python 依赖安装完成"
}

# -------------------- 创建目录结构 --------------------
setup_directories() {
    step "创建目录结构"

    local dirs=(
        "uploads"
        "uploads/videos"
        "uploads/audios"
        "uploads/images"
        "uploads/commentary_videos"
        "output"
        "output/exports"
        "temp"
        "temp/outputs"
        "database"
        "logs"
        "models"
        "resource"
        "frontend/static/draft"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "$SCRIPT_DIR/$d"
    done

    ok "目录结构创建完成"
}

# -------------------- 初始化配置 --------------------
init_config() {
    step "检查配置文件"

    local config_file="$SCRIPT_DIR/config/config.yaml"
    if [ -f "$config_file" ]; then
        ok "配置文件已存在: config/config.yaml"
    else
        warn "配置文件不存在，创建默认配置..."
        mkdir -p "$SCRIPT_DIR/config"
        cat > "$config_file" << 'YAML'
# JJYB_AI智剪 配置文件

app:
  name: JJYB_AI智剪
  version: 2.0.0
  debug: false
  host: 0.0.0.0
  port: 5000

database:
  type: sqlite
  path: database/jjyb_ai.db

ffmpeg:
  path: ffmpeg
  threads: 4

ai:
  device: cuda  # cuda or cpu
  models_dir: models

tts:
  default_engine: pyttsx3
  voice: zh-CN-XiaoxiaoNeural
  rate: +0%
  volume: +0%

asr:
  default_engine: whisper
  model: base
  language: zh

logging:
  level: INFO
  file: logs/app.log
  max_size: 10485760  # 10MB
  backup_count: 5
YAML
        ok "默认配置文件已创建"
    fi

    # 检查 AI 配置
    local ai_config="$SCRIPT_DIR/config/ai_config.json"
    if [ -f "$ai_config" ]; then
        ok "AI配置文件已存在: config/ai_config.json"
    else
        info "创建空 AI 配置文件..."
        echo '{}' > "$ai_config"
        ok "AI配置文件已创建（请通过 Web 界面配置 API 密钥）"
    fi
}

# -------------------- 系统检查 --------------------
run_check() {
    step "运行系统检查"

    source "$VENV_DIR/bin/activate"
    cd "$SCRIPT_DIR"
    python check_system.py 2>/dev/null || warn "系统检查脚本运行失败（不影响启动）"
}

# -------------------- 生成 systemd 服务文件 --------------------
generate_systemd() {
    step "生成 systemd 服务文件（可选）"

    local service_file="$SCRIPT_DIR/jjyb-ai.service"
    local current_user
    current_user="$(whoami)"

    cat > "$service_file" << EOF
[Unit]
Description=JJYB_AI智剪 v2.0 - 智能视频剪辑工具
After=network.target

[Service]
Type=simple
User=${current_user}
WorkingDirectory=${SCRIPT_DIR}
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin
Environment=APP_HOST=${APP_HOST}
Environment=APP_PORT=${APP_PORT}
ExecStart=${VENV_DIR}/bin/python frontend/app.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    ok "systemd 服务文件已生成: jjyb-ai.service"
    info "安装为系统服务:"
    info "  sudo cp jjyb-ai.service /etc/systemd/system/"
    info "  sudo systemctl daemon-reload"
    info "  sudo systemctl enable --now jjyb-ai"
}

# -------------------- 生成 Nginx 配置 --------------------
generate_nginx_conf() {
    local nginx_file="$SCRIPT_DIR/nginx-jjyb.conf"

    cat > "$nginx_file" << 'EOF'
# JJYB_AI智剪 - Nginx 反向代理配置
# 使用方法:
#   1. 将此文件复制到 /etc/nginx/sites-available/jjyb-ai
#   2. 创建软链接: sudo ln -s /etc/nginx/sites-available/jjyb-ai /etc/nginx/sites-enabled/
#   3. 修改 server_name 为你的域名
#   4. sudo nginx -t && sudo systemctl reload nginx

upstream jjyb_backend {
    server 127.0.0.1:5000;
}

server {
    listen 80;
    server_name your-domain.com;  # 修改为你的域名

    client_max_body_size 5G;  # 允许大文件上传

    # 请求超时（视频处理可能较慢）
    proxy_connect_timeout 300;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    send_timeout 600;

    location / {
        proxy_pass http://jjyb_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 禁止缓存 API 响应
        proxy_no_cache 1;
        proxy_cache_bypass 1;
    }

    # Socket.IO WebSocket 支持
    location /socket.io/ {
        proxy_pass http://jjyb_backend/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    # 静态文件缓存
    location /static/ {
        proxy_pass http://jjyb_backend/static/;
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    ok "Nginx 配置已生成: nginx-jjyb.conf"
}

# -------------------- 启动应用 --------------------
start_app() {
    step "启动应用"

    source "$VENV_DIR/bin/activate"
    cd "$SCRIPT_DIR"

    export APP_HOST="$APP_HOST"
    export APP_PORT="$APP_PORT"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   JJYB_AI智剪 v2.0 启动中...${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    info "监听地址: ${APP_HOST}:${APP_PORT}"
    info "本地访问: http://127.0.0.1:${APP_PORT}"
    if [ "$APP_HOST" = "0.0.0.0" ]; then
        local ip
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || ip=""
        if [ -n "$ip" ]; then
            info "局域网访问: http://${ip}:${APP_PORT}"
        fi
    fi
    info "API配置页: http://127.0.0.1:${APP_PORT}/api_settings"
    echo ""
    info "按 Ctrl+C 停止服务"
    echo ""

    python frontend/app.py
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     JJYB_AI智剪 v2.0 - 一键部署脚本      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""

    detect_os

    if [ "$INSTALL_MODE" = "run" ]; then
        # 仅启动模式
        if [ ! -d "$VENV_DIR" ]; then
            err "虚拟环境不存在，请先运行 ./deploy.sh 完成安装"
            exit 1
        fi
        start_app
        return
    fi

    find_python
    install_system_deps
    setup_venv
    install_python_deps
    setup_directories
    init_config
    run_check
    generate_systemd
    generate_nginx_conf

    step "部署完成"
    echo ""
    ok "所有步骤完成！"
    echo ""
    echo -e "${CYAN}快速启动:${NC}"
    echo "  ./deploy.sh run"
    echo ""
    echo -e "${CYAN}使用 systemd 管理（后台运行）:${NC}"
    echo "  sudo cp jjyb-ai.service /etc/systemd/system/"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable --now jjyb-ai"
    echo "  sudo systemctl status jjyb-ai"
    echo ""
    echo -e "${CYAN}配置 Nginx 反向代理:${NC}"
    echo "  sudo cp nginx-jjyb.conf /etc/nginx/sites-available/jjyb-ai"
    echo "  sudo ln -s /etc/nginx/sites-available/jjyb-ai /etc/nginx/sites-enabled/"
    echo "  sudo nginx -t && sudo systemctl reload nginx"
    echo ""
    echo -e "${YELLOW}首次使用请访问 http://127.0.0.1:${APP_PORT}/api_settings 配置 AI API 密钥${NC}"
    echo ""

    # 询问是否立即启动
    read -r -p "是否立即启动应用？[Y/n] " answer
    case "$answer" in
        [nN]|[nN][oO])
            info "跳过启动。稍后可运行: ./deploy.sh run"
            ;;
        *)
            start_app
            ;;
    esac
}

main "$@"
