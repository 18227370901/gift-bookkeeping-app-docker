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
    GUNICORN_WORKERS=1

# 安装运行时系统依赖（仅 curl 用于健康检查，libffi/libssl 运行库供 C 扩展使用）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    libffi8 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 阶段拷贝已安装的 Python 依赖
COPY --from=builder /install /usr/local

# 复制应用代码
COPY . /app/

# 暴露 Flask Gunicorn 端口
EXPOSE 11443

# 使用 Gunicorn 配置文件启动（workers/threads/timeout 等参数均由 gunicorn.conf.py 控制）
CMD ["gunicorn", "-c", "gunicorn.conf.py", "app:app"]
