#!/bin/sh
# db_setup.sh (Docker版) — 数据库模式配置函数（V10.10.20 对齐 mengya-docker 部署模式）
# 架构变化：
#   - 彻底移除 .temp/docker-compose.db-override.yml 动态 override 文件机制（根治 external 网络失效启动失败）
#   - DATABASE_URL 由 run.sh 经 shell 环境变量插值注入 compose（docker-compose.yml 的 ${DATABASE_URL:-}）
#   - 独立 PG：由静态 docker-compose.db.yml 按 -f 参数按需合成（萌芽同款 COMPOSE_FILE 机制）
#   - 共享 PG：通过 docker network connect 把共享 PG 容器接入 gift 自有网络 gift-docker_net（萌芽同款）
#   - 网络永不声明 external；旧 override 残留文件在各模式中顺手清理

# SQLite 模式：清空 DATABASE_URL 并清理旧机制残留 override 文件
setup_sqlite() {
    DATABASE_URL=""
    export DATABASE_URL
    rm -f "$DB_OVERRIDE"
    echo_e "${GREEN}数据库模式: SQLite 本地文件${NC}"
}

# V10.10.20: PG 连接参数解析（用户自定义 > 默认值）
# PG_USER/PG_PASSWORD/PG_DB 环境变量可自定义；未指定时使用默认值（gift_user / 随机 16 位 / gift_bookkeeping）
# 密码校验：单引号/空格直接拒绝（无法安全拼入 SQL 与 URL）；URL 特殊字符警告
resolve_pg_conn_params() {
    PG_USER="${PG_USER:-gift_user}"
    PG_DB="${PG_DB:-gift_bookkeeping}"
    if [ -z "$PG_PASSWORD" ]; then
        PG_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    else
        case "$PG_PASSWORD" in
            *\'*|*' '*)
                echo_e "${RED}❌ 自定义 PG_PASSWORD 含单引号或空格，无法安全用于数据库与连接 URL，请更换${NC}"
                exit 1
                ;;
            *@*|*:*|*/*|*#*|*\?*)
                echo_e "${YELLOW}⚠️ 自定义 PG_PASSWORD 含 URL 特殊字符（@ : / # ?），如遇连接失败请改用字母数字组合${NC}"
                ;;
        esac
    fi
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
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_PG_CONTAINER"; then
        echo_e "${RED}❌ 共享 PG 容器 ${DB_PG_CONTAINER} 未在运行，请先启动该容器，或执行 DB_RESET=1 ./$(basename "$0") start 重新选择数据库模式${NC}"
        exit 1
    fi
    PG_SUPERUSER=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$DB_PG_CONTAINER" 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2)
    PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
    # V10.10.20: 连接参数解析（PG_USER/PG_PASSWORD/PG_DB 可自定义，未指定用默认值）
    resolve_pg_conn_params
    # 幂等创建/更新账号与库（已有部署时 ALTER 同步密码、保留数据，避免 CREATE USER 已存在导致密码与 DATABASE_URL 不匹配）
    if docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'" 2>/dev/null | grep -q 1; then
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "ALTER USER $PG_USER WITH PASSWORD '$PG_PASSWORD';" >/dev/null 2>&1 || true
    else
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';" >/dev/null 2>&1 || true
    fi
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" 2>/dev/null | grep -q 1 || \
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE DATABASE $PG_DB OWNER $PG_USER;" >/dev/null 2>&1 || true
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "GRANT ALL ON DATABASE $PG_DB TO $PG_USER;" >/dev/null 2>&1 || true
    # V10.10.20: PG_PORT 可自定义共享容器的连接端口（默认 5432）
    PG_PORT="${PG_PORT:-5432}"
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
        echo_e "${YELLOW}  本地未检测到任何 PostgreSQL 镜像，自动下载内置默认镜像 postgres:16-alpine ...${NC}"
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
