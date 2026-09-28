#!/bin/sh

# ============================================================
# run.sh (Docker版) — 仅保留配置区 + source bin/ 模块 + 启停操作
# 函数已拆分到 bin/ 目录，本文件仅负责编排调用
# ============================================================

# ===== 配置区域 =====
APP_DIR="/opt/service/gift-bookkeeping-app-docker"
if [ ! -d "$APP_DIR" ]; then
    APP_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# ===== SNI 多项目共用端口配置 =====
PROJECT_NAME="${PROJECT_NAME:-gift_app_docker}"
SNI_DOMAIN="${SNI_DOMAIN:-localhost}"
SSL_CERT="${SSL_CERT:-$APP_DIR/ssl/server.crt}"
SSL_KEY="${SSL_KEY:-$APP_DIR/ssl/server.key}"
SNI_DEFAULT_SERVER="${SNI_DEFAULT_SERVER:-0}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/opt/service/nginx/conf.d}"

# ===== 文件覆盖策略 =====
SSL_FORCE_UPDATE="${SSL_FORCE_UPDATE:-}"
NGINX_CONF_FORCE_UPDATE="${NGINX_CONF_FORCE_UPDATE:-}"

# ===== 环境变量定义（导出给 Docker Compose） =====
export PORT="${PORT:-11443}"
export HOST_PORT="${HOST_PORT:-15000}"
export NGINX_PORT="${NGINX_PORT:-443}"
export ADMIN_USER="${ADMIN_USER:-admin}"
export ADMIN_PASS="${ADMIN_PASS:-admin123}"
export APP_IMAGE="${APP_IMAGE:-}"
export GUNICORN_WORKERS="${GUNICORN_WORKERS:-1}"

# ===== 加载 bin/ 模块（按依赖顺序） =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/bin/common.sh"
. "$SCRIPT_DIR/bin/cleanup.sh"
. "$SCRIPT_DIR/bin/ssl_certs.sh"
. "$SCRIPT_DIR/bin/nginx_config.sh"
. "$SCRIPT_DIR/bin/port_conflict.sh"
. "$SCRIPT_DIR/bin/db_setup.sh"
. "$SCRIPT_DIR/bin/db_select.sh"

# ===== 启停操作函数 =====

start_service() {
    echo_e "${GREEN}正在启动服务...${NC}"
    ensure_ssl_certs
    check_port_conflict "$HOST_PORT" || return 1
    setup_nginx_config || {
        echo_e "${RED}❌ Nginx SNI 配置失败，服务启动中止，请检查 SNI_DOMAIN 环境变量${NC}"
        return 1
    }
    cleanup_cache
    cd "$APP_DIR" || exit 1

    select_db_mode

    _compose_files="-f docker-compose.yml"
    if [ -f "$DB_OVERRIDE" ]; then
        _compose_files="$_compose_files -f .temp/docker-compose.db-override.yml"
    fi
    if [ -n "$APP_IMAGE" ]; then
        echo_e "${GREEN}使用预构建镜像模式: ${APP_IMAGE}${NC}"
        $DOCKER_COMPOSE $_compose_files pull
        if [ $? -ne 0 ]; then
            echo_e "${RED}❌ 镜像拉取失败，请检查镜像名称与仓库访问权限${NC}"
            exit 1
        fi
        $DOCKER_COMPOSE $_compose_files up -d --no-build
    else
        $DOCKER_COMPOSE $_compose_files up -d --build
    fi
    if [ $? -eq 0 ]; then
        echo_e "${GREEN}✅ Docker 容器集群启动成功!${NC}"
        echo_e "   容器内监听端口: $PORT"
        echo_e "   宿主机映射端口: $HOST_PORT"
        for _sni_domain in $SNI_DOMAIN; do
            _port_suffix=""
            [ "$NGINX_PORT" != "443" ] && _port_suffix=":$NGINX_PORT"
            echo_e "   HTTPS 访问地址: https://$_sni_domain$_port_suffix (由 Nginx 反向代理至 127.0.0.1:$HOST_PORT)"
        done
    else
        echo_e "${RED}❌ Docker 容器集群启动失败，请检查 Docker 日志${NC}"
        exit 1
    fi
}

stop_service() {
    echo_e "${YELLOW}正在停止 Docker 容器集群...${NC}"
    cd "$APP_DIR" || exit 1
    _compose_files="-f docker-compose.yml"
    if [ -f "$DB_OVERRIDE" ]; then
        _compose_files="$_compose_files -f .temp/docker-compose.db-override.yml"
    fi
    $DOCKER_COMPOSE $_compose_files down
    echo_e "${GREEN}✅ Docker 容器集群已停止${NC}"
    if [ "$1" != "skip_clean" ]; then
        cleanup_cache
    fi
}

restart_service() {
    echo_e "${YELLOW}正在重启 Docker 容器集群...${NC}"
    stop_service skip_clean
    sleep 2
    start_service
}

status_service() {
    echo_e "${GREEN}Docker 容器集群运行状态:${NC}"
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE ps
}

logs_service() {
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE logs -f
}

build_service() {
    echo_e "${GREEN}正在重新构建 Docker 镜像...${NC}"
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
    clean)
        cleanup_cache
        ;;
    *)
        echo_e "用法: $0 {start|stop|restart|status|logs|build|clean}"
        echo ""
        echo_e "  ${GREEN}start${NC}   : 启动并部署 Docker 容器集群 (自动生成证书/配置 Nginx SNI 与清理缓存)"
        echo_e "  ${GREEN}stop${NC}    : 停止并移除 Docker 容器集群"
        echo_e "  ${GREEN}restart${NC} : 重启 Docker 容器集群"
        echo_e "  ${GREEN}status${NC}  : 查看 Docker 容器运行状态"
        echo_e "  ${GREEN}logs${NC}    : 实时查看 Docker 容器日志"
        echo_e "  ${GREEN}build${NC}   : 重新构建 Docker 镜像"
        echo_e "  ${GREEN}clean${NC}   : 仅手动清理垃圾缓存与压缩 .git"
        echo ""
        echo_e "  多项目共用 443 端口（SNI 分流）示例: SNI_DOMAIN=gift-docker.example.com PROJECT_NAME=gift_app_docker SNI_DEFAULT_SERVER=0 ./$0 start"
        echo_e "  多域名示例: SNI_DOMAIN=\"gift-docker.example.com gift-docker2.example.com\" ./$0 start"
        echo ""
        echo_e "  文件覆盖策略（已存在的证书/Nginx 配置，默认先询问):"
        echo_e "  ${GREEN}SSL_FORCE_UPDATE=1${NC}          SSL 证书已存在时强制覆盖更新，不询问 (默认: 询问/非交互时保留)"
        echo_e "  ${GREEN}NGINX_CONF_FORCE_UPDATE=1${NC}   Nginx 配置已存在时强制覆盖渲染，不询问 (默认: 询问/非交互时保留)"
        echo_e "  ${GREEN}APP_IMAGE=ghcr.io/...:latest${NC}  预构建镜像地址 (非空时拉取镜像不本地构建，为空时本地 build)"
        echo_e "  ${GREEN}GUNICORN_WORKERS=1${NC}             Gunicorn worker 数量 (默认 1，可调 2/4)"
        exit 1
        ;;
esac

exit 0
