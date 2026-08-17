FROM python:3.11-slim

# 设置工作目录
WORKDIR /app

# 设置环境变量
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SESSION_COOKIE_SECURE=true

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 复制依赖文件并安装
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# 复制应用代码
COPY . /app/

# 暴露 Flask Gunicorn 端口
EXPOSE 5000

# 运行 Gunicorn WSGI 服务器
CMD ["gunicorn", "--workers=4", "--bind=0.0.0.0:5000", "app:app"]
