# 人情礼金记账系统 Docker 部署与运维手册 (Deployment & Operation)

> 本文档详细介绍了系统在本地及各类 Linux 生产服务器上的 Docker Compose 编排部署、运维、反向代理、SSL 证书及 Git 更新处理方案。  
> 快速启动请参考主页 [README.md](../README.md)。

---

## 目录
- [一、本地与服务器运行指南](#一本地与服务器运行指南)
- [二、Docker 镜像免构建部署 (V10.10.16)](#二docker-镜像免构建部署-v101016)
- [三、SSL / HTTPS 部署与 Nginx 反向代理说明](#三ssl--https-部署与-nginx-反向代理说明)
- [四、Linux 服务器代码更新与冲突处理指南](#四linux-服务器代码更新与冲突处理指南)
- [五、项目多形态交付矩阵 (Ecosystem)](#五项目多形态交付矩阵-ecosystem)
- [六、开源许可证](#六开源许可证)

---

## 一、本地与服务器运行指南

### 1. 本地快速启动（Windows / macOS / Linux）

```bash
# 1. 安装项目依赖
pip install -r requirements.txt

# 2. 直接启动 Flask 应用（默认监听 11443 端口）
python app.py
```
> 访问地址：`http://127.0.0.1:11443` 或通过配置的反向代理域名访问。

---

### 2. 使用服务管理脚本 `run.sh`（推荐 Linux / 云服务器生产环境）

根目录下提供了自动化管理脚本 `run.sh`。执行 `start` 指令时，脚本会**自动检测并创建 Python 虚拟环境（`venv`）**，并**自动增量补齐所需依赖库**。

```bash
# 1. 赋予执行权限
chmod +x run.sh

# 2. 启动服务（自动创建 venv + 自动 install 依赖 + 自动生成 SSL 证书 + 后台启动）
./run.sh start

# 3. 查看服务运行状态（含访问地址、本地直连、日志与数据库模式）
./run.sh status

# 4. 重启服务
./run.sh restart

# 5. 停止服务
./run.sh stop
```

> 💡 **端口与账号自定义**：
> 环境变量可在执行命令时临时指定，也可写入 shell 配置后长期生效：`PORT`（后端端口，默认 11443）、`NGINX_PORT`（Nginx 对外监听端口，默认 443）、`ADMIN_USER` 与 `ADMIN_PASS`。执行 `start` 或 `restart` 时，系统会自动渲染 Nginx 配置并热重载生效。
> V10.10.21 起全部默认值集中定义于 `bin/config.sh`；每台服务器的持久差异化配置（账密/SNI 域名/端口/PG 默认值等）推荐写入 `bin/config.local.sh`（已被 .gitignore 忽略，git pull 永不冲突），三层优先级：命令行环境变量 > `config.local.sh` > 内置默认值。
>
> 💡 **多项目共用 443 端口 SNI 分流**（V10.10）：
> 同一台服务器多个项目可共用 443 端口，依靠域名区分流量，各项目启动时指定专属变量即可：
> ```bash
> PROJECT_NAME=mengyao SNI_DOMAIN=mengyao.example.com SNI_DEFAULT_SERVER=0 ./run.sh start
> ```
> - `PROJECT_NAME`：项目标识，决定 Nginx 配置文件名与 upstream 名（默认 gift_app）
> - `SNI_DOMAIN`：SNI 域名，写入 server_name 与证书 CN/SAN（默认 localhost）；支持空格分隔多域名，如 `SNI_DOMAIN="a.com b.com"`，第一个为证书 CN，全部写入 SAN 与 server_name
> - `SNI_DEFAULT_SERVER`：是否作为 443 兑底 default_server，多项目只应有一个设为 1（默认 1）
> - `SSL_CERT` / `SSL_KEY`：可指向正式证书路径，默认使用自动生成的自签证书
>
> ⚡ **V10.10.16 性能与环境变量**：
> ```bash
> # 内存与 CPU 优化（默认值即可，按需调整）
> GUNICORN_WORKERS=1 ./run.sh start       # Gunicorn worker 数量（默认 1，可调 2/4）
>
> # 镜像免构建部署（服务器零现场 pip install）
> APP_IMAGE=ghcr.io/18227370901/gift-bookkeeping-web:latest ./run.sh start
> ```
> - `GUNICORN_WORKERS`：Gunicorn worker 进程数（默认 1，单进程 + gthread 4 线程 = 4 并发，与原 4 sync workers 持平；家庭/小团队场景 1 个足够，高负载可调 2/4）
> - `APP_IMAGE`：预构建镜像地址（非空时 `docker compose pull` 拉取镜像直接启动，服务器零构建；为空时维持 `docker compose up -d --build` 本地构建，完全向后兼容）

---

## 二、Docker 镜像免构建部署 (V10.10.16)

传统部署方式每次 `./run.sh start` 都会在服务器上执行 `docker compose up -d --build`，触发 `pip install` 全量安装依赖，耗时 5~10 分钟并占用 CPU/内存。V10.10.16 新增镜像免构建模式，实现"构建一次、多服务器秒级部署"。

### 1. 自动构建（GitHub Actions）

项目已预置 `.github/workflows/docker-publish.yml`，触发条件：
- **push main**：自动构建并推送 `latest` + `sha-xxxxxxx` 标签
- **打 tag v***：自动构建并推送语义化版本标签（如 `v1.0.0` → `1.0.0` + `v1.0`）
- **手动触发**：GitHub Actions 页面 → `Build & Publish Docker Image` → `Run workflow`

推送的 Registry：
- **ghcr.io**（默认启用，零密钥配置）：`ghcr.io/18227370901/gift-bookkeeping-web:latest`
- **阿里云 ACR**（国内拉取更快，需配置 secrets 启用）：
  1. 仓库 Settings → Secrets and variables → Actions → New repository secret
  2. 新增 `ACR_USERNAME`（阿里云 ACR 用户名）和 `ACR_PASSWORD`（访问密码）
  3. 新增 Variables：`ACR_REGISTRY`（如 `registry.cn-hangzhou.aliyuncs.com`）、`ACR_NAMESPACE`（你的命名空间）
  4. 取消 `docker-publish.yml` 中阿里云 ACR 段的注释即可生效

### 2. 服务器免构建部署

```bash
# 首次部署或代码更新后（服务器不执行 pip install，仅拉取镜像）
cd /opt/service/gift-bookkeeping-app-docker
git pull origin main
APP_IMAGE=ghcr.io/18227370901/gift-bookkeeping-web:latest ./run.sh restart

# 如需增大并发（内存充裕时）
GUNICORN_WORKERS=2 APP_IMAGE=ghcr.io/18227370901/gift-bookkeeping-web:latest ./run.sh restart

# 回退到本地构建模式（不拉取镜像）
./run.sh restart
```

### 3. 性能效果

| 指标 | 原版（4 sync workers） | V10.10.16 优化后 |
|---|---|---|
| 常态内存 | 350~535MB | **60~95MB**（↓80%） |
| 并发能力 | 4 个请求 | 4 个请求（1 worker × 4 gthread） |
| 首次部署耗时 | 5~10 分钟（pip install） | **< 30 秒**（镜像拉取） |
| 后台守护线程 | 12 份（4 进程 × 3 线程） | **3 份**（单进程 1 份干活） |
| 定时备份竞态 | 4 进程可能重复执行 | **无**（fcntl 单实例锁） |

---

## 三、SSL / HTTPS 部署与 Nginx 反向代理说明

项目已提供开箱即用的 SSL/TLS 安全部署方案：

### 1. 生成自签名证书（内网/测试环境可选）
```bash
# 默认域名 localhost；建议通过 --domain 写入实际 SNI 域名，避免浏览器报证书域名不匹配
python tools/generate_ssl_certs.py --domain gift.example.com
# 也可指定有效期
python tools/generate_ssl_certs.py --domain gift.example.com --days 730
```
将在根目录 `ssl/` 下自动生成 `server.crt` 与 `server.key`（`--domain` 支持域名或 IP，写入证书 CN 与 SAN）。
> 注：`run.sh start` 会自动传入 `--domain $SNI_DOMAIN` 生成证书，无需手工执行。

### 2. Nginx 反向代理配置（模板渲染，V10.10 改为 SNI 多项目共用 443 端口）
1. 配置目录 `config/nginx_ssl.conf` 已改为**占位符模板**，不直接使用，由 `run.sh` 自动渲染输出到 Nginx 配置目录（如 `/etc/nginx/conf.d/gift_app.conf`），每个项目一份独立配置，共用 443 端口依靠 SNI 域名区分流量。
2. 默认启动（`./run.sh start`）即可自动完成配置同步；需要自定义时通过环境变量指定（见上节"多项目共用 443 端口 SNI 分流"）。
3. 检查 Nginx 语法并重载生效：
   ```bash
   nginx -t
   nginx -s reload
   ```

---

## 四、Linux 服务器代码更新与冲突处理指南

当项目需要从远程 Git 仓库拉取最新代码时，请参考以下最佳实践：

### 标准更新流程（本地无冲突修改）
```bash
cd /opt/service/gift-bookkeeping-app
git pull origin main
./run.sh restart
```

### ⚠️ 当本地配置文件有改动时的推荐方案

**V10.10.21 推荐做法（一劳永逸）**：把服务器专属配置（账密/SNI 域名/端口等）迁移到 `bin/config.local.sh`（已被 .gitignore 忽略，git pull 永不冲突），之后每次更新只需 `git pull && ./run.sh restart`：
```bash
# 一次性迁移（示例：自定义管理员账密与 SNI 域名；沿用 ${变量:-值} 写法可使命令行环境变量临时覆盖）
cat > bin/config.local.sh <<'EOF'
ADMIN_USER="${ADMIN_USER:-myadmin}"
ADMIN_PASS="${ADMIN_PASS:-MyStrongPass2026}"
SNI_DOMAIN="${SNI_DOMAIN:-gift.example.com}"
EOF

# 日常更新（不再需要 stash）
git pull origin main
./run.sh restart
```

**历史遗留方案（曾直接修改 run.sh 配置区的存量服务器首次升级时使用）**：原 run.sh 顶部配置区在 V10.10.21 已拆分至 `bin/config.sh`，请先把原定制值按上例迁移到 `bin/config.local.sh`，再执行标准更新流程；迁移前可临时使用 git stash：
```bash
# 1. 暂存本地修改
git stash push -m "暂存本地配置"

# 2. 拉取远程最新代码
git pull origin main

# 3. 恢复本地修改并合并
git stash pop

# 4. 重启服务使更新生效
./run.sh restart
```

---



## 五、项目多形态交付矩阵 (Ecosystem)

本套人情礼金记账系统提供三种产品部署与交付形态，源码均已同步发布至 GitHub：

| 形态 | GitHub 仓库地址 | 适用场景 |
|:---|:---|:---|
| 🖥️ **Web 原生部署版** | [gift-bookkeeping-app](https://github.com/18227370901/gift-bookkeeping-app.git) | 适合本地 Python 环境、虚拟主机、轻量 VPS 单机运行 |
| 🐳 **Docker Compose 版** | [gift-bookkeeping-app-docker](https://github.com/18227370901/gift-bookkeeping-app-docker.git) | 适合企业生产服务器、一键容器编排、Nginx 反代与 SSL 自动化管理 |
| 📱 **Android 原生 APK 版** | [gift_bookkeeping_apk](https://github.com/18227370901/gift_bookkeeping_apk.git) | 适合安卓手机与平板脱机随身离线使用 |

## 六、开源许可证
