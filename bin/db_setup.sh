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
    PG_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    # 幂等创建/更新 gift 账号与库（已有部署时 ALTER 同步密码、保留数据，避免 CREATE USER 已存在导致密码与 DATABASE_URL 不匹配）
    if docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_roles WHERE rolname='gift_user'" 2>/dev/null | grep -q 1; then
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "ALTER USER gift_user WITH PASSWORD '$PG_PASSWORD';" >/dev/null 2>&1 || true
    else
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE USER gift_user WITH PASSWORD '$PG_PASSWORD';" >/dev/null 2>&1 || true
    fi
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -tAc "SELECT 1 FROM pg_database WHERE datname='gift_bookkeeping'" 2>/dev/null | grep -q 1 || \
        docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE DATABASE gift_bookkeeping OWNER gift_user;" >/dev/null 2>&1 || true
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "GRANT ALL ON DATABASE gift_bookkeeping TO gift_user;" >/dev/null 2>&1 || true
    DATABASE_URL="postgresql://gift_user:${PG_PASSWORD}@${DB_PG_CONTAINER}:5432/gift_bookkeeping"
    export DATABASE_URL
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

# 独立 PG 模式（对齐萌芽 dedicated 分支：静态 docker-compose.db.yml 按 -f 合成，不生成 override）
setup_independent_pg() {
    if [ -z "$PG_LOCAL_IMAGE" ]; then
        echo_e "${YELLOW}本地未找到 PostgreSQL 镜像。${NC}"
        if [ -t 0 ]; then
            printf '是否允许下载 postgres:16-alpine (约40MB)? (y/n) [默认 n]: ' >&2
            read -r _dl_answer
            case "$_dl_answer" in
                y|Y|yes|YES) PG_LOCAL_IMAGE="postgres:16-alpine" ;;
                *) echo_e "${YELLOW}用户取消下载，降级为 SQLite 模式${NC}"; DB_MODE=sqlite; setup_sqlite; return ;;
            esac
        else
            echo_e "${YELLOW}非交互环境无法下载，降级为 SQLite 模式${NC}"
            DB_MODE=sqlite; setup_sqlite; return
        fi
    fi
    PG_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    # V10.10.20: 按镜像智能匹配数据目录挂载路径，供 docker-compose.db.yml 的 ${PG_DATA_DIR} 插值
    PG_DATA_DIR=$(detect_pg_data_dir "$PG_LOCAL_IMAGE")
    export PG_PASSWORD PG_LOCAL_IMAGE PG_DATA_DIR
    DATABASE_URL="postgresql://gift_user:${PG_PASSWORD}@pg:5432/gift_bookkeeping"
    export DATABASE_URL
    rm -f "$DB_OVERRIDE"
    echo_e "${GREEN}数据库模式: 独立 PostgreSQL (${PG_LOCAL_IMAGE}，挂载 ${PG_DATA_DIR})${NC}"
}
