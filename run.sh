#!/bin/sh

# ===== 配置区域 =====
APP_DIR="/opt/service/gift-bookkeeping-app-docker"
if [ ! -d "$APP_DIR" ]; then
    APP_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# ===== SNI 多项目共用端口配置（全部支持环境变量覆盖，多项目部署时各项目设不同值即可） =====
PROJECT_NAME="${PROJECT_NAME:-gift_app_docker}"   # 项目标识：决定 Nginx 配置文件名($PROJECT_NAME.conf)与 upstream 名(${PROJECT_NAME}_backend)，默认与传统原生版 gift_app 区分
SNI_DOMAIN="${SNI_DOMAIN:-localhost}"            # SNI 域名：写入 server_name 与自签证书 CN/SAN，多项目各设一个域名
SSL_CERT="${SSL_CERT:-$APP_DIR/ssl/server.crt}" # SSL 证书路径（可指向正式证书）
SSL_KEY="${SSL_KEY:-$APP_DIR/ssl/server.key}"   # SSL 私钥路径
SNI_DEFAULT_SERVER="${SNI_DEFAULT_SERVER:-0}"   # 是否作为该监听端口的兑底 default_server（1=是 0=否，多项目共端口时只应有一个项目为 1；同一台服务器若原生版 gift_app 已作兑底，Docker 版保持 0）

# Nginx 配置文件目录变量（用户可自定义覆盖，如 export NGINX_CONF_DIR=/etc/nginx/conf.d）
# 默认指向 /opt/service/nginx/conf.d；其他部署环境如使用 /etc/nginx/conf.d，可通过环境变量覆盖
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/opt/service/nginx/conf.d}"

# ===== 文件覆盖策略（V10.10.3 新增：保护已存在的证书与 Nginx 配置，防止重启时被自签证书/模板渲染静默覆盖） =====
# SSL_FORCE_UPDATE / NGINX_CONF_FORCE_UPDATE: 文件已存在时是否强制覆盖更新
#   1 = 强制更新（不询问，直接覆盖）；未设置 = 交互式终端弹出 y/n 询问，非交互场景（cron/CI/管道）默认跳过保留旧文件
SSL_FORCE_UPDATE="${SSL_FORCE_UPDATE:-}"
NGINX_CONF_FORCE_UPDATE="${NGINX_CONF_FORCE_UPDATE:-}"

# ===== 环境变量定义（导出给 Docker Compose） =====
export PORT="${PORT:-11443}"            # Web 容器内部服务端口，默认 11443
export HOST_PORT="${HOST_PORT:-15000}"   # 宿主机映射端口，默认 15000
export NGINX_PORT="${NGINX_PORT:-443}"  # 宿主机 Nginx 监听端口，默认 443（多项目共用，依靠 SNI 域名区分流量）
export ADMIN_USER="${ADMIN_USER:-admin}"
export ADMIN_PASS="${ADMIN_PASS:-admin123}"

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# POSIX 兼容的彩色输出函数（替代 echo -e，兼容 dash/sh）
echo_e() {
    printf '%b\n' "$*"
}

# ===== 依赖检查 =====
check_docker() {
    if ! command -v docker > /dev/null 2>&1; then
        echo_e "${RED}错误: 未找到 docker 命令，请先安装 Docker。${NC}"
        exit 1
    fi

    if docker compose version > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose > /dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        echo_e "${RED}错误: 未找到 docker compose 或 docker-compose，请先安装 Docker Compose。${NC}"
        exit 1
    fi
}

# ===== 判断是否覆盖已存在文件：交互环境弹 y/n 询问；非交互环境（cron/CI）不能卡死在 read，默认保留旧文件 =====
# 入参 $1: 已存在文件路径（提示语用）；$2: 对应策略环境变量当前值（1=强制覆盖 0=强制保留 空=询问）；$3: 策略变量名（非交互提示文案用）
# 返回值: 0=允许覆盖更新 1=保留旧文件不覆盖
should_overwrite() {
    local target_file="$1"
    local force_value="$2"
    local hint_var="$3"
    # 环境变量已显式指定策略时，直接按策略执行，不再询问（兼容 cron 定时重启等非交互场景）
    if [ "$force_value" = "1" ]; then
        return 0
    fi
    if [ "$force_value" = "0" ]; then
        return 1
    fi
    # [ -t 0 ] 检测 stdin 是否为终端：非交互场景（cron、管道、CI）无人应答，默认保留旧文件，避免脚本卡死
    if [ ! -t 0 ]; then
        echo_e "${YELLOW}检测到已存在 $target_file，非交互环境自动保留旧文件（如需强制更新请设置 $hint_var=1）${NC}"
        return 1
    fi
    # 交互式终端：弹出确认，输入 y/Y 确认覆盖，其余任意输入（含直接回车）均视为保留旧文件（默认安全）
    printf '检测到已存在 %s，是否覆盖更新? (y/n) [默认 n]: ' "$target_file" >&2
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# ===== 自动生成 SSL 证书：文件不存在则直接创建；已存在时先询问是否更新，防止自定义/正式证书被自签证书覆盖 =====
ensure_ssl_certs() {
    # 两份证书文件均不存在时，无需询问，直接创建（首次部署场景）
    if [ ! -f "$SSL_CERT" ] && [ ! -f "$SSL_KEY" ]; then
        echo_e "${GREEN}未检测到 SSL 证书文件，正在生成自签名证书 (域名: $SNI_DOMAIN)...${NC}"
        mkdir -p "$APP_DIR/ssl"
        local cert_script="$APP_DIR/generate_ssl_certs.py"
        # 固定在 APP_DIR 下执行，确保证书始终输出到 $APP_DIR/ssl（不依赖调用时所在目录）
        if command -v python3 > /dev/null 2>&1; then
            (cd "$APP_DIR" && python3 "$cert_script" --domain "$SNI_DOMAIN")
        else
            echo_e "${RED}警告: 未找到 python3，无法自动生成证书，请手动生成或准备 $SSL_CERT 和 $SSL_KEY${NC}"
        fi
    # 文件已存在：必须先取得用户/环境变量许可，才允许覆盖更新（保护自定义证书、正式证书）
    elif should_overwrite "$SSL_CERT" "$SSL_FORCE_UPDATE" "SSL_FORCE_UPDATE"; then
        echo_e "${GREEN}确认更新，正在重新生成 SSL 自签名证书 (域名: $SNI_DOMAIN)...${NC}"
        mkdir -p "$APP_DIR/ssl"
        local cert_script="$APP_DIR/generate_ssl_certs.py"
        # 固定在 APP_DIR 下执行，确保证书始终输出到 $APP_DIR/ssl（不依赖调用时所在目录）
        if command -v python3 > /dev/null 2>&1; then
            (cd "$APP_DIR" && python3 "$cert_script" --domain "$SNI_DOMAIN")
        else
            echo_e "${RED}警告: 未找到 python3，无法自动生成证书，请手动生成或准备 $SSL_CERT 和 $SSL_KEY${NC}"
        fi
    else
        echo_e "${GREEN}✅ 检测到已存在 SSL 证书文件，保留现有证书不更新: $SSL_CERT / $SSL_KEY${NC}"
    fi
    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
        echo_e "${YELLOW}⚠️ 证书文件缺失: $SSL_CERT / $SSL_KEY，Nginx 配置校验将无法通过${NC}"
    fi
}

# ===== 自动配置 Nginx 反向代理（SNI 多项目分流） =====
setup_nginx_config() {
    # SNI 域名必填：server_name 为空会导致 Nginx 配置无效，且多项目无法区分流量
    if [ -z "$SNI_DOMAIN" ]; then
        echo_e "${RED}错误: SNI_DOMAIN 为空，无法配置 Nginx SNI 分流，已中止。请通过环境变量指定，例如: SNI_DOMAIN=gift.example.com PROJECT_NAME=gift_app_docker ./$0 start${NC}"
        return 1
    fi

    # Nginx 配置目录不存在时：提示用户手动创建，不自动创建、不跳过
    if [ ! -d "$NGINX_CONF_DIR" ]; then
        echo_e "${RED}错误: Nginx 配置目录不存在: $NGINX_CONF_DIR${NC}"
        echo_e "${YELLOW}请手动创建该目录后重试: sudo mkdir -p $NGINX_CONF_DIR${NC}"
        echo_e "${YELLOW}（其他部署环境如使用 /etc/nginx/conf.d，可通过环境变量覆盖: export NGINX_CONF_DIR=/etc/nginx/conf.d）${NC}"
        return 1
    fi

    if [ -d "$NGINX_CONF_DIR" ]; then
        echo_e "${GREEN}正在处理 Nginx 配置文件 ($NGINX_CONF_DIR)...${NC}"
        local target_conf="$NGINX_CONF_DIR/$PROJECT_NAME.conf"
        # SNI default_server 冲突自动降级：同端口只能有一个 default_server，检测到已有其他项目设为 default_server 时自动改为非兜底
        if [ "$SNI_DEFAULT_SERVER" = "1" ]; then
            for f in "$NGINX_CONF_DIR"/*.conf; do
                [ -f "$f" ] || continue
                [ "$f" = "$target_conf" ] && continue  # 跳过自己
                if grep -q "default_server" "$f" 2>/dev/null; then
                    echo_e "${YELLOW}⚠️ 检测到 $(basename "$f") 已设为 default_server，本项目将自动改为非兜底模式${NC}"
                    SNI_DEFAULT_SERVER=0
                    break
                fi
            done
        fi
        # 已存在的项目配置文件先取得许可再覆盖渲染，防止用户手改过的 conf 被模板静默重置
        # （首次部署文件不存在时无需询问，直接渲染创建）
        if [ -f "$target_conf" ] && ! should_overwrite "$target_conf" "$NGINX_CONF_FORCE_UPDATE" "NGINX_CONF_FORCE_UPDATE"; then
            echo_e "${YELLOW}保留现有 Nginx 配置文件，未重新渲染: $target_conf${NC}"
        elif [ -f "$APP_DIR/nginx_ssl.conf" ]; then
            # 按 SNI_DEFAULT_SERVER 决定 listen 行是否追加 default_server（兜底 server）
            local listen_value="$NGINX_PORT"
            local default_flag="否"
            if [ "$SNI_DEFAULT_SERVER" = "1" ]; then
                listen_value="${NGINX_PORT} default_server"
                default_flag="是"
            fi
            # 渲染占位符模板，输出为当前项目专属配置文件（每个项目一份，互不覆盖）
            # 模板顶部的占位符说明注释不带入生成文件（其占位符已被替换，保留会误导阅读者）
            # 注意：__BACKEND_PORT__ 填的是宿主机 Docker 映射端口 HOST_PORT（默认 15000），不是容器内 PORT
            {
                echo "# 本文件由 run.sh 依据 nginx_ssl.conf 模板自动生成，请勿手工修改（改模板请编辑源文件后重跑 start）"
                echo "# 项目: $PROJECT_NAME | SNI域名: $SNI_DOMAIN | 监听端口: $NGINX_PORT | default_server: $default_flag | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
                sed -e '1,/^#   __SSL_KEY__/d' \
                    -e "s|__UPSTREAM_NAME__|${PROJECT_NAME}_backend|g" \
                    -e "s|__BACKEND_PORT__|$HOST_PORT|g" \
                    -e "s|__NGINX_PORT__|$listen_value|g" \
                    -e "s|__SNI_DOMAIN__|$SNI_DOMAIN|g" \
                    -e "s|__SSL_CERT__|$SSL_CERT|g" \
                    -e "s|__SSL_KEY__|$SSL_KEY|g" \
                    "$APP_DIR/nginx_ssl.conf"
            } > "$target_conf" 2>/dev/null && \
            echo_e "${GREEN}✅ 已动态更新并同步 Nginx 配置到 $target_conf (项目: $PROJECT_NAME, 宿主机映射端口: $HOST_PORT, Nginx监听端口: $NGINX_PORT, SNI域名: $SNI_DOMAIN, default_server: $default_flag)${NC}" || true
        fi
        if command -v nginx > /dev/null 2>&1; then
            if nginx -t >/dev/null 2>&1; then
                (nginx -s reload >/dev/null 2>&1 || systemctl reload nginx >/dev/null 2>&1) && \
                echo_e "${GREEN}✅ Nginx 配置热重载成功!${NC}" || echo_e "${YELLOW}⚠️ Nginx 热重载跳过 (需 root 权限)${NC}"
            else
                echo_e "${YELLOW}⚠️ Nginx 配置语法校验未通过，跳过 reload${NC}"
            fi
        fi
    fi
}

# ===== 清理缓存与 .git 冗余垃圾 =====
cleanup_cache() {
    echo_e "${GREEN}正在清理本地缓存与 .git 冗余垃圾...${NC}"
    cd "$APP_DIR" || return
    if [ -d ".git" ] && command -v git > /dev/null 2>&1; then
        git reflog expire --expire=now --all 2>/dev/null || true
        git gc --prune=now 2>/dev/null || true
        echo_e "${GREEN}✅ .git 冗余垃圾清理完成! 当前 .git 体积: $(du -sh .git 2>/dev/null | cut -f1)${NC}"
    fi
    find "$APP_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$APP_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
    rm -rf /tmp/gift-backup 2>/dev/null || true
}

# ===== Docker 操作函数 =====

# 检测端口是否被占用，被占用时提示用户选择处理方式（SNI 模式下允许双版本共存，但后端端口不能相同）
check_port_conflict() {
    local check_port="$1"
    local port_pid=$(lsof -ti :"$check_port" 2>/dev/null)

    if [ -z "$port_pid" ]; then
        return 0  # 端口空闲，可正常启动
    fi

    # 端口被其他进程占用
    local proc_info=$(ps -p "$port_pid" -o cmd= 2>/dev/null | head -c 200)
    echo_e "${RED}❌ 端口 $check_port 已被占用！${NC}"
    echo_e "   占用进程 PID: $port_pid"
    echo_e "   进程信息: $proc_info"

    # 非交互环境直接中止
    if [ ! -t 0 ]; then
        echo_e "${RED}非交互环境无法选择，服务启动中止。请更换端口后重试。${NC}"
        echo_e "   传统版: PORT=新端口 ./$0 start"
        echo_e "   Docker版: HOST_PORT=新端口 ./$0 start"
        return 1
    fi

    # 交互式选择
    while true; do
        echo_e "${YELLOW}请选择处理方式：${NC}"
        echo_e "  1) 修改本服务端口后重新启动（推荐）"
        echo_e "  2) 停用另一个服务的 Nginx 配置后继续"
        echo_e "  3) 中止启动"
        printf '请输入选项 [1/2/3]: '
        read -r choice
        case "$choice" in
            1)
                echo_e "${GREEN}请修改端口后重新启动：${NC}"
                echo_e "   传统版: PORT=新端口 ./$0 start"
                echo_e "   Docker版: HOST_PORT=新端口 ./$0 start"
                return 1
                ;;
            2)
                # 列出当前 Nginx 配置目录中的项目配置文件，让用户选择停用哪个
                echo_e "${YELLOW}当前 $NGINX_CONF_DIR 中的 Nginx 配置文件：${NC}"
                local conf_files=$(ls "$NGINX_CONF_DIR"/*.conf 2>/dev/null)
                if [ -z "$conf_files" ]; then
                    echo_e "${RED}未找到任何 .conf 配置文件${NC}"
                    return 1
                fi
                local ci=1
                for f in $conf_files; do
                    echo_e "  $ci) $(basename "$f")"
                    ci=$((ci + 1))
                done
                printf '请输入要停用的配置编号: '
                read -r conf_choice
                local selected=$(echo "$conf_files" | sed -n "${conf_choice}p")
                if [ -n "$selected" ]; then
                    mv "$selected" "${selected}.disabled" 2>/dev/null
                    echo_e "${GREEN}已停用: $(basename "$selected")${NC}"
                    # reload nginx
                    if command -v nginx > /dev/null 2>&1; then
                        if nginx -t >/dev/null 2>&1; then
                            nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null
                        fi
                    fi
                    # 再次检测端口是否释放
                    local recheck_pid=$(lsof -ti :"$check_port" 2>/dev/null)
                    if [ -n "$recheck_pid" ]; then
                        echo_e "${RED}停用 Nginx 配置后端口 $check_port 仍被占用，可能后端进程仍在运行${NC}"
                        echo_e "   请手动停止占用端口的进程: kill $recheck_pid"
                        return 1
                    fi
                    return 0
                else
                    echo_e "${RED}无效的选择${NC}"
                    return 1
                fi
                ;;
            3)
                echo_e "${YELLOW}已中止启动${NC}"
                return 1
                ;;
            *)
                echo_e "${RED}无效选项，请重新选择${NC}"
                ;;
        esac
    done
}

start_service() {
    echo_e "${GREEN}正在启动服务...${NC}"
    # 启动前自动生成最新 SSL 证书、配置 Nginx SNI 与清理缓存垃圾（SNI 配置失败则中止启动）
    ensure_ssl_certs

    # 端口冲突检测（SNI 模式下允许双版本共存，但宿主机映射端口不能相同）
    check_port_conflict "$HOST_PORT" || return 1

    setup_nginx_config || {
        echo_e "${RED}❌ Nginx SNI 配置失败，服务启动中止，请检查 SNI_DOMAIN 环境变量${NC}"
        return 1
    }
    cleanup_cache
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE up -d --build
    if [ $? -eq 0 ]; then
        echo_e "${GREEN}✅ Docker 容器集群启动成功!${NC}"
        echo_e "   容器内监听端口: $PORT"
        echo_e "   宿主机映射端口: $HOST_PORT"
        echo_e "   HTTPS 访问地址: https://$SNI_DOMAIN"$( [ "$NGINX_PORT" = "443" ] || echo ":$NGINX_PORT" )" (由 Nginx 反向代理至 127.0.0.1:$HOST_PORT)"
    else
        echo_e "${RED}❌ Docker 容器集群启动失败，请检查 Docker 日志${NC}"
        exit 1
    fi
}

stop_service() {
    echo_e "${YELLOW}正在停止 Docker 容器集群...${NC}"
    cd "$APP_DIR" || exit 1
    $DOCKER_COMPOSE down
    echo_e "${GREEN}✅ Docker 容器集群已停止${NC}"
}

restart_service() {
    echo_e "${YELLOW}正在重启 Docker 容器集群...${NC}"
    stop_service
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
        echo_e ""
        echo_e "  文件覆盖策略（已存在的证书/Nginx 配置，默认先询问):"
        echo_e "  ${GREEN}SSL_FORCE_UPDATE=1${NC}          SSL 证书已存在时强制覆盖更新，不询问 (默认: 询问/非交互时保留)"
        echo_e "  ${GREEN}NGINX_CONF_FORCE_UPDATE=1${NC}   Nginx 配置已存在时强制覆盖渲染，不询问 (默认: 询问/非交互时保留)"
        exit 1
        ;;
esac

exit 0
