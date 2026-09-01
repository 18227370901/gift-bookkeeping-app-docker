# 人情礼金记账系统 (Docker Compose 自动化部署版)

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://www.docker.com/)
[![Flask](https://img.shields.io/badge/Flask-3.0.3-green.svg)](https://flask.palletsprojects.com/)
[![Nginx](https://img.shields.io/badge/Nginx-SSL_Proxy-brightgreen.svg)](https://nginx.org/)

> **最新更新说明**：
> - 🛡️ **密保找回密码算术验证码与动态刷新**：找回密码流程全面接入算术验证码防护机制（支持 `/forgot-password/captcha` 接口无感拉取与动态点击刷新），有效防御针对密保答案的自动化暴力破解与脚本探测。
> - ⏳ **管理员/普通用户找回密码防爆破与倒计时临时锁定**：密保答案错误触发递增计数与错误上限预警；达到上限后自动进入临时冷却锁定状态（支持毫秒级动态倒计时实时解锁），阻断高频撞库风险。
> - 🔑 **密码复杂度校验机制**：重置密码与修改密码全面接入密码复杂度验证（至少6位且同时包含字母与数字），严控弱口令风险。
> - 🛡️ **密保找回密码防爆破限制与临时锁定**：找回密码输入密保答案时引入错误次数限制机制（默认3次），超过限制自动触发临时锁定保护并展示倒计时；支持管理员在后台动态配置最大错误尝试次数。
> - 👥 **用户跨权限管理与层级控制**：管理员可为普通用户精细化配置跨用户数据权限（查看他人、编辑他人、删除他人），层级向下兼容包含。
> - 🧹 **示例数据与脱敏清洗**：移除所有个人敏感历史记录与附加账号，数据库重置为仅保留默认管理员（账号 `admin`，密码 `admin123`），并包含 66 条合成的测试随礼记录方便开箱即用。
> - 📥 **导入样例表格下载与必填规则标注**：新增导出 CSV 样例模版功能，提供标准填写参考；导入弹窗明确保留了各字段规则并突出标注必填字段（客人姓名、礼金金额、办席原因）。
> - 🔑 **默认管理员账号与密保说明**：系统默认管理员账号为 `admin`，初始密码为 `admin123`；默认密保问题为“系统默认安全问题：您的默认备用验证码是？”，默认密保答案为 **`admin`**（支持登录后自行修改）。
> - 🔄 **登录流程重定向与刷新防护 (PRG模式)**：将登录失败处理重构为 Post-Redirect-Get (PRG) 模式。页面刷新时触发无副作用的 GET 请求拉取风险状态，彻底防止刷新页面导致密码错误尝试计数人工累加。
> - 🛡️ **CSRF Token 自动恢复与友好拦截**：`@app.before_request` 钩子自动补全 Session 中的 CSRF 令牌，并在表单 CSRF 令牌过期或失配时拦截 403 异常，通过 Flash 消息引导用户重试而非直接抛出错误。
> - 🛡️ **登录风控跨用户隔离修复**：优化登录风控机制为特定用户名独立的隔离计数字典，修复先前在登录框切换不同用户名会导致累计错误次数归零绕过风控的漏洞。
> - ⚡ **自定义端口动态同步 Nginx**：`run.sh` 脚本支持 `PORT`（容器内端口，默认 11443）、`HOST_PORT`（宿主机映射端口，默认 15000）与 `NGINX_PORT`（Nginx 监听端口，默认 15001）自定义配置，启动/重启时可自动将端口映射更新至 `docker-compose.yml` 及 Nginx 配置文件 `gift_app_docker.conf` 并热重载生效。
> - 🔒 **每次启动自动刷新 SSL 证书**：`run.sh` 执行 `start` 或 `restart` 时自动调用 `generate_ssl_certs.py` 生成最新自签名 SSL 证书，提升通信安全。
> - 🛡️ **登录风控防暴力破解与管理员自定义配置**：连续失败达到阈值自动启用算术验证码，支持管理员在后台自定义“最大失败次数”及“锁定等待时长（秒）”。
> - 📱 **移动端响应式布局优化**：全面优化移动端界面显示，表格与按钮响应式适配。
> - 🌐 **自动化 Nginx 配置与同步**：`run.sh` 脚本自动完成宿主机 Nginx 配置文件同步、冲突排查与重载。
> - 🧹 **自动缓存与 Git 清理**：自动清理 Python 缓存文件及 Git 冗余对象。
> - 🐳 **Docker 配置化精简**：移除默认内置 PostgreSQL 容器，默认采用高可靠本地 SQLite 存储，并支持外部 DATABASE_URL 扩展。

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

### 3. 访问系统
- **HTTPS 端口**：打开浏览器访问 **`https://<您的服务器IP或域名>:15001`**（宿主机 15001 端口经 Nginx 映射至容器内部 11443 端口）

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

> 💡 **自定义管理员账号密码与端口拓扑**：
> 可在 `run.sh` 脚本头的环境变量配置区域修改 `PORT`（Web容器端口，默认 11443）、`HOST_PORT`（宿主机映射端口，默认 15000）、`NGINX_PORT`（Nginx监听端口，默认 15001）、`ADMIN_USER` 和 `ADMIN_PASS`。
> 端口转发链路拓扑为：**客户端 -> 宿主机 Nginx (HTTPS $NGINX_PORT端口) -> 宿主机映射端口 (127.0.0.1:$HOST_PORT) -> Web容器应用 ($PORT端口)**。
> 在执行 `./run.sh start` 或 `./run.sh restart` 时，系统将自动将设置的端口更新至 `docker-compose.yml` 及 Nginx 配置文件 `gift_app_docker.conf` 中并重载生效。

---

## ⚙️ 常用运维指令与 `run.sh` 使用指南

本项目提供了标准的 Docker 生命周期管理脚本 `run.sh`：

```bash
chmod +x run.sh

./run.sh start    # 自动检查/生成 SSL 证书，并使用 Docker Compose 启动容器集群 (暴露宿主机 15000 端口)
./run.sh stop     # 停止并移除 Docker 容器集群
./run.sh restart  # 重启 Docker 容器集群
./run.sh status   # 查看 Docker 容器运行状态 (或 ./run.sh ps)
./run.sh logs     # 实时查看 Docker 容器日志
./run.sh build    # 重新构建 Docker 镜像
```

---

## 🚀 首次部署指导操作说明

### 1. 克隆代码库到 Linux 服务器
```bash
git clone https://github.com/18227370901/gift-bookkeeping-app-docker.git /opt/service/gift-bookkeeping-app-docker
cd /opt/service/gift-bookkeeping-app-docker
```

### 2. 使用 `run.sh` 一键部署 Docker 集群
```bash
chmod +x run.sh
./run.sh start
```
> 💡 **端口暴露机制**：Web 容器内开放 `11443` 端口，通过 `docker-compose.yml` 映射暴露为宿主机的 `15000` 端口（避免占用宿主机 15001 端口）。

### 3. 配置宿主机 Nginx SSL 反向代理 (监听 15001 端口)
```bash
# 1. 生成自签名 SSL 证书（用于测试环境）
python3 generate_ssl_certs.py

# 2. 将反向代理配置拷贝至宿主机 Nginx 配置目录 (如 /etc/nginx/conf.d/gift_app_docker.conf)
cp nginx_ssl.conf /etc/nginx/conf.d/gift_app_docker.conf

# 💡 注意：如果服务器上同时存在非 Docker 版本，不能在 /etc/nginx/conf.d/ 下同时启用两个 listen 15001 的配置文件，
# 否则 Nginx 默认会一直命中其中一个 Upstream，导致切换至另一个服务时报 502 Bad Gateway！
# 切换至 Docker 版本时，请禁用非 Docker 版本的配置：
mv /etc/nginx/conf.d/gift_app_native.conf /etc/nginx/conf.d/gift_app_native.conf.disabled 2>/dev/null || true

# 3. 校验配置并加载生效
nginx -t && nginx -s reload
```

---

## 🔄 Linux 服务器更新最新代码指南

在 Linux 服务器上应用 GitHub 云端最新代码的完整步骤如下：

### 标准更新步骤（本地无未提交修改）
```bash
# 1. 进入项目根目录
cd /opt/service/gift-bookkeeping-app-docker

# 2. 拉取最新代码
git pull origin main

# 3. 使用 run.sh 一键重启并重构镜像容器
./run.sh restart
```

---

### ⚠️ 当本地有修改，拉取最新代码的冲突处理方案

如果在服务器或本地修改了配置文件（如 `nginx.conf`、`run.sh` 或 `docker-compose.yml`），直接执行 `git pull origin main` 可能会提示冲突。请根据业务需求选择以下处理方案之一：

#### 方案一：保留本地修改并合并（推荐）✅
暂存本地修改，拉取远程更新后再恢复合并：
```bash
# 1. 暂存本地修改
git stash push -m "保存本地配置变更"

# 2. 拉取最新代码
git pull origin main

# 3. 恢复本地修改（如遇到冲突需手动修改）
git stash pop

# 4. 手动解决冲突后提交（如需要）
git add .
git commit -m "fix: 合并远程更新并保留本地配置"

# 5. 重启容器集群应用最新代码
./run.sh restart
```

#### 方案二：放弃本地修改，使用远程版本
丢弃特定的本地文件改动，直接同步远程代码：
```bash
# 1. 查看具体改动（确认是否要放弃）
git diff nginx.conf run.sh docker-compose.yml

# 2. 恢复这些文件到远程版本
git checkout -- nginx.conf run.sh docker-compose.yml

# 3. 拉取最新代码
git pull origin main

# 4. 重启容器集群
./run.sh restart
```

#### 方案三：仅保留重要文件的本地修改
备份重要配置文件后重置，拉取最新代码再手动比对合并：
```bash
# 1. 备份重要配置文件
cp nginx.conf nginx.conf.backup
cp run.sh run.sh.backup

# 2. 放弃这些文件的修改
git checkout -- nginx.conf run.sh docker-compose.yml

# 3. 拉取最新代码
git pull origin main

# 4. 对比备份文件和最新代码，手动合并配置
diff nginx.conf.backup nginx.conf
diff run.sh.backup run.sh

# 5. 合并完成后清理备份文件
rm nginx.conf.backup run.sh.backup

# 6. 重启容器集群
./run.sh restart
```

#### 方案四：强制覆盖（谨慎使用）⚠️
直接用远程最新代码强制覆盖本地所有改动（**未提交的本地修改将不可逆丢失**）：
```bash
# 1. 重置到远程最新状态
git fetch origin main
git reset --hard origin/main

# 2. 重启容器集群
./run.sh restart
```



---

## 🐘 PostgreSQL 数据库切换与配置说明

系统默认使用轻量级 **SQLite** 数据库，无需安装任何额外服务，适合单机/轻量部署。若需要切换为高并发、高可用的 **PostgreSQL** 数据库，请按以下说明配置：

### 1. 在 `docker-compose.yml` 中开启 PostgreSQL
`docker-compose.yml` 中已内置 `db` 服务（基于 `postgres:15-alpine`）。在 `web` 服务节点下解开 `DATABASE_URL` 环境变量配置：

```yaml
services:
  web:
    environment:
      - SECRET_KEY=gift-bookkeeping-docker-prod-secret-key
      - SESSION_COOKIE_SECURE=true
      # 启用 PostgreSQL 数据库连接
      - DATABASE_URL=postgresql://gift_user:gift_password@db:5432/gift_db
```

### 2. 外部独立 PostgreSQL 数据库配置
如果您使用的是已有外部 PostgreSQL 服务器，仅需在环境变量或 `docker-compose.yml` 中将 `DATABASE_URL` 设置为您的独立数据库连接字符串即可：

```bash
DATABASE_URL=postgresql://<用户名>:<密码>@<数据库IP或域名>:<端口>/<数据库名>
```
*示例*：
`DATABASE_URL=postgresql://postgres:MySecurePass123@192.168.1.100:5432/gift_db`

### 3. 特性与无损迁移
- 程序启动时，SQLAlchemy 会自动检测数据库连接。如果表结构不存在，系统将自动建表并初始化管理员账号。
- `psycopg2-binary` 依赖包已内置在 `requirements.txt` 中，支持一键无缝连接 PostgreSQL。

---

## 🔑 默认管理员账户与安全提醒
- 系统启动时会自动根据配置初始化管理员账户，建议成功部署后登录并设置密保问题！

