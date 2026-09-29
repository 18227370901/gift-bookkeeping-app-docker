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

# V10.10.19: 统一访问信息展示（start 成功提示与 status 巡检共用）
print_access_info() {
    echo_e "   容器内监听端口: $PORT"
    echo_e "   宿主机映射端口: $HOST_PORT"
    for _sni_domain in $SNI_DOMAIN; do
        _port_suffix=""
        [ "$NGINX_PORT" != "443" ] && _port_suffix=":$NGINX_PORT"
        echo_e "   HTTPS 访问地址: https://$_sni_domain$_port_suffix (由 Nginx 反向代理至 127.0.0.1:$HOST_PORT)"
    done
}

# V10.10.19: 展示当前持久化的数据库部署模式（status 巡检用；不展示 DATABASE_URL 以免泄露数据库密码）
print_db_mode_info() {
    if [ -f "$DB_ENV_FILE" ]; then
        load_db_env
        if [ -n "${DB_MODE:-}" ]; then
            echo_e "   数据库模式: ${DB_MODE} (配置于 .temp/.db.env，DB_RESET=1 ./$(basename "$0") start 可重新选择)"
        else
            echo_e "   数据库模式: 配置文件为空或已损坏 (.temp/.db.env)，建议 DB_RESET=1 ./$(basename "$0") start 重新选择"
        fi
    else
        echo_e "   数据库模式: 未持久化配置（可能由 DB_MODE 环境变量指定或非交互默认 SQLite）"
    fi
}

# V10.10.20(对齐萌芽): 按 DB_MODE 构造 compose 文件组合（独立 PG 模式追加静态 docker-compose.db.yml）
# 彻底移除 .temp override 动态文件机制；DATABASE_URL 由 shell 环境变量插值注入
compose_files_for_mode() {
    _cf="-f docker-compose.yml"
    if [ "${DB_MODE:-}" = "independent" ]; then
        _cf="$_cf -f docker-compose.db.yml"
    fi
    echo "$_cf"
}

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

    _compose_files=$(compose_files_for_mode)
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
        # V10.10.20(对齐萌芽): 共享 PG 兑底接入——首启时网络在 setup 阶段尚不存在，此处补充接入并重启 web
        # 已接入（setup 阶段完成）则不重复操作，日常 start 零额外重启
        if [ "${DB_MODE:-}" = "shared" ] && [ -n "${DB_PG_CONTAINER:-}" ]; then
            if ! docker network inspect gift-docker_net >/dev/null 2>&1; then
                echo_e "${YELLOW}⚠️ 未找到网络 gift-docker_net，共享 PG 容器未能接入，请重新执行 start${NC}"
            elif ! docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$DB_PG_CONTAINER" 2>/dev/null | grep -qw "gift-docker_net"; then
                docker network connect gift-docker_net "$DB_PG_CONTAINER" 2>/dev/null || true
                echo_e "${GREEN}✅ 已接入共享 PG 容器 ${DB_PG_CONTAINER} 至自有网络 gift-docker_net${NC}"
                $DOCKER_COMPOSE $_compose_files restart web >/dev/null 2>&1
                echo_e "${GREEN}✅ web 容器已重启并连接共享 PG (${DB_PG_CONTAINER})${NC}"
            fi
        fi
        # V10.10.19: 访问信息展示统一由 print_access_info 输出（与 status 命令一致）
        print_access_info
    else
        echo_e "${RED}❌ Docker 容器集群启动失败，请检查 Docker 日志${NC}"
        echo_e "${YELLOW}  若提示 external network 不存在，请执行: DB_RESET=1 ./$(basename "$0") start 重新选择数据库模式（或 DB_MODE=sqlite ./$(basename "$0") start 切换 SQLite）${NC}"
        exit 1
    fi
}

stop_service() {
    echo_e "${YELLOW}正在停止 Docker 容器集群...${NC}"
    cd "$APP_DIR" || exit 1
    # V10.10.20: 共享 PG 模式先摘除 PG 容器与 gift 网络的连接，避免网络被占用导致 down 失败
    if [ -f "$DB_ENV_FILE" ]; then
        load_db_env
        if [ "${DB_MODE:-}" = "shared" ] && [ -n "${DB_PG_CONTAINER:-}" ]; then
            docker network disconnect gift-docker_net "$DB_PG_CONTAINER" 2>/dev/null || true
        fi
    fi
    _compose_files=$(compose_files_for_mode)
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
    # V10.10.20(对齐萌芽): 按 DB_MODE 构造 compose 文件（独立 PG 模式 pg 容器状态一并显示）
    [ -f "$DB_ENV_FILE" ] && load_db_env
    _compose_files=$(compose_files_for_mode)
    $DOCKER_COMPOSE $_compose_files ps
    # V10.10.19: 有容器在运行时，附带访问地址与数据库模式，便于日常巡检
    if [ -n "$($DOCKER_COMPOSE $_compose_files ps -q 2>/dev/null)" ]; then
        echo_e ""
        print_access_info
        print_db_mode_info
    fi
}

logs_service() {
    cd "$APP_DIR" || exit 1
    # V10.10.20(对齐萌芽): 按 DB_MODE 构造 compose 文件（独立 PG 模式可同时查看 pg 日志）
    [ -f "$DB_ENV_FILE" ] && load_db_env
    _compose_files=$(compose_files_for_mode)
    $DOCKER_COMPOSE $_compose_files logs -f
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
        echo_e "  ${GREEN}status${NC}  : 查看 Docker 容器运行状态 (运行中附带访问地址与数据库模式)"
        echo_e "  ${GREEN}logs${NC}    : 实时查看 Docker 容器日志"
        echo_e "  ${GREEN}build${NC}   : 重新构建 Docker 镜像"
        echo_e "  ${GREEN}clean${NC}   : 仅手动清理垃圾缓存与压缩 .git"
        echo ""
        echo_e "  多项目共用 443 端口（SNI 分流）示例: SNI_DOMAIN=gift-docker.example.com PROJECT_NAME=gift_app_docker SNI_DEFAULT_SERVER=0 ./$(basename "$0") start"
        echo_e "  多域名示例: SNI_DOMAIN=\"gift-docker.example.com gift-docker2.example.com\" ./$(basename "$0") start"
        echo ""
        echo_e "  文件覆盖策略（已存在的证书/Nginx 配置，默认先询问):"
        echo_e "  ${GREEN}SSL_FORCE_UPDATE=1${NC}          SSL 证书已存在时强制覆盖更新，不询问 (默认: 询问/非交互时保留)"
        echo_e "  ${GREEN}NGINX_CONF_FORCE_UPDATE=1${NC}   Nginx 配置已存在时强制覆盖渲染，不询问 (默认: 询问/非交互时保留)"
        echo_e "  ${GREEN}APP_IMAGE=ghcr.io/...:latest${NC}  预构建镜像地址 (非空时拉取镜像不本地构建，为空时本地 build)"
        echo_e "  ${GREEN}GUNICORN_WORKERS=1${NC}             Gunicorn worker 数量 (默认 1，可调 2/4)"
        echo_e ""
        echo_e "  数据库部署选择 (首次 start 交互式三选一，选择结果持久化于 .temp/.db.env，后续 start/restart 自动读取):"
        echo_e "  ${GREEN}DB_MODE=sqlite|shared|independent${NC}   直接指定数据库模式跳过交互 (shared 需搭配 DB_PG_CONTAINER)"
        echo_e "  ${GREEN}DB_PG_CONTAINER=<容器名>${NC}            共享 PG 模式复用的已运行容器名，启动时自动接入自有网络 gift-docker_net"
        echo_e "  ${GREEN}DB_RESET=1${NC}                          清除已保存的数据库配置并重新进入交互选择 (自动清理 .db.env 与旧 override 残留)"
        echo_e "  示例: DB_RESET=1 ./$(basename "$0") start   # 重新选择数据库模式"
        exit 1
        ;;
esac

exit 0
