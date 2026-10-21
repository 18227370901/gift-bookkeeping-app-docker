# ============================================================
# V10.10.16 性能优化：多阶段构建
# Stage 1 (builder): 安装 Python 依赖
# Stage 2 (runner): 仅拷贝 site-packages + 应用代码，不含构建工具链
# ============================================================

FROM python:3.11-slim AS builder

WORKDIR /app

# 安装构建依赖（编译 cryptography/psycopg2 等 C 扩展所需）
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libffi-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# 复制依赖文件并安装到独立目录（便于 Stage 2 精确拷贝）
COPY requirements.txt /app/
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.11-slim AS runner

WORKDIR /app

# 设置环境变量
# V10.10.16: MALLOC_ARENA_MAX=2 限制 glibc 多线程内存池碎片（gthread 模式下实测省 5~15% RSS）
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SESSION_COOKIE_SECURE=true \
    MALLOC_ARENA_MAX=2 \
    GUNICORN_WORKERS=2

# 安装运行时系统依赖（仅 curl 用于健康检查，libffi/libssl 运行库供 C 扩展使用）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    libffi8 \
    libssl3 \
    fonts-wqy-microhei \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 阶段拷贝已安装的 Python 依赖
COPY --from=builder /install /usr/local

# 复制应用代码
COPY . /app/

# V10.11.28 (对齐传统版运行目录修复)：logs/ 已被 .dockerignore 排除（不打入镜像），
# 此处预置空目录——容器内运行期写入点（weather/holiday 磁盘缓存、数据库恢复备份）虽有
# Python makedirs 兜底，预置目录可消除首个请求的兜底创建窗口并规范化镜像结构
RUN mkdir -p /app/logs

# 暴露 Flask Gunicorn 端口
EXPOSE 11443

# 使用 Gunicorn 配置文件启动（workers/threads/timeout 等参数均由 gunicorn.conf.py 控制）
# V10.11.17 (ADR-42): 标准容器健康检查探针
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://127.0.0.1:11443/health || exit 1

CMD ["gunicorn", "-c", "gunicorn.conf.py", "app:app"]
