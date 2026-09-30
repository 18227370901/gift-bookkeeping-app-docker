#!/bin/sh
# db_setup.sh (Docker版) — 数据库模式配置函数（V10.10.20 对齐 mengya-docker 部署模式）
# V10.10.22: ALTER USER 密码同步改为可靠模式（不再静默吞错）
# 架构变化：
#   - 彻底移除 .temp/docker-compose.db-override.yml 动态 override 文件机制（根治 external 网络失效启动失败）
#   - DATABASE_URL 由 run.sh 经 shell 环境变量插值注入 compose（docker-compose.yml 的 ${DATABASE_URL:-}）
#   - 独立 PG：由静态 docker-compose.db.yml 按 -f 参数按需合成（萌芽同款 COMPOSE_FILE 机制）
#   - 共享 PG：通过 docker network connect 把共享 PG 容器接入 gift 自有网络 gift-docker_net（萌芽同款）
#   - 网络永不声明 external；旧 override 残留文件在各模式中顺手清理

# V10.10.25: 可靠的 PG 密码同步（ALTER USER），多种连接方式兜底
# 入参 $1: 容器名, $2: 超级用户名（可选，默认 postgres）, $3: 目标用户, $4: 新密码
# 背景：psql -U <用户> 在 Docker PG 容器内默认走 scram-sha-256 密码认证（非 trust），
#       真正可靠的免密方式是 docker exec -u postgres（OS 级 peer 认证）
pg_sync_password() {
    _psc="$1"
    _pss="${2:-postgres}"
    _psu="$3"
    _psp="$4"
    # 方式 1（最可靠）: OS 级 peer 认证
    if docker exec -u postgres "$_psc" psql -tAc "SELECT 1" >/dev/null 2>&1; then
        docker exec -u postgres "$_psc" psql -c "ALTER USER $_psu WITH PASSWORD '$_psp';" >/dev/null 2>&1
        return $?
    fi
    # 方式 2: 本地 socket + 传入的超级用户（部分镜像 pg_hba.conf 配置了 trust）
    if docker exec "$_psc" psql -U "$_pss" -tAc "SELECT 1" >/dev/null 2>&1; then
        docker exec "$_psc" psql -U "$_pss" -c "ALTER USER $_psu WITH PASSWORD '$_psp';" >/dev/null 2>&1
        return $?
    fi
    # 方式 3: 容器 env 检测真实超级用户
    _env_su=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$_psc" 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2)
    if [ -n "$_env_su" ] && [ "$_env_su" != "$_pss" ]; then
        if docker exec -u postgres "$_psc" psql -U "$_env_su" -tAc "SELECT 1" >/dev/null 2>&1; then
            docker exec -u postgres "$_psc" psql -U "$_env_su" -c "ALTER USER $_psu WITH PASSWORD '$_psp';" >/dev/null 2>&1
            return $?
        fi
    fi
    echo_e "${RED}❌ ALTER USER 密码同步失败：无法连接容器 $_psc 的 PostgreSQL（peer/$_pss/POSTGRES_USER 三种方式均失败）${NC}"
    return 1
}

# V10.10.25: 检测容器的真实超级用户名（POSTGRES_USER env，无则 postgres）
detect_pg_superuser() {
    _dsu=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2)
    echo "${_dsu:-postgres}"
}

# SQLite 模式：清空 DATABASE_URL 并清理旧机制残留 override 文件
setup_sqlite() {
    DATABASE_URL=""
    export DATABASE_URL
    rm -f "$DB_OVERRIDE"
    echo_e "${GREEN}数据库模式: SQLite 本地文件${NC}"
}

# V10.10.22: PG 连接参数解析（用户自定义 > config.local.sh > 内置默认值；默认值集中定义于 bin/config.sh）
# PG_USER/PG_PASSWORD/PG_DB 环境变量可自定义；未指定时使用默认值（PG_USER_DEFAULT / PG_PASSWORD_DEFAULT / PG_DB_DEFAULT）
# V10.10.22 变更：PG_PASSWORD 不再每次随机生成——此前随机密码导致重启/重选时密码变化，已有 PG 实例密码不匹配；
#                 现改为固定默认值 gift_docker_pass（可在 config.local.sh 中覆盖），已有实例用户自动 ALTER USER 同步
# 密码校验：单引号/空格直接拒绝（无法安全拼入 SQL 与 URL）；URL 特殊字符警告
resolve_pg_conn_params() {
    PG_USER="${PG_USER:-$PG_USER_DEFAULT}"
    PG_DB="${PG_DB:-$PG_DB_DEFAULT}"
    PG_PASSWORD="${PG_PASSWORD:-$PG_PASSWORD_DEFAULT}"
    case "$PG_PASSWORD" in
        *\'*|*' '*)
            echo_e "${RED}❌ 自定义 PG_PASSWORD 含单引号或空格，无法安全用于数据库与连接 URL，请更换${NC}"
            exit 1
            ;;
        *@*|*:*|*/*|*#*|*\?*)
            echo_e "${YELLOW}⚠️ 自定义 PG_PASSWORD 含 URL 特殊字符（@ : / # ?），如遇连接失败请改用字母数字组合${NC}"
            ;;
    esac
    export PG_USER PG_PASSWORD PG_DB
}

# V10.10.20: 智能匹配 PG 镜像数据目录挂载路径（对齐萌芽 DB_DATA_DIR 机制）
# PostgreSQL 18+（含 pgvector/pgvector:pg18）PGDATA 为 /var/lib/postgresql；
# 15/16/14 及 alpine 变体为 /var/lib/postgresql/data
# 挂载路径与镜像不匹配会导致数据不落持久卷，容器删除即数据丢失
detect_pg_data_dir() {
    case "$1" in
        *18*|*pg18*) echo "/var/lib/postgresql" ;;
        *15*|*16*|*14*|*alpine*) echo "/var/lib/postgresql/data" ;;
        *) echo "/var/lib/postgresql" ;;
    esac
}

# 共享 PG 模式（对齐萌芽 shared 分支：复用已有 PG 容器 + 接入自有网络，不生成 override）
setup_shared_pg() {
    if [ -z "$DB_PG_CONTAINER" ]; then
        echo_e "${RED}共享 PG 模式需要指定 DB_PG_CONTAINER 环境变量${NC}"
        exit 1
    fi
    # 校验共享 PG 容器确实在运行，避免生成指向失效容器的配置
    # V10.10.25: docker ps 会把崩溃循环（Restarting）容器也列出，改用 State.Status 严格判定
    if [ "$(docker inspect --format '{{.State.Status}}' "$DB_PG_CONTAINER" 2>/dev/null)" != "running" ]; then
        echo_e "${RED}❌ 共享 PG 容器 ${DB_PG_CONTAINER} 未在正常运行（状态: $(docker inspect --format '{{.State.Status}}' "$DB_PG_CONTAINER" 2>/dev/null || echo 不存在)），最后 15 行日志如下：${NC}"
        docker logs --tail 15 "$DB_PG_CONTAINER" 2>&1 | sed 's/^/    /' | head -20
        echo_e "${RED}  请先修复该容器，或执行 ./$(basename "$0") restart --reconfig 重新选择数据库模式${NC}"
        exit 1
    fi
    # V10.10.25: 检测容器真实超级用户（POSTGRES_USER env，无则 postgres）
    PG_SUPERUSER=$(detect_pg_superuser "$DB_PG_CONTAINER")
    # V10.10.20: 连接参数解析（PG_USER/PG_PASSWORD/PG_DB 可自定义，未指定用默认值）
    resolve_pg_conn_params
    # 幂等创建/更新账号与库（已有部署时 ALTER 同步密码、保留数据）
    # V10.10.22: ALTER USER 不再静默吞错——失败则报错终止，避免 DATABASE_URL 密码与 PG 实际密码不匹配
    # V10.10.25: psql 统一 docker exec -u postgres（OS 级 peer 认证，无需密码）+ 已检测的真实超级用户名
    if docker exec -u postgres "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'" 2>/dev/null | grep -q 1; then
        if ! pg_sync_password "$DB_PG_CONTAINER" "$PG_SUPERUSER" "$PG_USER" "$PG_PASSWORD"; then
            echo_e "${RED}❌ 共享 PG 密码同步失败，请检查容器 $DB_PG_CONTAINER 的超级用户权限${NC}"
            return 1
        fi
    else
        docker exec -u postgres "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo_e "${RED}❌ CREATE USER $PG_USER 失败，请检查容器 $DB_PG_CONTAINER 的超级用户 $PG_SUPERUSER 权限${NC}"
            return 1
        fi
    fi
    docker exec -u postgres "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" 2>/dev/null | grep -q 1 || \
        docker exec -u postgres "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE DATABASE $PG_DB OWNER $PG_USER;" >/dev/null 2>&1 || true
    docker exec -u postgres "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "GRANT ALL ON DATABASE $PG_DB TO $PG_USER;" >/dev/null 2>&1 || true
    # V10.10.20: PG_PORT 可自定义共享容器的连接端口（默认 PG_PORT_DEFAULT，定义于 bin/config.sh）
    PG_PORT="${PG_PORT:-$PG_PORT_DEFAULT}"
    DATABASE_URL="postgresql://${PG_USER}:${PG_PASSWORD}@${DB_PG_CONTAINER}:${PG_PORT}/${PG_DB}"
    export DATABASE_URL PG_PORT
    rm -f "$DB_OVERRIDE"
    # 对齐萌芽：网络已存在时立即把共享 PG 容器接入 gift 自有网络（幂等，不影响其原有网络与其他项目）
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qx "gift-docker_net"; then
        docker network connect gift-docker_net "$DB_PG_CONTAINER" 2>/dev/null || true
        echo_e "${GREEN}数据库模式: 共享 PostgreSQL (${DB_PG_CONTAINER})，已接入自有网络 gift-docker_net${NC}"
    else
        echo_e "${GREEN}数据库模式: 共享 PostgreSQL (${DB_PG_CONTAINER})${NC}"
        echo_e "${YELLOW}  网络 gift-docker_net 尚未创建，容器集群启动后将自动接入 ${DB_PG_CONTAINER}${NC}"
    fi
}

# 独立 PG 模式（对齐萌芽 dedicated：静态 docker-compose.db.yml 按 -f 合成，不生成 override）
# V10.10.20: 镜像优先级链 —— PG_IMAGE（用户自定义）> 本地已存在镜像（detect_pg_environment）> 默认镜像自动下载（postgres:16-alpine，可 PG_IMAGE_DEFAULT 覆盖）
setup_independent_pg() {
    # ① 用户自定义镜像（最高优先）
    if [ -n "$PG_IMAGE" ]; then
        PG_LOCAL_IMAGE="$PG_IMAGE"
        echo_e "${GREEN} 使用用户自定义 PG 镜像: ${PG_LOCAL_IMAGE}${NC}"
    fi
    # ② 本地已存在 PG 镜像（由 detect_pg_environment 预检测填充 PG_LOCAL_IMAGE）
    if [ -z "$PG_LOCAL_IMAGE" ]; then
        # ③ 本地无任何 PG 镜像：自动下载内置默认镜像（不再询问，非交互同样适用）
        echo_e "${YELLOW}  本地未检测到任何 PostgreSQL 镜像，自动下载内置默认镜像 ${PG_IMAGE_DEFAULT:-postgres:16-alpine} ...${NC}"
        PG_LOCAL_IMAGE="${PG_IMAGE_DEFAULT:-postgres:16-alpine}"
        if ! docker pull "$PG_LOCAL_IMAGE"; then
            echo_e "${RED}❌ 默认 PG 镜像下载失败，请检查网络，或改用 PG_IMAGE 指定自定义镜像后重试；降级为 SQLite 模式${NC}"
            DB_MODE=sqlite; setup_sqlite; return
        fi
        echo_e "${GREEN}✅ 默认镜像已下载: ${PG_LOCAL_IMAGE}${NC}"
    fi
    # V10.10.20: 连接参数解析（PG_USER/PG_PASSWORD/PG_DB 可自定义，未指定用默认值）
    resolve_pg_conn_params
    # V10.10.20: 按镜像智能匹配数据目录挂载路径，供 docker-compose.db.yml 的 ${PG_DATA_DIR} 插值
    PG_DATA_DIR=$(detect_pg_data_dir "$PG_LOCAL_IMAGE")
    export PG_PASSWORD PG_LOCAL_IMAGE PG_DATA_DIR PG_USER PG_DB
    # 独立模式容器内端口固定 5432（PG_PORT 仅共享模式生效）
    DATABASE_URL="postgresql://${PG_USER}:${PG_PASSWORD}@pg:5432/${PG_DB}"
    export DATABASE_URL
    rm -f "$DB_OVERRIDE"
    echo_e "${GREEN}数据库模式: 独立 PostgreSQL (${PG_LOCAL_IMAGE}，挂载 ${PG_DATA_DIR}，库 ${PG_DB}/账号 ${PG_USER})${NC}"
}
