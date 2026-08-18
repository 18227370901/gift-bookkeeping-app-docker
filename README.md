# 人情礼金记账系统 (Docker Compose 自动化部署版)

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://www.docker.com/)
[![Flask](https://img.shields.io/badge/Flask-3.0.3-green.svg)](https://flask.palletsprojects.com/)
[![Nginx](https://img.shields.io/badge/Nginx-SSL_Proxy-brightgreen.svg)](https://nginx.org/)

> **最新更新说明**：
> - 👑 **管理员用户管理增强**：管理员可实时启用/禁用/删除普通用户，被禁用账号无法登录并显示“联系管理员处理”提示，已登录用户在被禁用或删除后将被即时拦截强制下线。
> - 🛠️ **自动化运维与依赖管理**：启动脚本 `run.sh` 自动判断并创建 Python 虚拟环境（`venv`）及安装 `requirements.txt` 依赖库，免除手动执行命令；支持通过环境变量自定义 admin 账号与密码。
> - 🧹 **冗余清理**：项目已彻底清理打包 exe/apk 等不必要文件及历史构件，精简项目体积。

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
docker compose up -d --build
```

### 4. 访问系统
- **HTTPS 端口**：打开浏览器访问 **`https://<您的服务器IP或域名>:1443`**

---

## 🐍 运行脚本 `run.sh` 服务管理（非 Docker 环境）

根目录下提供了服务管理脚本 `run.sh`。运行 `start` 指令时，脚本会**自动判断并创建 Python 虚拟环境（`venv`）**，并**自动安装 `requirements.txt` 中所需依赖**，无需手动执行繁琐命令。

```bash
# 1. 赋予可执行权限
chmod +x run.sh

# 2. 启动服务（自动创建 venv + 自动 install 依赖 + 后台启动 Flask）
./run.sh start

# 3. 服务管理指令
./run.sh start    # 启动服务
./run.sh stop     # 停止服务
./run.sh status   # 查看状态
./run.sh restart  # 重启服务
```

> 💡 **自定义管理员账号密码与端口**：
> 可在 `run.sh` 脚本头的环境变量配置区域修改 `ADMIN_USER` 和 `ADMIN_PASS`（支持特殊字符），启动时系统将自动初始化或更新该管理员账号。

---

## ⚙️ 常用运维指令

- **查看容器日志**：
  ```bash
  docker compose logs -f
  ```
- **停止服务**：
  ```bash
  docker compose down
  ```
- **重启服务**：
  ```bash
  docker compose restart
  ```
- **更新版本重构**：
  ```bash
  git pull
  docker compose up -d --build
  ```

---

## 🔑 默认管理员账户与安全提醒
- 系统启动时会自动根据配置初始化管理员账户，建议成功部署后登录并设置密保问题！

