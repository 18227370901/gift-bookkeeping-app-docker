#!/bin/sh
# cleanup.sh (Docker版) — Docker 依赖检查 + 缓存清理

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

# ===== 清理缓存与 .git 冗余垃圾 + Docker 构建缓存 =====
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
    # Docker 构建缓存清理：清理悬空镜像与构建缓存（不影响正在运行的容器和其他项目的镜像）
    if command -v docker > /dev/null 2>&1; then
        local _df_before=$(docker system df --format '{{.Type}}:{{.Size}}' 2>/dev/null | grep -E '^(Images|Build Cache):' | tr '\n' '; ')
        docker image prune -f 2>/dev/null || true
        docker builder prune -f 2>/dev/null || true
        echo_e "${GREEN}✅ Docker 构建缓存清理完成（悬空镜像 + 构建缓存）${NC}"
        local _df_after=$(docker system df --format '{{.Type}}:{{.Size}}' 2>/dev/null | grep -E '^(Images|Build Cache):' | tr '\n' '; ')
        if [ -n "$_df_before" ] && [ -n "$_df_after" ]; then
            echo_e "   Docker 占用变化: [清理前] $_df_before"
            echo_e "   Docker 占用变化: [清理后] $_df_after"
        fi
    fi
}
