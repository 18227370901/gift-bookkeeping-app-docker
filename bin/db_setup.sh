#!/bin/sh
# db_setup.sh (Docker版) — 数据库模式配置函数（SQLite/共享PG/独立PG + compose override 生成）

# SQLite 模式：清理 override 文件
setup_sqlite() {
    DATABASE_URL=""
    export DATABASE_URL
    rm -f "$DB_OVERRIDE"
    echo_e "${GREEN}数据库模式: SQLite 本地文件${NC}"
}

# 共享 PG 模式（Docker 版：生成 compose override 加入 PG 容器网络）
setup_shared_pg() {
    if [ -z "$DB_PG_CONTAINER" ]; then
        echo_e "${RED}共享 PG 模式需要指定 DB_PG_CONTAINER 环境变量${NC}"
        exit 1
    fi
    PG_SUPERUSER=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$DB_PG_CONTAINER" 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2)
    PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
    PG_NETWORK=$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$DB_PG_CONTAINER" 2>/dev/null)
    PG_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE USER gift_user WITH PASSWORD '$PG_PASSWORD';" 2>/dev/null || true
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "CREATE DATABASE gift_bookkeeping OWNER gift_user;" 2>/dev/null || true
    docker exec "$DB_PG_CONTAINER" psql -U "$PG_SUPERUSER" -c "GRANT ALL ON DATABASE gift_bookkeeping TO gift_user;" 2>/dev/null || true
    DATABASE_URL="postgresql://gift_user:${PG_PASSWORD}@${DB_PG_CONTAINER}:5432/gift_bookkeeping"
    export DATABASE_URL
    mkdir -p "$APP_DIR/.temp"
    cat > "$DB_OVERRIDE" << YAMLEOF
version: '3.8'
services:
  web:
    environment:
      - DATABASE_URL=${DATABASE_URL}
    networks:
      - gift_network
      - pg_external
networks:
  pg_external:
    external: true
    name: ${PG_NETWORK}
YAMLEOF
    echo_e "${GREEN}数据库模式: 共享 PostgreSQL (${DB_PG_CONTAINER}, 网络 ${PG_NETWORK})${NC}"
}

# 独立 PG 模式（Docker 版：生成 compose override 添加 pg 服务）
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
    DATABASE_URL="postgresql://gift_user:${PG_PASSWORD}@pg:5432/gift_bookkeeping"
    export DATABASE_URL
    mkdir -p "$APP_DIR/.temp"
    cat > "$DB_OVERRIDE" << YAMLEOF
version: '3.8'
services:
  pg:
    image: ${PG_LOCAL_IMAGE}
    restart: unless-stopped
    environment:
      - POSTGRES_DB=gift_bookkeeping
      - POSTGRES_USER=gift_user
      - POSTGRES_PASSWORD=${PG_PASSWORD}
    volumes:
      - gift_pg_data:/var/lib/postgresql/data
    networks:
      - gift_network
  web:
    environment:
      - DATABASE_URL=${DATABASE_URL}
    depends_on:
      - pg
volumes:
  gift_pg_data:
    driver: local
YAMLEOF
    echo_e "${GREEN}数据库模式: 独立 PostgreSQL (${PG_LOCAL_IMAGE})${NC}"
}
