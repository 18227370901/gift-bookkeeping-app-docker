#!/bin/sh
# service.sh (Docker版) — 启停操作函数（V10.10.21 自 run.sh 拆出）
# 依赖：bin/config.sh（变量）、bin/common.sh（echo_e）、bin/cleanup.sh（cleanup_cache/check_docker）、
#       bin/db_select.sh（select_db_mode/load_db_env）、bin/db_setup.sh（PG 模式函数）

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
            echo_e "   数据库模式: ${DB_MODE} (配置于 .temp/.db.env，./$(basename "$0") --reconfig 可重新选择)"
        else
            echo_e "   数据库模式: 配置文件为空或已损坏 (.temp/.db.env)，建议 ./$(basename "$0") --reconfig 重新选择"
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

    # V10.10.20: 独立 PG 模式持久化镜像/挂载路径/连接参数（共享 save_db_env 不写这些字段，避免 restart 时漂移）
    if [ "${DB_MODE:-}" = "independent" ] && [ -n "${PG_LOCAL_IMAGE:-}" ]; then
        mkdir -p "$APP_DIR/.temp"
        [ -f "$DB_ENV_FILE" ] || touch "$DB_ENV_FILE"
        grep -v -E '^(PG_LOCAL_IMAGE|PG_DATA_DIR|PG_USER|PG_PASSWORD|PG_DB)=' "$DB_ENV_FILE" 2>/dev/null > "$DB_ENV_FILE.tmp" || true
        echo "PG_LOCAL_IMAGE=$PG_LOCAL_IMAGE" >> "$DB_ENV_FILE.tmp"
        echo "PG_DATA_DIR=$PG_DATA_DIR" >> "$DB_ENV_FILE.tmp"
        echo "PG_USER=$PG_USER" >> "$DB_ENV_FILE.tmp"
        echo "PG_PASSWORD=$PG_PASSWORD" >> "$DB_ENV_FILE.tmp"
        echo "PG_DB=$PG_DB" >> "$DB_ENV_FILE.tmp"
        mv "$DB_ENV_FILE.tmp" "$DB_ENV_FILE"
        chmod 600 "$DB_ENV_FILE" 2>/dev/null || true
    fi

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
        # V10.10.22: 独立 PG 容器就绪后强制 ALTER USER 同步密码——
        # Docker 卷已存在时 POSTGRES_PASSWORD 环境变量被忽略（PG 只在首次初始化时读取），
        # 需 ALTER USER 兑底确保密码与 DATABASE_URL 一致
        # V10.10.22: ① 容器名修正为 gift_bookkeeping_pg——此前误用 ${PROJECT_NAME}-pg，
        #    与 docker-compose.db.yml 硬编码的 container_name 不一致，docker exec 找不到容器，
        #    密码同步从未生效（独立 PG卷已存在时切换/更新密码仍会认证失败）
        #    ② pg_isready 就绪轮询（最长 30 秒）取代固定 sleep 3（首次初始化卷时 PG 就绪可能更久）
        #    ③ 同步成功后 restart web——web 若以旧密码启动连接失败，不同步重启无法恢复
        if [ "${DB_MODE:-}" = "independent" ] && [ -n "${PG_PASSWORD:-}" ]; then
            _pg_svc="gift_bookkeeping_pg"
            _pg_wait=0
            while [ $_pg_wait -lt 30 ]; do
                docker exec "$_pg_svc" pg_isready -U "${PG_USER:-gift_user}" > /dev/null 2>&1 && break
                sleep 1
                _pg_wait=$((_pg_wait + 1))
            done
            if pg_sync_password "$_pg_svc" "$PG_USER" "$PG_USER" "$PG_PASSWORD"; then
                _ps_ok=1
            elif pg_sync_password "$_pg_svc" "postgres" "$PG_USER" "$PG_PASSWORD"; then
                _ps_ok=1
            else
                _ps_ok=""
            fi
            if [ -n "$_ps_ok" ]; then
                echo_e "${GREEN}✅ 独立 PG 密码已同步${NC}"
                $DOCKER_COMPOSE $_compose_files restart web >/dev/null 2>&1
                echo_e "${GREEN}✅ web 容器已重启并以同步后的密码连接 PG${NC}"
            else
                echo_e "${YELLOW}⚠️ 独立 PG 密码同步未成功，如遇连接失败请手动检查容器 $_pg_svc${NC}"
            fi
        fi
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
        echo_e "${YELLOW}  若提示 external network 不存在，请执行: ./$(basename "$0") --reconfig 重新选择数据库模式（或 DB_MODE=sqlite ./$(basename "$0") start 切换 SQLite）${NC}"
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
