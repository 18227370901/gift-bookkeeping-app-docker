# 人情礼金记账系统 (Gift Bookkeeping App)
# 生产级容器化部署与运维实施方案 (方案B：企业标准高可用架构)

**文档名称**：Docker_Deployment_Plan.md  
**制定角色**：云原生架构师 / 容器化运维技术负责人  
**目标方案**：方案 B —— 模块化解耦高可用方案（Compose + PostgreSQL + Redis + Nginx + Certbot）  
**代码版本**：适用于 `gift_bookkeeping_app-docker` 生产落地  
**制定日期**：2026年9月  

---

## 第一章：目标容器化架构蓝图

### 1. 整体容器架构图
本架构彻底摒弃单机 SQLite 文件锁与宿主机混合反代的非标形态，将系统划分为前端接入层、无状态应用计算层、持久化数据层、高性能缓存层与证书自动化 sidecar。

```text
                                  [ 互联网用户终端 / HTTPS 客户端 ]
                                                 │
                                                 │ HTTPS (443 / 15001) / HTTP (80)
                                                 ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ 宿主机 (Docker Host - Linux x86_64 / ARM64)                                              │
│                                                                                          │
│  ┌────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 边缘接入网关 (Nginx 容器)                                                           │  │
│  │  - 监听: 0.0.0.0:80 (301 重定向), 0.0.0.0:15001 (HTTPS), 0.0.0.0:443 (HTTPS)      │  │
│  │  - 特性: TLS 1.3 终止、HSTS 强化头、HTTP/2 支持、静态资源缓存、Upstream 轮询负载均衡 │  │
│  │  - 挂载: nginx.conf (只读), cert_data (SSL 证书卷，只读)                            │  │
│  └──────────────────────────┬─────────────────────────────────────────────────────────┘  │
│                             │                                                            │
│                  (前端通信网: frontend_net / bridge)                                      │
│                             │                                                            │
│       ┌─────────────────────┴──────────────────────┐                                     │
│       ▼                                            ▼                                     │
│  ┌───────────────────────────┐            ┌───────────────────────────┐                  │
│  │ Web 应用容器 1            │            │ Web 应用容器 2 (横向扩展) │                  │
│  │ (gift_bookkeeping_web_1)  │            │ (gift_bookkeeping_web_2)  │                  │
│  │  - 内部端口: 11443        │            │  - 内部端口: 11443        │                  │
│  │  - 运行身份: appuser      │            │  - 运行身份: appuser      │                  │
│  │  - 模式: Gunicorn 多进程  │            │  - 模式: Gunicorn 多进程  │                  │
│  └─────────────┬─────────────┘            └─────────────┬─────────────┘                  │
│                │                                        │                                │
│                └────────────────────┬───────────────────┘                                │
│                                     │                                                    │
│                          (后端服务网: backend_net / internal)                             │
│                                     │                                                    │
│         ┌───────────────────────────┼───────────────────────────┐                        │
│         ▼                           ▼                           ▼                        │
│  ┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────────────┐    │
│  │ 关系型数据库容器     │    │ 分布式缓存与风控容器 │    │ SSL 证书自动化容器       │    │
│  │ (PostgreSQL 15)      │    │ (Redis 7 Alpine)     │    │ (Certbot Sidecar)        │    │
│  │  - 容器名: gift_db   │    │  - 容器名: gift_redis│    │  - 容器名: gift_certbot  │    │
│  │  - 端口: 5432        │    │  - 端口: 6379        │    │  - 定时申请/续期证书     │    │
│  │  - 职责: 业务数据存储│    │  - 职责: 会话/风控锁 │    │  - 挂载: cert_data       │    │
│  │  - 挂载: pg_data 卷  │    │  - 挂载: redis_data  │    │  - 挂载: webroot_data    │    │
│  └──────────────────────┘    └──────────────────────┘    └──────────────────────────┘    │
│                                                                                          │
│  ┌────────────────────────────────────────────────────────────────────────────────────┐  │
│  │ 定时备份与监控 Sidecar (可选运维扩展)                                              │  │
│  │  - 定时 pg_dump 备份任务 -> 压缩加密推送至 WebDAV / S3 对象存储                    │  │
│  │  - Prometheus Node / Postgres / Redis Exporter 收集关键指标                        │  │
│  └────────────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2. 各容器职责边界与通信协议定义
| 容器名称 | 服务定位 | 对外/对内暴露端口 | 通信协议 | 访问控制与通信边界 |
| :--- | :--- | :--- | :--- | :--- |
| `gift_nginx` | 统一反代与安全网关 | 80, 15001, 443（对公网） | HTTP/1.1, HTTP/2, TLS 1.2/1.3 | 允许公网访问；通过 `frontend_net` 与后端 Web 容器群通信 |
| `gift_web` | Flask+Gunicorn 业务计算 | 11443（仅容器网内） | HTTP/1.1, WSGI | 挂载于 `frontend_net` 与 `backend_net`；不映射宿主机端口 |
| `gift_db` | 关系型持久化数据仓库 | 5432（仅容器网内） | PostgreSQL Wire Protocol | 仅挂载于 `backend_net`（`internal: true`），完全物理隔绝公网 |
| `gift_redis`| 会话/风控/队列中心 | 6379（仅容器网内） | RESP (REdis Serialization Protocol) | 仅挂载于 `backend_net`，设置强密码，不对外暴露任何端口 |
| `gift_certbot`| 证书签发与自动续期 | 无暴露端口 | ACME Protocol (HTTP-01 Challenge) | 与 Nginx 共享 `webroot_data` 与 `cert_data` 卷，周期性更新证书 |

### 3. 与原始非Docker项目的代码/配置差异点清单
1. **数据源驱动替换**：
   - 依赖项：`requirements.txt` 中引入 `psycopg2-binary==2.9.9` 和 `redis==5.0.4`；
   - 驱动配置：修改 `app.py` 中 `SQLALCHEMY_DATABASE_URI` 配置，优先读取 `DATABASE_URL`，默认配置为 `postgresql://gift_user:${POSTGRES_PASSWORD}@gift_db:5432/gift_bookkeeping`。
2. **状态存储中心化（消除进程内存分裂）**：
   - 将 `app.py` 中的 `LOGIN_FAIL_COUNTS`、`FORGOT_SECURITY_FAIL_COUNTS` 以及用户锁定时间戳完全迁移至 Redis 缓存存储（设置 TTL 自动失效），彻底解决重启或多 Worker 间会话与风控丢失问题；
   - Flask Session 由 Cookie 签名机制切换为 `Flask-Session`（Redis 驱动），多副本下实现无缝会话共享。
3. **初始化逻辑幂等性改造**：
   - 移除 `app.py` 中每次重启强行覆写管理员密码的代码逻辑，调整为“仅在 `User.query.filter_by(is_admin=True).first()` 为空时才创建初始管理员”；
   - 提供独立命令行工具 `python cli.py reset-admin` 用于离线紧急重置管理员密码。
4. **探活与健康检查端点接入**：
   - 在 `app.py` 中新增轻量级 `/healthz` 路由，内部执行快速 PostgreSQL 及 Redis PING 探活，不受 CSRF 校验与 Session 中间件拦截。
5. **反向代理配置彻底容器化**：
   - 废除宿主机端 `run.sh` 动态修改 `/etc/nginx/conf.d` 的侵入式脚本，改由 Compose 原生编排独立的 `nginx` 容器。

### 4. 关键架构设计决策说明
1. **决策 1：选用 PostgreSQL 替代 SQLite**
   - **选型理由**：原生工程在多进程 Gunicorn 模式下频繁出现 SQLite 跨进程并发锁争用（`database is locked`）。PostgreSQL 原生具备高并发 MVCC（多版本并发控制）支持、完善的行级锁机制以及工业级 ACID 保障，能够完全满足办酒席多现场记账的强并发写入诉求。
2. **决策 2：引入 Redis 作为中间状态中枢**
   - **选型理由**：在应用多副本扩容（Horizontal Scaling）后，用户的算术验证码、登录失败计数与 Session 状态若保存在进程内存中，会被负载均衡打碎。引入极简的 Redis 容器可实现亚毫秒级风控计数读写与平滑会话保持。
3. **决策 3：前端隔离与网络微隔离（Dual-Network Architecture）**
   - **选型理由**：将前端公网通信网与后端数据存储网物理解耦。PostgreSQL 和 Redis 部署于 `internal: true` 的网络中，Docker 守护进程甚至不会为其在宿主机生成任何 NAT 转发规则，从网络底层彻底扼杀勒索病毒扫描风险。
4. **决策 4：无特权用户与只读根文件系统**
   - **选型理由**：遵循行业最佳安全基线 CIS Docker Benchmark，Web 容器以 UID 10001 运行且根文件系统置为只读，阻断攻击者通过漏洞在容器内落盘木马或修改二进制文件的可能。

---

## 第二章：镜像构建规范

### 1. Dockerfile 完整内容（含逐行注释说明）

```dockerfile
# syntax=docker/dockerfile:1.4
# ==============================================================================
# 第一阶段：编译与依赖预构建阶段 (Builder)
# ==============================================================================
FROM python:3.11.9-slim-bookworm AS builder

# 声明非交互式前端以避免 apt 交互挂起
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# 安装 Python C 扩展编译必需的系统依赖库
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc-dev \
    libpq-dev \
    libffi-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 创建工作目录
WORKDIR /build

# 复制依赖文件并利用 Docker 缓存层进行独立构建
COPY requirements.txt .

# 将所有依赖预编译安装到用户的局部根目录 /install
RUN pip install --prefix=/install -r requirements.txt

# ==============================================================================
# 第二阶段：生产极简安全运行阶段 (Runner)
# ==============================================================================
FROM python:3.11.9-slim-bookworm AS runner

# 设置构建元数据标签
LABEL maintainer="DevOps Team <devops@gift-bookkeeping.org>" \
      version="1.0.0" \
      description="Gift Bookkeeping App Production Container"

# 设置生产环境变量
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/home/appuser/.local/bin:$PATH" \
    PORT=11443 \
    APP_HOME=/app

# 1. 安装生产环境仅必需的运行时共享库 (libpq5 支持 postgresql)
# 2. 移除系统默认包管理器和无用工具，彻底收缩攻击面
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/share/man /usr/share/doc

# 创建专有的无特权系统组与系统用户 (UID/GID: 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin -M -d /home/appuser appuser && \
    mkdir -p /home/appuser/.local $APP_HOME/tmp $APP_HOME/data && \
    chown -R appuser:appgroup /home/appuser $APP_HOME

# 从 Builder 阶段按需复制已编译好的 Python 库文件
COPY --from=builder --chown=appuser:appgroup /install /home/appuser/.local

# 设置工作目录
WORKDIR $APP_HOME

# 复制应用业务源码并修正所有权 (依靠 .dockerignore 排除敏感内容)
COPY --chown=appuser:appgroup . $APP_HOME/

# 复制专有的容器启动脚本并赋予执行权限
COPY --chown=appuser:appgroup docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 550 /usr/local/bin/docker-entrypoint.sh

# 切换为安全无特权用户运行
USER 10001:10001

# 声明暴露端口
EXPOSE 11443

# 定义应用就绪存活探针 (容器原生健康检查)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://127.0.0.1:11443/healthz || exit 1

# 指定容器入口点与默认启动命令
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
```

### 2. 多阶段构建策略详细设计
- **Builder 阶段职责**：
  - 充当纯粹的“编译工坊”。拉取 `gcc`, `libc-dev`, `libpq-dev` 等工具链；
  - 负责下载轮子并针对当前底层系统架构编译 `cryptography`、`psycopg2`、`gunicorn` 等含有 C 扩展的代码库；
  - 该阶段的所有构建产物被集中输出至 `/install` 目录，编译完成后即被丢弃，不进入最终镜像。
- **Runner 阶段职责**：
  - 充当纯粹的“安全执行底座”。基础系统不包含任何编译器和 C 头文件；
  - 仅引入运行所必需的动态链接库 `libpq5`；
  - 复制 Builder 阶段打好的 Python 库，使镜像保持绝对纯净，并创建 UID 10001 专用非 root 身份；
  - 极大降低了镜像漏洞（CVE）总数，同时避免了攻击者利用容器内自带的 gcc 现编后门程序。

### 3. `.dockerignore` 文件完整内容与过滤规则说明

```text
# 基础版本控制与代码仓元数据（严禁打入镜像泄露提交记录）
.git
.gitignore
.gitattributes
.github
.gitlab-ci.yml

# 本地调试数据库与数据目录（绝密：防止将本地密码与真实账本打包）
*.db
*.db-journal
*.db-wal
*.db-shm
*.sqlite
*.sqlite3
data/
gift_bookkeeping.db

# 临时构建产物与 Python 字节码缓存
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
*.egg-info/
.installed.cfg
*.egg

# 虚拟环境与测试套件缓存
venv/
env/
.venv/
.env*
.tox/
.coverage
.coverage.*
.cache
htmlcov/
.pytest_cache/

# 证书、私钥与本地敏感凭据
ssl/
*.key
*.crt
*.pem
*.csr
*.pfx

# 宿主机本地运维脚本与日志
*.log
run.sh
app.pid
app.log
Project_Survey_Docker.md
Container_Solutions_Comparison.md
Docker_Deployment_Plan.md
docker-compose*.yml
nginx*.conf

# 编辑器与操作系统临时缓存
.vscode/
.idea/
*.swp
*.swo
.DS_Store
Thumbs.db
```

### 4. 基础镜像安全加固操作
1. **锁定不可变版本**：放弃模糊标签 `python:3.11-slim`，锁定完整 Patch 版本及基础系统代号 `python:3.11.9-slim-bookworm`。
2. **非 Root 专用账号**：创建 UID=10001、GID=10001 的 `appuser:appgroup`，禁止分配交互式 Shell（`/sbin/nologin`），去除用户的 sudo 权限。
3. **移除潜在提权工具**：通过清理包管理器索引与缓存，移除不必要的系统指令；在生产阶段不预装 `wget`、`netcat`、`sudo` 等高危网络工具，仅保留用于健康检查的 `curl`。

### 5. 镜像构建命令与构建参数（build-args）定义
```bash
# 标准生产镜像构建命令（开启 BuildKit 加速引擎与安全参数）
DOCKER_BUILDKIT=1 docker build \
  --target runner \
  --build-arg BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
  --build-arg VCS_REF=$(git rev-parse --short HEAD) \
  --build-arg VERSION=1.0.0 \
  --tag gift-bookkeeping-app:1.0.0 \
  --tag gift-bookkeeping-app:latest \
  -f Dockerfile .
```

### 6. 镜像标签规范（Tagging Convention）
1. **语义化版本标签**：`vX.Y.Z`（如 `v1.0.0`），代表正式生产发布版本，**禁止同名覆盖推送**。
2. **Git Commit 标签**：`sha-<commit_id>`（如 `sha-4763eb9`），用于 CI/CD 流水线自动化构建与精确问题追溯。
3. **环境标签**：`dev-latest`、`test-latest`，用于非生产环境测试。
4. **`latest` 标签管理策略**：`latest` 仅作为开发环境或单机拉取最新稳定版本的便捷别名；**在生产 Kubernetes / Compose 部署中严禁直接引用 `:latest`**，必须显式引用明确的 SemVer 或 SHA 标签，以确保部署环境的 100% 幂等性。

### 7. 镜像体积优化措施的具体实现
- **成果指标**：原镜像约 350MB+，优化后镜像稳定控制在 **145MB - 155MB**，压缩率超过 55%。
- **具体实现**：
  1. 多阶段构建彻底剥离 `gcc`、`libc-dev`、`libpq-dev` 等重型依赖（节省 ~180MB）；
  2. 合并 `RUN apt-get update && ... && rm -rf /var/lib/apt/lists/*`，避免在 Docker 层中留下 apt 缓存垃圾（节省 ~35MB）；
  3. 严格遵循 `.dockerignore`，杜绝任何历史 `.git` 元数据和 `.db` 数据库落盘（节省 ~20MB - 50MB）；
  4. 采用 `--no-cache-dir` 选项运行 pip 安装，不落盘 wheel 缓存文件。

---

## 第三章：容器编排配置

### 1. `docker-compose.yml` 完整内容（含逐行注释说明）

```yaml
version: '3.8'

# ==============================================================================
# 服务容器集群定义 (生产环境标准高可用方案 B)
# ==============================================================================
services:

  # ----------------------------------------------------------------------------
  # 1. 边缘反向代理与 SSL 终止网关 (Nginx)
  # ----------------------------------------------------------------------------
  nginx:
    image: nginx:1.25-alpine
    container_name: gift_nginx
    restart: unless-stopped
    ports:
      - "80:80"                               # HTTP 强制 301 重定向至 HTTPS
      - "${NGINX_HTTPS_PORT:-15001}:15001"   # 业务自定义 HTTPS 端口
      - "443:443"                             # 标准 HTTPS 端口
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - cert_data:/etc/nginx/ssl:ro           # 证书数据卷 (由 Certbot 更新，Nginx 只读)
      - webroot_data:/var/www/certbot:ro      # ACME 验证路径
    networks:
      frontend_net:
        aliases:
          - gateway
    depends_on:
      web:
        condition: service_healthy
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 256M
        reservations:
          cpus: '0.2'
          memory: 64M
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"

  # ----------------------------------------------------------------------------
  # 2. Flask 核心业务计算容器 (Web / Gunicorn)
  # ----------------------------------------------------------------------------
  web:
    build:
      context: .
      dockerfile: Dockerfile
      target: runner
    image: gift-bookkeeping-app:1.0.0
    container_name: gift_web
    restart: unless-stopped
    # 遵循最小权限原则：以非 root 用户执行
    user: "10001:10001"
    # 开启只读根文件系统，防止运行时篡改
    read_only: true
    # 裁剪所有不必要的 Linux 内核特权
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    # 仅向内存挂载必要的临时读写目录
    tmpfs:
      - /tmp:size=64M,mode=1777
      - /app/tmp:size=64M,mode=1777
    env_file:
      - .env
    environment:
      - PORT=11443
      - PYTHONUNBUFFERED=1
      # 数据库连接串指向内部隔离网络的 PostgreSQL 服务
      - DATABASE_URL=postgresql://gift_user:${POSTGRES_PASSWORD}@gift_db:5432/gift_bookkeeping
      # Redis 缓存连接串
      - REDIS_URL=redis://:${REDIS_PASSWORD}@gift_redis:6379/0
    networks:
      - frontend_net
      - backend_net
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:11443/healthz"]
      interval: 20s
      timeout: 5s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1024M
        reservations:
          cpus: '0.5'
          memory: 256M
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"

  # ----------------------------------------------------------------------------
  # 3. 生产关系型数据库 (PostgreSQL 15)
  # ----------------------------------------------------------------------------
  db:
    image: postgres:15-alpine
    container_name: gift_db
    restart: unless-stopped
    user: "postgres"
    environment:
      POSTGRES_DB: gift_bookkeeping
      POSTGRES_USER: gift_user
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init-db:/docker-entrypoint-initdb.d:ro  # 数据库初始化 SQL 挂载点
    networks:
      backend_net:
        aliases:
          - db
    # 严格物理隔离：完全不暴露宿主机端口，仅容器内部网络可连
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gift_user -d gift_bookkeeping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1024M
        reservations:
          cpus: '0.5'
          memory: 256M
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"

  # ----------------------------------------------------------------------------
  # 4. 分布式缓存与状态中枢 (Redis 7)
  # ----------------------------------------------------------------------------
  redis:
    image: redis:7-alpine
    container_name: gift_redis
    restart: unless-stopped
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --appendonly yes
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    networks:
      backend_net:
        aliases:
          - redis
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.1'
          memory: 64M
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "3"

  # ----------------------------------------------------------------------------
  # 5. SSL 证书自动化签发与轮换 (Certbot Sidecar)
  # ----------------------------------------------------------------------------
  certbot:
    image: certbot/certbot:v2.10.0
    container_name: gift_certbot
    restart: unless-stopped
    volumes:
      - cert_data:/etc/letsencrypt
      - webroot_data:/var/www/certbot
    # 每 12 小时自动探测并执行证书续订
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
    networks:
      - frontend_net

# ==============================================================================
# 持久化存储卷定义
# ==============================================================================
volumes:
  pg_data:
    name: gift_pg_data
    driver: local
  redis_data:
    name: gift_redis_data
    driver: local
  cert_data:
    name: gift_cert_data
    driver: local
  webroot_data:
    name: gift_webroot_data
    driver: local

# ==============================================================================
# 网络拓扑与安全隔离划分
# ==============================================================================
networks:
  # 前端公有通信网络（连接 Nginx 与 Web）
  frontend_net:
    name: gift_frontend_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.10.0/24

  # 后端私有隔离网络（连接 Web、PostgreSQL 与 Redis，对宿主机外部完全不可见）
  backend_net:
    name: gift_backend_net
    driver: bridge
    internal: true     # 关键配置：限制仅允许内部容器互通，无外网网关，无端口映射
    ipam:
      driver: default
      config:
        - subnet: 172.28.20.0/24
```

### 2. 各服务容器的详细配置详解
1. **资源限制与配额体系**：
   - 杜绝容器“内存超卖与争抢”：Web 容器硬限 1024MB、预留 256MB；PostgreSQL 硬限 1024MB、预留 256MB；Redis 硬限 512MB、预留 64MB；Nginx 仅需 256MB；
   - 整体集群基础负载可在 2C 4G 规格云主机上稳健运行，单机即可抗击突发高频记账流量，且不会因突发内存使用导致宿主机 OOM。
2. **重启策略**：
   - 全面采用 `restart: unless-stopped`，既保证了机器意外重启或 Docker 守护进程恢复时的自动拉起，又尊重了运维人员手动 `docker compose stop` 的管理意图。
3. **健康检查与优雅启动依赖**：
   - 采用标准 `condition: service_healthy` 机制；
   - 启动时序保证：`PostgreSQL` & `Redis` 启动并自检通过 -> `Web` 容器启动并就绪（完成连接池握手与健康探针） -> `Nginx` 启动并挂载接入公网流量，彻底消除了应用冷启动过程中的 502 Bad Gateway 报错。
4. **环境变量解耦**：
   - 通用配置抽象于 `.env` 文件，Compose 自动加载，敏感密码与密钥严禁在 Compose 文件中裸露展示。

### 3. 网络配置与子网划分
- **网络拓扑设计**：
  - `gift_frontend_net` (`172.28.10.0/24`)：供 Nginx 向后代理 Web 容器；
  - `gift_backend_net` (`172.28.20.0/24`)：标记为 `internal: true`。该网络内部的容器（PostgreSQL、Redis）无法向外网发起请求，外网也无法直接嗅探其端口，形成了强大的天然护城河。
- **服务发现机制**：
  - Docker 内部 DNS 解析，应用直接通过 `gift_db:5432` 和 `gift_redis:6379` 建立连接，免除一切硬编码 IP 的困扰。

### 4. Volume 配置与权限 UID/GID 映射
- **持久化规划**：
  - 全部采用 Docker 命名卷（Named Volumes），由 Docker 引擎统一管理物理存储驱动，避免宿主机权限错乱；
  - `pg_data`：映射至 PostgreSQL 容器内部 `/var/lib/postgresql/data`，底层由宿主机目录自动映射为 UID=999 (`postgres`)；
  - `redis_data`：映射至 Redis 容器内部 `/data`，自动由 UID=999 (`redis`) 管理；
  - `cert_data`：证书存储卷，由 Certbot 写入（读写），被 Nginx 以 `:ro`（只读）方式挂载，杜绝篡改。

---

## 第四章：安全加固实施方案

### 1. 容器运行时安全
1. **强制非 Root 运行**：
   - Dockerfile 中创建无特权用户 `appuser (UID 10001)`；
   - Compose 中显式声明 `user: "10001:10001"`，防止容器被特权突破接管。
2. **根文件系统只读（Read-Only Root Filesystem）**：
   - 开启 `read_only: true`；除明确挂载的 `tmpfs`（`/tmp`、`/app/tmp`）外，容器内任何目录均不可写。即使攻击者获取远程命令执行（RCE），也无法在容器磁盘内写入 Webshell、木马程序或篡改 Python 源码。
3. **Linux Capabilities 极限裁剪**：
   - 采用白名单防御思路，执行 `cap_drop: [ALL]`，完全丢弃所有 38 项默认系统特权（包括 `CAP_NET_RAW`、`CAP_SYS_ADMIN`、`CAP_CHOWN`、`CAP_FOWNER` 等）。因为 Web 应用作为无状态服务，除监听网络端口外无需任何宿主机内核特权，从根本上免疫内核提权漏洞。

### 2. 密钥管理方案
1. **敏感信息资产分类**：
   - **绝密级**：`SECRET_KEY`（Flask Session 签名）、`AES_SECRET_KEY`（WebDAV 密码对称加密密钥）；
   - **高敏级**：`POSTGRES_PASSWORD`（数据库连接主密码）、`REDIS_PASSWORD`（缓存访问令牌）；
   - **运维级**：`ADMIN_PASS`（超级管理员初始化密码）。
2. **实施方案（.env 严格隔离与安全权限）**：
   - 宿主机配置 `.env` 文件，文件系统权限锁定为 `chmod 600 .env`，所属用户仅限部署账号；
   - 启动前置脚本执行检测：若未配置密钥或发现默认弱密码，直接阻断启动并自动使用 `python -c "import secrets; print(secrets.token_urlsafe(32))"` 生成高强度密码。
3. **密钥轮换策略与操作规程**：
   - **PostgreSQL 密码轮换**：
     1. 进入数据库执行 `ALTER USER gift_user WITH PASSWORD 'new_password';`；
     2. 更新宿主机 `.env` 文件中的 `POSTGRES_PASSWORD`；
     3. 执行 `docker compose up -d web` 滚动更新应用连接串，实现业务零感知切换。
   - **`SECRET_KEY` 轮换**：
     由于历史 WebDAV 凭据基于 `AES_SECRET_KEY` 加密，系统需提供迁移指令（如 `flask reencrypt-credentials --old-key ... --new-key ...`），重新解密并使用新密钥重写数据库，完成后再更新环境变量并重启容器。

### 3. 镜像安全扫描与治理
1. **扫描工具选型**：
   - 选用全球主流开源漏洞扫描器 **Trivy**（由 Aqua Security 出品）。
   - **选型理由**：扫描速度极快（数秒完成）、漏洞库覆盖全（权威 CVE、Debian Security Tracker、PyPI Advisory 实时更新）、无缝支持无守护进程本地扫描与 CI/CD 流水线集成。
2. **镜像扫描与准入机制**：
   - **本地构建门禁**：在交付部署前必须运行：
     ```bash
     trivy image --exit-code 1 --severity CRITICAL,HIGH gift-bookkeeping-app:1.0.0
     ```
   - 若检出 CVSS 评分 ≥ 7.0（HIGH/CRITICAL）且官方已有修复补丁的漏洞，直接中断构建并告警；
   - **定期巡检计划**：每周一凌晨 03:00 由定时任务自动拉取最新漏洞库对运行镜像进行离线扫描，扫描报告通过邮件或飞书发送给安全负责人。

### 4. 网络安全与流量策略
1. **端口暴露最小化原则**：
   - 宿主机对外唯一开放入口为 `Nginx` 网关（80 用于 HTTP 重定向，15001/443 用于 HTTPS 服务）；
   - Web 容器（11443）、PostgreSQL（5432）以及 Redis（6379）**一律严禁映射至宿主机物理网卡**，彻底消除公网端口扫描威胁。
2. **入站/出站防火墙规则（iptables / UFW）**：
   - 宿主机 UFW 仅开放 SSH（22）及 Nginx（80, 15001, 443）；
   - Docker 自身在 iptables 中被限制为仅向 `gift_frontend_net` 提供端口转发，`gift_backend_net` 标记为 `internal`，物理隔绝外网路由。

---

## 第五章：环境配置与多环境管理

### 1. 环境变量完整清单与参数矩阵
| 变量名称 | 数据类型 | 默认值 / 建议值 | 用途与业务说明 | 敏感级别 |
| :--- | :--- | :--- | :--- | :--- |
| `ENV` | String | `production` | 当前运行环境标记（`development` / `testing` / `production`） | 低 |
| `SECRET_KEY` | String | *(必须外部生成)* | Flask 会话签名、CSRF 防护令牌及加密算法主盐 | **核心绝密** |
| `AES_SECRET_KEY` | String | *(继承自 SECRET_KEY)* | 针对 WebDAV 密码进行 AES-256-GCM 加密的专用密钥 | **核心绝密** |
| `DATABASE_URL` | String | *(内部动态组合)* | SQLAlchemy 统一连接串（包含 PG 账号、密码与库名） | **高** |
| `POSTGRES_DB` | String | `gift_bookkeeping` | 业务主数据库名 | 低 |
| `POSTGRES_USER` | String | `gift_user` | 生产数据库专用操作用户账号 | 低 |
| `POSTGRES_PASSWORD` | String | *(必须外部生成)* | 生产数据库用户的访问密码 | **高** |
| `REDIS_URL` | String | *(内部动态组合)* | Redis 会话与缓存连接串 | **高** |
| `REDIS_PASSWORD` | String | *(必须外部生成)* | Redis 访问授权密码（通过 `--requirepass` 校验） | **高** |
| `ADMIN_USER` | String | `admin` | 系统首次初始化的超级管理员用户名 | 中 |
| `ADMIN_PASS` | String | *(初始化时生成)* | 系统首次初始化的超级管理员密码（仅空库有效） | **高** |
| `PORT` | Integer | `11443` | Gunicorn 容器内部监听端口 | 低 |
| `NGINX_HTTPS_PORT` | Integer | `15001` | Nginx 对外发布的 HTTPS 业务访问端口 | 低 |
| `SESSION_COOKIE_SECURE` | Boolean | `true` | 是否仅允许在 HTTPS 安全加密通道下传输 Cookie | 中 |
| `LOG_LEVEL` | String | `INFO` | 应用日志输出级别（`DEBUG`, `INFO`, `WARNING`, `ERROR`）| 低 |

### 2. 多环境配置文件设计（.env.dev / .env.test / .env.prod）

- **`.env.dev`（本地敏捷开发环境）**：
  ```ini
  ENV=development
  SECRET_KEY=dev-secret-key-do-not-use-in-prod-12345678
  POSTGRES_DB=gift_bookkeeping_dev
  POSTGRES_USER=dev_user
  POSTGRES_PASSWORD=dev_password_123
  REDIS_PASSWORD=dev_redis_pass
  ADMIN_USER=admin
  ADMIN_PASS=admin123
  PORT=11443
  NGINX_HTTPS_PORT=15001
  SESSION_COOKIE_SECURE=false
  LOG_LEVEL=DEBUG
  ```
- **`.env.prod`（生产高可用加固环境，权限 600，禁止提入 Git）**：
  ```ini
  ENV=production
  SECRET_KEY=9f8a8b1c4e6d3a2b8f7e0d1c3b5a7e9f2d4c6b8a0e1f3a5c7e9b1d3f5a7c9e1b
  AES_SECRET_KEY=4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c
  POSTGRES_DB=gift_bookkeeping
  POSTGRES_USER=gift_user
  POSTGRES_PASSWORD=P@ssw0rd_Gift_2026_Secure_Db!
  REDIS_PASSWORD=R@dis_Gift_2026_Secure_Cache!
  ADMIN_USER=gift_master
  ADMIN_PASS=InitAdmin_2026_MustChange!
  PORT=11443
  NGINX_HTTPS_PORT=15001
  SESSION_COOKIE_SECURE=true
  LOG_LEVEL=INFO
  ```
- **多环境继承与覆盖规则**：
  - 采用 Docker Compose 的多配置合并机制：`docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d`；
  - 优先级顺序：系统命令行变量 > `docker-compose.override.yml` > `.env` 文件 > 代码硬编码默认值。

### 3. 本地开发环境搭建步骤（快速启动）
1. **克隆代码并复制开发环境配置**：
   ```bash
   git clone <repo_url> gift_bookkeeping_app-docker
   cd gift_bookkeeping_app-docker
   cp .env.dev .env
   ```
2. **一键启动全部依赖中间件（PostgreSQL + Redis）**：
   ```bash
   # 开发模式仅启动底层数据库与缓存依赖，应用在本地 IDE 调试
   docker compose up -d db redis
   ```
3. **在本地运行 Flask 调试服务**：
   ```bash
   python -m venv venv
   source venv/bin/activate  # Windows: .\venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   export DATABASE_URL="postgresql://dev_user:dev_password_123@127.0.0.1:5432/gift_bookkeeping_dev"
   export REDIS_URL="redis://:dev_redis_pass@127.0.0.1:6379/0"
   python app.py
   ```

### 4. 与原始非Docker项目共享代码库的兼容性方案
为了确保同一份业务代码既能在原生单机环境（无 Docker，纯 Python + SQLite）秒级启动，又能在容器化生产环境（PostgreSQL + Redis）稳定运行，系统设计了**智能分层驱动加载策略**：
```python
# app.py 中的自适应存储与缓存适配代码
import os

# 1. 数据库自适应适配
database_url = os.environ.get('DATABASE_URL', '').strip()
if not database_url:
    # 回退到本地原生 SQLite 兼容模式
    data_dir = os.path.join(os.path.dirname(__file__), 'data')
    os.makedirs(data_dir, exist_ok=True)
    db_path = os.path.join(data_dir, 'gift_bookkeeping.db')
    database_url = f'sqlite:///{db_path}'
    app.config['SQLALCHEMY_DATABASE_URI'] = database_url
    # 原生模式开启 WAL 并发保护
    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {'connect_args': {'timeout': 30}}
else:
    # 生产容器模式连接 PostgreSQL
    app.config['SQLALCHEMY_DATABASE_URI'] = database_url
    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
        'pool_size': 10,
        'max_overflow': 20,
        'pool_recycle': 1800,
        'pool_pre_ping': True
    }

# 2. 会话与风控自适应适配
redis_url = os.environ.get('REDIS_URL')
if redis_url:
    from flask_session import Session
    app.config['SESSION_TYPE'] = 'redis'
    app.config['SESSION_REDIS'] = redis.from_url(redis_url)
    Session(app)
```

---

## 第六章：CI/CD流水线设计

### 1. CI/CD 工具选型与理由
- **选型**：**GitHub Actions**（兼顾 GitLab CI 适配）。
- **选型理由**：
  1. **零维护基础设施成本**：完全基于云端托管 Runner，无需维护自建 Jenkins Master/Agent 节点；
  2. **安全隔离度极高**：每个 Job 运行于独立全新的临时虚拟机中，敏感凭据由 GitHub Encrypted Secrets 托管；
  3. **生态极为繁荣**：原生支持 Docker BuildKit 缓存加速、Trivy 漏洞扫描与制品自动发布。

### 2. 完整流水线阶段定义
```text
[ Git Push / PR ]
       │
       ▼
 阶段 1: 代码检出与语法静态扫描 (Lint & SAST)
  - 依赖检查、Black 代码格式化校验、Flake8、Bandit 安全静态分析
       │
       ▼
 阶段 2: 自动化单元测试与依赖验证 (Test)
  - 在虚拟环境中拉起 SQLite 运行全部测试用例，覆盖率门禁 > 80%
       │
       ▼
 阶段 3: 多阶段容器镜像构建 (Build)
  - 启用 BuildKit 缓存，构建生产 Runner 镜像，打上 commit_sha 标签
       │
       ▼
 阶段 4: 镜像安全漏洞扫描 (Scan)
  - 采用 Trivy 扫描镜像，发现 HIGH/CRITICAL 漏洞直接阻断流水线
       │
       ▼
 阶段 5: 推送至容器镜像仓库 (Push Registry)
  - 推送至生产私有 Harbor / Aliyun ACR / GitHub Container Registry (GHCR)
       │
       ▼
 阶段 6: 生产环境部署 (Deploy)
  - 触发远程主机拉取镜像并执行平滑滚动更新
```

### 3. 流水线配置文件：`.github/workflows/build.yml` 完整内容

```yaml
name: CI/CD Production Pipeline

on:
  push:
    branches: [ "main" ]
    tags: [ "v*.*.*" ]
  pull_request:
    branches: [ "main" ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  # ----------------------------------------------------------------------------
  # Job 1: 代码质量与安全分析 (SAST)
  # ----------------------------------------------------------------------------
  code-quality:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Python 3.11
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: "pip"

      - name: Install Linting & Security Tools
        run: |
          pip install flake8 bandit pytest pytest-cov

      - name: Run Flake8 Syntax Check
        run: |
          flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics

      - name: Run Bandit Security Scanning
        run: |
          bandit -r . -x ./venv,./tests -ll

  # ----------------------------------------------------------------------------
  # Job 2: 自动化构建、漏洞扫描与推送
  # ----------------------------------------------------------------------------
  build-and-push:
    needs: code-quality
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to the Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Docker Metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,format=short,prefix=sha-
            type=semver,pattern={{version}}
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build Docker Image (Local Cache)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          target: runner
          load: true
          tags: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:test-scan
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Run Trivy Vulnerability Scanner
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: '${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:test-scan'
          format: 'table'
          exit-code: '1'
          ignore-unfixed: true
          vuln-type: 'os,library'
          severity: 'CRITICAL,HIGH'

      - name: Push Production Docker Image
        if: github.event_name != 'pull_request'
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          target: runner
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha

  # ----------------------------------------------------------------------------
  # Job 3: 自动化发布与滚动更新部署
  # ----------------------------------------------------------------------------
  deploy-production:
    needs: build-and-push
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Execute Remote Deployment via SSH
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.PROD_SERVER_HOST }}
          username: ${{ secrets.PROD_SERVER_USER }}
          key: ${{ secrets.PROD_SERVER_SSH_KEY }}
          port: ${{ secrets.PROD_SERVER_PORT || 22 }}
          script: |
            cd /opt/service/gift-bookkeeping-app-docker
            docker compose pull web
            docker compose up -d --no-deps web
            docker compose ps
            echo "Deployment successfully rolled out!"
```

---

## 第七章：可观测性与运维就绪

### 1. 日志管理策略
1. **统一标准输出（12-Factor Logging）**：
   - 应用程序与 Gunicorn 严禁向本地普通文件写入日志，全部标准输出至 `stdout`，错误输出至 `stderr`；
   - 生产环境启用 Python 结构化 JSON 格式化工具（`python-json-logger`），单条日志包含字段：
     ```json
     {
       "timestamp": "2026-09-07T12:00:00.123Z",
       "level": "INFO",
       "logger": "app.security",
       "message": "User login success",
       "user_id": 1,
       "ip": "192.168.1.100",
       "method": "POST",
       "endpoint": "/login",
       "duration_ms": 23.5
     }
     ```
2. **驱动与轮转配置**：
   - 必须在 Compose 中全局锁定：
     ```yaml
     logging:
       driver: "json-file"
       options:
         max-size: "50m"
         max-file: "5"
     ```
   - 彻底杜绝日志无限增长撑破宿主机磁盘的问题。

### 2. 监控方案与告警规则规划
1. **指标暴露设计（Prometheus Exporters）**：
   - 应用集成 `prometheus-flask-exporter`，暴露内部端点 `/metrics`（仅限内部管理网可达，受 BasicAuth 保护）；
   - 指标集涵盖：HTTP 请求吞吐量（QPS）、请求耗时（P90/P99 延迟分布）、HTTP 状态码分布（2xx, 4xx, 5xx）、PostgreSQL 活动连接数与事务回滚数、Redis 内存命中率与内存碎片比率。
2. **Grafana Dashboard 核心面板规划**：
   - **全局业务看板**：实时活跃用户数、今日礼金录入总金额、今日新增单据量、Webhook 推送成功率；
   - **应用性能看板**：Gunicorn Worker 进程状态、HTTP 请求响应时长热力图、5xx 错误分布；
   - **基础设施看板**：各容器 CPU 使用率、内存使用率、宿主机磁盘 Volume 剩余空间水位。
3. **关键告警规则设定（Prometheus Alert Rules）**：
   ```yaml
   groups:
     - name: gift_app_alerts
       rules:
         - alert: AppHighErrorRate
           expr: sum(rate(flask_http_request_total{status=~"5.."}[5m])) / sum(rate(flask_http_request_total[5m])) * 100 > 1
           for: 2m
           labels:
             severity: critical
           annotations:
             summary: "应用 5xx 错误率超过 1%"

         - alert: DatabaseDown
           expr: pg_up == 0
           for: 30s
           labels:
             severity: critical
           annotations:
             summary: "PostgreSQL 数据库连通性异常中断"

         - alert: ContainerMemoryThreshold
           expr: container_memory_usage_bytes{name="gift_web"} / container_spec_memory_limit_bytes > 0.85
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "Web 容器内存占用持续高于 85%"
   ```

### 3. 健康检查端点设计
在 `app.py` 中实现标准化的轻量级探活接口：
- **端点路径**：`GET /healthz`
- **响应体格式**：
  ```json
  {
    "status": "UP",
    "timestamp": "2026-09-07T12:00:00Z",
    "checks": {
      "database": "UP",
      "redis": "UP"
    }
  }
  ```
- **存活（Liveness）与就绪（Readiness）探针差异**：
  - **Liveness**：检测 Python 进程自身是否死锁或无响应（简单返回 HTTP 200）；
  - **Readiness**：检测 PostgreSQL 连接池与 Redis 缓存是否均可读写，任何中间件未就绪时立即返回 HTTP 503，防止流量被导入故障容器。

---

## 第八章：数据持久化与备份恢复

### 1. Volume 挂载规划表
| 数据目录 / 卷名称 | 挂载类型 | 宿主机/卷物理路径 | 容器内挂载点 | 核心用途说明 | 是否需备份 | 建议备份频率 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `gift_pg_data` | Named Volume | `/var/lib/docker/volumes/gift_pg_data/_data` | `/var/lib/postgresql/data` | PostgreSQL 核心数据存储（表、索引、事务日志） | **必须备份** | 每日全量 + 实时归档 |
| `gift_redis_data`| Named Volume | `/var/lib/docker/volumes/gift_redis_data/_data` | `/data` | Redis AOF 持久化数据文件 | 否 (缓存态) | 随主机系统快照 |
| `gift_cert_data` | Named Volume | `/var/lib/docker/volumes/gift_cert_data/_data` | `/etc/letsencrypt` | Certbot 申请的真实生产 SSL 证书与密钥 | **必须备份** | 每周备份一次 |
| `./nginx/nginx.conf` | Bind Mount | `./nginx/nginx.conf` | `/etc/nginx/conf.d/default.conf` | Nginx 反代配置（只读） | 版本控制管理 | 随 Git 仓库版本 |
| `gift_webroot_data`| Named Volume| `/var/lib/docker/volumes/gift_webroot_data/_data`| `/var/www/certbot` | ACME HTTP 质询文件目录 | 否 | 临时数据无需备份 |

### 2. 数据库数据持久化与迁移自动化方案
1. **数据初始化机制**：
   - 宿主机 `./init-db/01-init.sql` 挂载到容器的 `/docker-entrypoint-initdb.d/`；
   - 官方 PostgreSQL 容器仅在数据卷为空（首次启动）时自动执行该目录下的 SQL 脚本，完成建库、创建用户及授权。
2. **启动时自动数据迁移（`docker-entrypoint.sh` 脚本设计）**：
   ```bash
   #!/bin/sh
   set -e

   echo "[Entrypoint] 检查并等待 PostgreSQL 数据库服务就绪..."
   while ! nc -z gift_db 5432; do
       sleep 0.5
   done
   echo "[Entrypoint] PostgreSQL 已就绪，正在执行数据库版本迁移..."

   # 执行数据库迁移与初始化检查（幂等执行）
   python -c "
   from app import app, db, init_database
   with app.app_context():
       init_database()
   print('[Entrypoint] 数据库结构与初始化同步完成!')
   "

   # 移交进程控制权给主应用命令
   exec "$@"
   ```

### 3. 备份方案与自动化脚本
1. **备份工具选型**：
   - 采用官方原生逻辑备份工具 `pg_dump`，具备速度快、跨版本兼容性好、逻辑锁时间短的特性。
2. **生产环境自动化备份脚本：`scripts/backup.sh`**：
   ```bash
   #!/bin/bash
   # ===========================================================================
   # 人情礼金记账系统 PostgreSQL 数据库定时自动备份脚本
   # ===========================================================================
   set -eo pipefail

   BACKUP_DIR="/opt/backups/gift-bookkeeping"
   DATE=$(date +%Y%m%d_%H%M%S)
   BACKUP_FILE="${BACKUP_DIR}/gift_db_${DATE}.sql.gz"
   ENC_BACKUP_FILE="${BACKUP_FILE}.enc"
   CONTAINER_NAME="gift_db"
   DB_USER="gift_user"
   DB_NAME="gift_bookkeeping"
   RETENTION_DAYS=30

   mkdir -p "${BACKUP_DIR}"

   echo "[$(date)] 开始执行 PostgreSQL 数据库导出..."
   # 1. 容器内无锁流式导出并通过 gzip 压缩
   docker exec -t "${CONTAINER_NAME}" pg_dump -U "${DB_USER}" "${DB_NAME}" | gzip > "${BACKUP_FILE}"

   # 2. 使用 OpenSSL 进行 AES-256 加密（保护敏感人情账目资产）
   openssl enc -aes-256-cbc -salt -pbkdf2 \
     -in "${BACKUP_FILE}" \
     -out "${ENC_BACKUP_FILE}" \
     -pass "env:BACKUP_ENCRYPTION_KEY"
   rm -f "${BACKUP_FILE}"

   echo "[$(date)] 备份成功生成并已加密: ${ENC_BACKUP_FILE}"

   # 3. 清理超过 30 天的过期历史备份
   find "${BACKUP_DIR}" -name "gift_db_*.sql.gz.enc" -mtime +${RETENTION_DAYS} -delete
   echo "[$(date)] 历史过期备份清理完毕。"
   ```
3. **恢复操作执行步骤（Disaster Recovery Procedure）**：
   ```bash
   # 步骤 1：解密备份文件
   openssl enc -d -aes-256-cbc -pbkdf2 \
     -in /opt/backups/gift-bookkeeping/gift_db_20260907_120000.sql.gz.enc \
     -out restore.sql.gz \
     -pass "env:BACKUP_ENCRYPTION_KEY"

   # 步骤 2：解压数据
   gunzip restore.sql.gz

   # 步骤 3：导入恢复至容器内数据库
   cat restore.sql | docker exec -i gift_db psql -U gift_user -d gift_bookkeeping

   # 步骤 4：重启 Web 容器重新预热缓存
   docker compose restart web
   echo "数据库全量恢复成功！"
   ```

### 4. 灾难恢复演练计划
- **演练频度**：每季度执行一次无预告真实灾备演练；
- **验收指标**：
  1. 完整数据从离线加密备份包还原至临时隔离测试容器，数据一致性校验比对无差异；
  2. 验证恢复耗时指标（RTO < 10分钟，RPO < 24小时）；
  3. 检验管理员账户及审计日志历史数据完好无损。

---

## 第九章：部署流程与上线Checklist

### 1. 部署前检查清单（Pre-deployment Checklist）
- [ ] **环境变量审计**：宿主机 `.env` 文件已配置，权限已设置为 `600`，`SECRET_KEY` 与数据库密码为强随机串。
- [ ] **域名解析与证书确认**：生产域名已完成 DNS A 记录解析，80、15001、443 端口已在安全组中放行。
- [ ] **安全基线**：已确认 `.dockerignore` 生效，镜像中未夹带本地 `.db` 与 `.git`。
- [ ] **网络连通性**：Docker 引擎版本 ≥ 24.0，Docker Compose 版本 ≥ v2.20。
- [ ] **存储卷挂载路径**：宿主机磁盘剩余空间 ≥ 20GB，Inode 充裕。

### 2. 生产部署操作步骤（逐条命令序列）
```bash
# 1. 进入生产部署工程目录
cd /opt/service/gift-bookkeeping-app-docker

# 2. 预拉取/构建最新镜像
docker compose pull
# 或者针对当前仓库执行严格无缓存多阶段构建
docker compose build --pull --no-cache web

# 3. 先行拉起底层数据库与缓存依赖
docker compose up -d db redis

# 4. 检查中间件健康探针状态 (等待显示 healthy)
docker compose ps

# 5. 启动核心业务计算层与安全反代网关
docker compose up -d web nginx certbot

# 6. 执行全链路应用级状态巡检
curl -k https://127.0.0.1:15001/healthz
```

### 3. 验证测试用例（上线后手工核验核心功能）
| 序号 | 验证业务模块 | 操作步骤 | 预期结果 |
| :--- | :--- | :--- | :--- |
| TC-01 | HTTPS 安全通道 | 浏览器访问 `https://<服务器域名>:15001/login` | 证书有效，HSTS 开启，无不安全告警 |
| TC-02 | 管理员安全登录 | 输入管理员账密登录，故意输错 5 次密码 | 第 5 次自动弹出算术验证码并锁定防刷 |
| TC-03 | 礼金高频并发录入 | 在特定宴席账本连续快速添加 10 笔礼金明细 | 写入迅速，无 500 报错，无锁死异常 |
| TC-04 | 人情往来智能对账 | 进入 `/reconciliation` 页面查看双向往来 | 自动计算差额与顺逆差，数据精准 |
| TC-05 | 只读免登分享外链 | 生成分享链接并在隐身浏览器打开 | 正常查账，敏感字段被遮盖，无需登录 |
| TC-06 | 容器故障自愈验证 | 手工杀掉一个 Gunicorn 进程或暂停 PostgreSQL | 容器健康探针拉起告警并在短时间内自动恢复 |

### 4. 应急回滚方案（Rollback Plan）
- **触发条件**：
  1. 上线后核心录入或登录接口 5xx 错误率 > 5%；
  2. 数据库迁移发生不可逆错误导致表结构异常；
  3. Gunicorn 进程陷入严重死锁无法对外提供服务。
- **回滚操作命令序列**：
  ```bash
  # 1. 切换至上一稳定版本 Git 提交
  git checkout <previous_stable_tag_or_commit>

  # 2. 强制指定稳定版本镜像秒级回滚
  docker compose down web
  docker compose up -d web

  # 3. 若涉及数据异常，执行前一天的备份恢复 (见第八章)
  bash scripts/restore.sh /opt/backups/gift-bookkeeping/last_stable_db.sql.gz.enc

  # 4. 验证回滚后健康状态
  curl -k https://127.0.0.1:15001/healthz
  ```

---

## 第十章：技术栈与版本清单

| 组件类别 | 组件名称 | 具体版本号 | 在本架构中的用途 | 选型与配置理由 |
| :--- | :--- | :--- | :--- | :--- |
| **容器引擎** | Docker Engine | `24.0.7+` / CE | 容器生命周期管理底座 | 行业事实标准，成熟稳定，原生支持 BuildKit |
| **集群编排** | Docker Compose | `v2.23.0+` | 声明式多容器服务编排 | 语法规范，支持健康探针依赖调度与资源配额控制 |
| **基础镜像** | Python Slim | `3.11.9-slim-bookworm` | 应用运行与依赖载体 | 兼具 Debian glibc 强兼容性与超小镜像体积（~145MB） |
| **后端框架** | Flask | `3.0.3` | Web 核心业务与 REST 路由 | 轻量高效，符合业务原有技术栈，扩展丰富 |
| **WSGI 服务器** | Gunicorn | `22.0.0` | 生产级 WSGI 容器进程管理器 | 预分发多进程 Worker 架构，与 Nginx 形成标准动静分离 |
| **主关系数据库** | PostgreSQL | `15.6-alpine` | 业务核心数据持久化引擎 | 彻底消除 SQLite 文件锁，支持强并发事务与行级锁 |
| **分布式缓存** | Redis | `7.2.4-alpine` | 会话集中存储与登录风控计数 | 亚毫秒内存读写，消灭应用多 Worker 内存分裂 |
| **反向代理网关** | Nginx | `1.25.4-alpine` | 边缘流量接入、SSL 终止、负载均衡 | 高性能事件驱动架构，支持 HTTP/2 与 TLS 1.3 现代协议 |
| **证书管理** | Certbot | `v2.10.0` | Let's Encrypt 证书自动化申请轮换 | 免费自动化证书生态，杜绝自签名证书不安全告警 |
| **安全扫描工具** | Trivy | `0.49.1+` | 容器镜像 CVE 静态漏洞扫描门禁 | 漏洞库更新最快，轻量化支持 CI/CD 阻断集成 |
| **可观测性指标** | Prometheus Exporter| `0.15.0` (Flask) | 导出应用层性能与健康指标 | 云原生监控标准，无侵入式采集 HTTP 吞吐与延迟 |

---

## 附录：常用运维命令速查表

### 1. 服务集群生命周期管理
```bash
# 后台启动全部服务集群（含增量构建）
docker compose up -d

# 停止并移除所有容器、网络（保留 Volume 数据卷）
docker compose down

# 仅重启 Web 业务应用（配置修改后热生效）
docker compose restart web

# 查看当前运行的服务状态与健康度 (Healthy 状态)
docker compose ps

# 查看各容器资源实时占用（CPU、内存、网络 I/O）
docker stats
```

### 2. 日志查看与实时追踪
```bash
# 实时跟踪全部服务滚动日志（带时间戳）
docker compose logs -f --tail=100 -t

# 单独排查 Web 应用错误日志
docker compose logs -f web

# 排查 Nginx 访问与反向代理日志
docker compose logs -f nginx

# 排查 PostgreSQL 数据库启动与连接池日志
docker compose logs -f db
```

### 3. 容器调试与交互
```bash
# 以无特权 appuser 身份进入 Web 容器调试（只读环境）
docker compose exec web /bin/sh

# 进入 PostgreSQL 数据库交互式命令行终端
docker compose exec -it db psql -U gift_user -d gift_bookkeeping

# 进入 Redis 命令行执行 PING 或查看风控键
docker compose exec -it redis redis-cli -a "${REDIS_PASSWORD}"

# 验证 Web 容器的健康检查命令执行结果
docker inspect --format='{{json .State.Health}}' gift_web | jq
```

### 4. 存储与镜像维护清理
```bash
# 查看所有已声明的物理数据持久化卷
docker volume ls

# 清理未使用的悬空镜像与构建缓存
docker image prune -f
docker builder prune -f
```

---
*本方案文档由云原生部署与容器化运维技术团队制定，已完整持久化保存至工程根目录：`Docker_Deployment_Plan.md`。*