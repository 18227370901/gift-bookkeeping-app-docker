#!/bin/bash

# ===== 确保使用 Bash 解释器运行（防止 sh run.sh 导致的 Bashisms 语法报错） =====
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# ===== 配置区域 =====
APP_DIR="/opt/service/gift-bookkeeping-app-docker"
if [ ! -d "$APP_DIR" ]; then
    APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ===== 依赖检查 =====
check_docker() {
    if ! command -v docker > /dev/null 2>&1; then
        echo -e "${RED}错误: 未找到 docker 命令，请先安装 Docker。${NC}"
        exit 1
    fi

    if docker compose version > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        echo -e "${RED}错误: 未找到 docker compose 或 docker-compose，请先安装 Docker Compose。${NC}"
        exit 1
    fi
}

# ===== 自动补全 SSL 证书 =====
ensure_ssl_certs() {
    if [ ! -f "$APP_DIR/ssl/server.crt" ] || [ ! -f "$APP_DIR/ssl/server.key" ]; then
        echo -e "${YELLOW}检测到 SSL 证书缺失，正在自动生成自签名随机 SSL 证书...${NC}"
        mkdir -p "$APP_DIR/ssl"
        if command -v python3 > /dev/null 2>&1; then
            python3 "$APP_DIR/generate_ssl_certs.py"
        else
            echo -e "${RED}警告: 未找到 python3，无法自动生成证书，请手动生成或准备 ssl/server.crt 和 ssl/server.key${NC}"
        fi
    fi
}

# ===== Docker 操作函数 =====

start_service() {
    echo -e "${GREEN}正在通过 Docker Compose 启动服务集群...${NC}"
    ensure_ssl_certs
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE up -d --build
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Docker 容器集群启动成功!${NC}"
        echo -e "   HTTPS 访问地址: https://<your-server-ip>:15001"
    else
        echo -e "${RED}❌ Docker 容器集群启动失败，请检查 Docker 日志${NC}"
        exit 1
    fi
}

stop_service() {
    echo -e "${YELLOW}正在停止 Docker 容器集群...${NC}"
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE down
    echo -e "${GREEN}✅ Docker 容器集群已停止${NC}"
}

restart_service() {
    echo -e "${YELLOW}正在重启 Docker 容器集群...${NC}"
    stop_service
    sleep 2
    start_service
}

status_service() {
    echo -e "${GREEN}Docker 容器集群运行状态:${NC}"
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE ps
}

logs_service() {
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE logs -f
}

build_service() {
    echo -e "${GREEN}正在重新构建 Docker 镜像...${NC}"
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE build
}

# ===== 主逻辑 =====
check_docker

case "$1" in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    status|ps)
        status_service
        ;;
    logs)
        logs_service
        ;;
    build)
        build_service
        ;;
    *)
        echo -e "用法: $0 {start|stop|restart|status|logs|build}"
        echo ""
        echo -e "  ${GREEN}start${NC}   : 启动并部署 Docker 容器集群"
        echo -e "  ${GREEN}stop${NC}    : 停止并移除 Docker 容器集群"
        echo -e "  ${GREEN}restart${NC} : 重启 Docker 容器集群"
        echo -e "  ${GREEN}status${NC}  : 查看 Docker 容器运行状态"
        echo -e "  ${GREEN}logs${NC}    : 实时查看 Docker 容器日志"
        echo -e "  ${GREEN}build${NC}   : 重新构建 Docker 镜像"
        exit 1
        ;;
esac

exit 0
