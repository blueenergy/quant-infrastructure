#!/bin/bash
#####################################################################
# Quant Trading System - Server Initialization Script
#
# 用途：在新机器上一键配置用户、目录、权限和基础环境
# 
# 使用方法：
#   sudo bash setup-server.sh
#
# 功能：
#   1. 创建 shuyolin 用户和组
#   2. 配置 sudo 权限
#   3. 创建项目目录结构
#   4. 设置文件权限
#   5. 安装基础依赖
#   6. 配置防火墙
#   7. 安装 Docker (可选)
#
#####################################################################

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        echo "使用方法: sudo bash $0"
        exit 1
    fi
}

# 配置变量
USERNAME="shuyolin"
USERGROUP="shuyolin"
USER_HOME="/home/${USERNAME}"
TRADING_ROOT="${USER_HOME}/trading"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Quant Trading System 服务器初始化  ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "配置信息："
echo "  用户名: ${USERNAME}"
echo "  用户组: ${USERGROUP}"
echo "  主目录: ${USER_HOME}"
echo "  项目目录: ${TRADING_ROOT}"
echo ""
read -p "确认开始初始化? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warning "用户取消操作"
    exit 0
fi

# ========================
# 1. 创建用户和组
# ========================
log_info "步骤 1/8: 创建用户和组..."

if id "${USERNAME}" &>/dev/null; then
    log_warning "用户 ${USERNAME} 已存在，跳过创建"
else
    # 创建用户组
    if getent group "${USERGROUP}" > /dev/null 2>&1; then
        log_warning "组 ${USERGROUP} 已存在"
    else
        groupadd "${USERGROUP}"
        log_success "创建组: ${USERGROUP}"
    fi
    
    # 创建用户
    useradd -m -g "${USERGROUP}" -s /bin/bash "${USERNAME}"
    log_success "创建用户: ${USERNAME}"
    
    # 设置密码
    echo "请为用户 ${USERNAME} 设置密码："
    passwd "${USERNAME}"
fi

# ========================
# 2. 配置 sudo 权限
# ========================
log_info "步骤 2/8: 配置 sudo 权限..."

SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"
if [ ! -f "${SUDOERS_FILE}" ]; then
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    log_success "已添加 sudo 权限"
else
    log_warning "sudo 配置已存在"
fi

# ========================
# 3. 创建项目目录结构
# ========================
log_info "步骤 3/8: 创建项目目录结构..."

DIRECTORIES=(
    "${TRADING_ROOT}"
    "${TRADING_ROOT}/quant-strategy-manager"
    "${TRADING_ROOT}/vnpy-live-trading"
    "${TRADING_ROOT}/vnpy-live-trading/logs"
    "${TRADING_ROOT}/vnpy-live-trading/logs/workers"
    "${TRADING_ROOT}/quantFinance"
    "${TRADING_ROOT}/quantFinance-dashboard"
    "${TRADING_ROOT}/quant-infrastructure"
    "${TRADING_ROOT}/data"
    "${TRADING_ROOT}/backups"
)

for dir in "${DIRECTORIES[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_success "创建目录: $dir"
    else
        log_warning "目录已存在: $dir"
    fi
done

# ========================
# 4. 设置目录权限
# ========================
log_info "步骤 4/8: 设置目录权限..."

chown -R "${USERNAME}:${USERGROUP}" "${USER_HOME}"
chmod 755 "${USER_HOME}"
chmod 755 "${TRADING_ROOT}"
chmod 755 "${TRADING_ROOT}/vnpy-live-trading/logs"
chmod 755 "${TRADING_ROOT}/vnpy-live-trading/logs/workers"

log_success "权限设置完成"

# ========================
# 5. 安装基础依赖
# ========================
log_info "步骤 5/8: 检测操作系统并安装基础依赖..."

# 检测操作系统
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    log_error "无法检测操作系统"
    exit 1
fi

log_info "检测到系统: ${OS} ${VERSION}"

case "$OS" in
    rocky|rhel|centos|fedora)
        log_info "安装 Rocky Linux/RHEL/CentOS 依赖..."
        dnf install -y epel-release || yum install -y epel-release
        dnf install -y \
            python3 \
            python3-pip \
            python3-devel \
            git \
            vim \
            wget \
            curl \
            gcc \
            gcc-c++ \
            make \
            tar \
            bzip2 \
            || yum install -y \
            python3 \
            python3-pip \
            python3-devel \
            git \
            vim \
            wget \
            curl \
            gcc \
            gcc-c++ \
            make \
            tar \
            bzip2
        ;;
    ubuntu|debian)
        log_info "安装 Ubuntu/Debian 依赖..."
        apt-get update
        apt-get install -y \
            python3 \
            python3-pip \
            python3-venv \
            python3-dev \
            git \
            vim \
            wget \
            curl \
            build-essential \
            tar \
            bzip2
        ;;
    *)
        log_warning "未识别的操作系统: ${OS}"
        log_warning "请手动安装: python3, pip, git, gcc, make"
        ;;
esac

log_success "基础依赖安装完成"

# ========================
# 6. 配置防火墙
# ========================
log_info "步骤 6/8: 配置防火墙..."

if command -v firewall-cmd &> /dev/null; then
    log_info "检测到 firewalld，配置端口..."
    
    # MongoDB
    firewall-cmd --permanent --add-port=27017/tcp || log_warning "MongoDB 端口配置失败"
    
    # Redis
    firewall-cmd --permanent --add-port=6379/tcp || log_warning "Redis 端口配置失败"
    
    # API Server
    firewall-cmd --permanent --add-port=5000/tcp || log_warning "API Server 端口配置失败"
    
    # FastAPI Gateway
    firewall-cmd --permanent --add-port=3001/tcp || log_warning "FastAPI 端口配置失败"
    
    # Dashboard
    firewall-cmd --permanent --add-port=5173/tcp || log_warning "Dashboard 端口配置失败"
    
    firewall-cmd --reload || log_warning "防火墙重载失败"
    
    log_success "防火墙配置完成"
elif command -v ufw &> /dev/null; then
    log_info "检测到 ufw，配置端口..."
    
    ufw allow 27017/tcp comment 'MongoDB'
    ufw allow 6379/tcp comment 'Redis'
    ufw allow 5000/tcp comment 'API Server'
    ufw allow 3001/tcp comment 'FastAPI Gateway'
    ufw allow 5173/tcp comment 'Dashboard'
    
    log_success "防火墙配置完成"
else
    log_warning "未检测到防火墙工具，请手动配置"
fi

# ========================
# 7. 安装 Docker (可选)
# ========================
log_info "步骤 7/8: Docker 安装 (可选)..."

read -p "是否安装 Docker? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v docker &> /dev/null; then
        log_warning "Docker 已安装"
    else
        log_info "安装 Docker..."
        
        case "$OS" in
            rocky|rhel|centos)
                dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || \
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || \
                yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                ;;
            ubuntu|debian)
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh
                rm get-docker.sh
                ;;
        esac
        
        # 启动 Docker
        systemctl enable docker
        systemctl start docker
        
        # 添加用户到 docker 组
        usermod -aG docker "${USERNAME}"
        
        log_success "Docker 安装完成"
    fi
else
    log_info "跳过 Docker 安装"
fi

# ========================
# 8. 创建快速启动脚本
# ========================
log_info "步骤 8/8: 创建快速启动脚本..."

# 创建环境激活脚本
cat > "${USER_HOME}/activate-vnpy.sh" << 'EOF'
#!/bin/bash
# 快速激活 vnpy 环境
cd ~/trading/vnpy-live-trading
source .venv/bin/activate
echo "✓ vnpy 环境已激活"
echo "Python: $(which python)"
echo "当前目录: $(pwd)"
EOF

chmod +x "${USER_HOME}/activate-vnpy.sh"
chown "${USERNAME}:${USERGROUP}" "${USER_HOME}/activate-vnpy.sh"

# 创建服务启动脚本
cat > "${USER_HOME}/start-services.sh" << 'EOF'
#!/bin/bash
# 启动所有服务

echo "启动基础设施服务..."
cd ~/trading/quant-infrastructure
docker compose up -d mongodb redis

echo ""
echo "等待 MongoDB 就绪..."
sleep 10

echo ""
echo "启动 Worker API Server..."
cd ~/trading/quant-strategy-manager
./start_api_server.sh &

echo ""
echo "启动 FastAPI Gateway..."
cd ~/trading/quantFinance
export REMOTE_WORKER_API="http://localhost:5000/api/workers"
uvicorn main:app --host 0.0.0.0 --port 3001 &

echo ""
echo "启动 Dashboard..."
cd ~/trading/quantFinance-dashboard
npm run dev &

echo ""
echo "✓ 所有服务已启动"
echo ""
echo "访问地址："
echo "  - Dashboard: http://localhost:5173"
echo "  - API Gateway: http://localhost:3001"
echo "  - Worker API: http://localhost:5000"
EOF

chmod +x "${USER_HOME}/start-services.sh"
chown "${USERNAME}:${USERGROUP}" "${USER_HOME}/start-services.sh"

log_success "快速启动脚本创建完成"

# ========================
# 完成总结
# ========================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✓ 服务器初始化完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "创建的资源："
echo "  • 用户: ${USERNAME}"
echo "  • 用户组: ${USERGROUP}"
echo "  • 主目录: ${USER_HOME}"
echo "  • 项目根目录: ${TRADING_ROOT}"
echo ""
echo "快速启动脚本："
echo "  • ~/activate-vnpy.sh - 激活 vnpy 环境"
echo "  • ~/start-services.sh - 启动所有服务"
echo ""
echo "下一步操作："
echo "  1. 切换到 ${USERNAME} 用户:"
echo "     su - ${USERNAME}"
echo ""
echo "  2. 克隆项目代码到 ${TRADING_ROOT}:"
echo "     cd ~/trading"
echo "     git clone <your-repo> quant-strategy-manager"
echo "     git clone <your-repo> vnpy-live-trading"
echo "     # ... 克隆其他项目"
echo ""
echo "  3. 设置 Python 虚拟环境:"
echo "     cd ~/trading/vnpy-live-trading"
echo "     python3 -m venv .venv"
echo "     source .venv/bin/activate"
echo "     pip install -r requirements.txt"
echo ""
echo "  4. 启动基础设施 (MongoDB, Redis):"
echo "     cd ~/trading/quant-infrastructure"
echo "     docker compose up -d"
echo ""
echo "  5. 部署 systemd 服务:"
echo "     sudo ln -sf ~/trading/quant-strategy-manager/systemd/worker-api.service /etc/systemd/system/"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable --now worker-api"
echo ""
echo -e "${BLUE}提示: 如果安装了 Docker，请重新登录以使组权限生效${NC}"
echo ""
