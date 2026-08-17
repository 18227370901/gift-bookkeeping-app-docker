# 人情礼金记账系统 (Docker Compose 自动化部署版)

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://www.docker.com/)
[![Flask](https://img.shields.io/badge/Flask-3.0.3-green.svg)](https://flask.palletsprojects.com/)
[![Nginx](https://img.shields.io/badge/Nginx-SSL_Proxy-brightgreen.svg)](https://nginx.org/)

> **最新更新说明**：更新并同步全站 CSRF 安全防护机制与最新前端模板，全面支持登录无操作超时动态设置、批量日志清空与账户密码/密保重置防护。

---

## 🚀 Docker Compose 部署指南

### 1. 克隆代码库
```bash
git clone https://github.com/18227370901/gift-bookkeeping-app-docker.git
cd gift-bookkeeping-app-docker
```

### 2. 准备 SSL 证书
将您的 SSL 证书公钥 `server.crt` 和私钥 `server.key` 放置于根目录下的 `ssl/` 文件夹中：
```bash
mkdir -p ssl
# 将您的 server.crt 和 server.key 复制进 ssl 文件夹
```
> 💡 **快速测试证书生成**：如果没有真实证书，可先运行项目内置的生成脚本一键创建测试证书：
> ```bash
> python generate_ssl_certs.py
> mkdir -p ssl && mv server.crt server.key ssl/
> ```

### 3. 一键启动 Docker 容器集群
在项目根目录下运行：
```bash
docker-compose up -d --build
```

### 4. 访问系统
- **HTTPS 端口**：打开浏览器访问 **`https://<您的服务器IP或域名>:1443`**
- **HTTP 自动重定向**：访问 `http://<您的服务器IP或域名>:80` 将自动重定向至自定义 1443 端口。

---

## 🛠️ Docker 容器架构

- **`web` 容器**：基于 Python 3.11-slim，运行 Gunicorn 多进程 Web 服务器，处理 Flask 业务逻辑，数据存储于 Docker 挂载数据卷 `gift_data`。
- **`nginx` 容器**：基于 Nginx Alpine 镜像，实现 SSL/TLS 卸载与反向代理转发（HTTP 80 -> HTTPS 1443），配置了完整的 Web 安全响应头（HSTS、X-Frame-Options 等）。

---

## ⚙️ 常用运维指令

- **查看容器日志**：
  ```bash
  docker-compose logs -f
  ```
- **停止服务**：
  ```bash
  docker-compose down
  ```
- **重启服务**：
  ```bash
  docker-compose restart
  ```
- **更新版本重构**：
  ```bash
  git pull
  docker-compose up -d --build
  ```

---

## 默认管理员账户与安全提醒
- 系统初次启动时已预置默认管理员账户，建议成功部署后立即更改密码并设置密保问题！
