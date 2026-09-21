---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'd42e3be2-53c7-4e6d-9e96-765af73423b7'
  PropagateID: 'd42e3be2-53c7-4e6d-9e96-765af73423b7'
  ReservedCode1: 'e8c134f8-4d04-4af9-a370-8919601970a9'
  ReservedCode2: 'e8c134f8-4d04-4af9-a370-8919601970a9'
---

# 人情礼金记账系统 (Docker Compose 自动化部署版)

[![Docker](https://img.shields.io/badge/Docker-Compose-blue.svg)](https://www.docker.com/)
[![Flask](https://img.shields.io/badge/Flask-3.0.3-green.svg)](https://flask.palletsprojects.com/)
[![Nginx](https://img.shields.io/badge/Nginx-SSL_Proxy-brightgreen.svg)](https://nginx.org/)

> **最新更新说明**：
> - 🔧 **V10.10.4 f-string 兼容修复、Nginx 路径默认值调整与 run.sh POSIX 兼容化（2026-09-21）**：①修复 `routes_ext.py:4441` f-string 引号冲突导致 Docker 镜像（Python 3.11）`SyntaxError` 容器无法启动（外层单引号改双引号，3.12 兼容写法适配 3.11）；②`NGINX_CONF_DIR` 默认值从 `/etc/nginx/conf.d` 改为 `/opt/service/nginx/conf.d`，目录不存在时提示用户手动创建（不自动 mkdir/不跳过/不删除），可通过环境变量覆盖旧路径；③`run.sh` 全面 POSIX 兼容化——`#!/bin/bash`→`#!/bin/sh`，移除 bash 自愈逻辑，`${BASH_SOURCE}`→`$0`，`echo -e`→新增 `echo_e()` 函数（`printf '%b\n'`），`read -r -p`→`printf+read`，`((wait_time++))`→`$((wait_time+1))`，`source`→`.`。`sh run.sh status` 不再报 `Bad substitution`/`() unexpected` 等。两版同步，`bash -n`+`dash -n` 双校验通过。
> - 🔐 **V10.10.3 run.sh 证书与 Nginx 配置覆盖保护（2026-09-20）**：修复每次 `start`/`restart` 无条件重新生成自签证书、覆盖渲染 Nginx 配置，导致用户自行替换的正式证书或手工定制内容被静默覆盖丢失的问题。现在证书/配置**文件不存在时直接创建**（不询问）；**已存在时先弹 `y/n` 询问**（默认 `n` 保留，回车即安全）；非交互环境（cron/CI/管道）自动保留旧文件不卡死。新增环境变量 `SSL_FORCE_UPDATE=1` / `NGINX_CONF_FORCE_UPDATE=1` 供自动化场景强制更新（设 `0` 强制保留）。两版 `should_overwrite` 函数逐字一致，功能测试全部通过（逻辑 6/6 + 端到端 14/14 + Docker 版 7/7）。
> - 🔀 **V10.10 与原生部署版全量功能同步（2026-09-18）**：本 Docker 版已将原生版 V2 ~ V10.10 的全部功能演进同步完毕，两版功能完全一致、部署形态各自独立（原生版 venv 直跑，本版 Docker Compose 编排）。本次同步内容：
>   - 🤖 **AI 助手三件套**：多会话聊天（创建/重命名/删除）、四级配置优先级容错（用户多配置 → 旧版单配置 → 全局环境变量 → 管理员共享配置）、DuckDuckGo 联网搜索增强、本地兜底引擎、管理员多配置管理与普通用户授权；
>   - 📋 **权限申请工单**：新注册用户默认无菜单权限，需提交工单申请、管理员审批（通过/驳回附理由/撤销）后方可使用；无权限用户首页显示友好的申请引导卡片；
>   - 📡 **Webhook 全面重构（V10.1 ~ V10.9.1）**：用户级/事件级监控范围可配置、15 页面 × 12 事件推送矩阵、7 占位符场景化消息模板、约 40 处推送点全项目覆盖、推送日志自动脱敏；
>   - ☁️ **WebDAV 备份增强**：AES-256 加密 zip 备份（pyzipper）、Cron 定时备份调度器、普通用户隔离备份（仅含本人数据的过滤库）、数据级合并恢复、备份功能与定时任务分级授权；
>   - 👥 **权限级别语义修正**：级别 1 改为「自身全权 + 他人仅查看」（原为仅查看），六大子菜单（新增备份管理），13 模块审计日志可配置记录；
>   - 🌐 **Nginx SNI 多项目共用 443 端口**：`NGINX_PORT` 默认 15001 → **443**，多项目（如与「萌芽」平台）同机部署依靠 SNI 域名分流，每项目一份独立 Nginx 配置（`$PROJECT_NAME.conf`）；
>   - 🛡️ **镜像与仓库安全加固**：新增 `.dockerignore`（排除 .git、数据库、备份、证书、密钥等敏感文件，防止打入镜像泄露）；`.gitignore` 新增运行时附属文件忽略（`*.bak`、`*.db-wal`、`data/`、`ssl/`、`.env` 等）；
>   - 📦 **新增依赖**：`openai`、`duckduckgo_search`、`pyzipper`（首次部署需重新构建镜像）；
>   - 🗄️ **数据库自动迁移**：已有数据卷无需手工处理，启动时 `init_database()` 自动补建 7 张新表（AI 会话/消息/查询日志、定时备份任务、执行日志、备份附件、权限工单）与全部新列。
> - 📊 **V10.10.2 样例数据体系扩充与两版统一（2026-09-20）**：礼金记账明细从 104 条扩充至 **151 条**（新增随礼 42 条 + 收礼 6 条），形成完整的人情对账双向往来闭环；亲友纪念日备忘从 4 条扩充至 6 条；两版（原生部署版与本 Docker 版）根目录样例库 `gift_bookkeeping.db` 实现字节级统一（MD5 一致），开箱演示体验完全相同。全部姓名、电话、地址均为虚构演示数据。
> - 🐛 **V10.10.1 人情对账状态标签方向修复（2026-09-20）**：修复对账页面「人情状态」标签与差额方向完全相反的 Bug。`net_balance = 收礼 - 随礼`，原 net > 0 错显「待还礼」、net < 0 错显「待补礼」，现已对调为：net > 0 → 待补礼（红色，我方需回）、net < 0 → 待还礼（绿色，尚欠我方）。涉及 `gift_utils.py` 状态字典、`routes_ext.py` 筛选条件与排序方向、`templates/reconciliation.html` 徽章与下拉文案，差额数值计算本身未改动。
> - 🔔 **2.1 纪念日到期单次推送防重机制（周期锁架构）**：- 检查 if r.last_notified_target == target_cycle_str: continue，已成功推送过的周期直接跳过，杜绝 60 秒死循环；
> - ☁️ **2.2 WebDAV 智能路径解析与递归自动建目录（MKCOL）**：- 智能识别坚果云等 WebDAV 根路径（如以 /dav 结尾），当未指定子目录时，自动挂载默认安全备份目录 /gift_backups/，防止根路径直写触发 404。
> - 🔒 **2.3 容器依赖与敏感数据零明文加固**：2. **敏感凭据安全闭环**：WebDAV 账号密码、Webhook 密钥等高敏感数据全部强制以 AES-256-GCM 密文存储，日志自动脱敏掩码，保证生产环境数据安全。
> - 🛡️ **密保找回密码算术验证码与动态刷新**：找回密码流程全面接入算术验证码防护机制（支持 `/forgot-password/captcha` 接口无感拉取与动态点击刷新），有效防御针对密保答案的自动化暴力破解与脚本探测。
> - ⏳ **管理员/普通用户找回密码防爆破与倒计时临时锁定**：密保答案错误触发递增计数与错误上限预警；达到上限后自动进入临时冷却锁定状态（支持毫秒级动态倒计时实时解锁），阻断高频撞库风险。
> - 🔑 **密码复杂度校验机制与函数修复**：重置密码与修改密码全面接入强口令复杂度验证规则（长度至少6位且同时包含字母与数字），严控弱口令风险，修复缺失复杂度校验函数引发的 500 异常。
> - 📊 **补充并丰富 100 条开箱即用样例数据**：涵盖婚宴、满月酒、周岁宴、寿宴、升学宴、乔迁宴、生日、百日宴等多种典型人情往来场景，方便开箱即用与图表数据预览。
> - 👥 **用户跨权限管理与层级控制**：管理员可为普通用户精细化配置跨用户数据权限（查看他人、编辑他人、删除他人），层级向下兼容包含。
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


## 🌟 核心功能模块与技术资产

系统已集成全套现代化礼金记账业务闭环与企业级基础设施：

### 1. 礼金账本 (Gift Ledger)
- 支持**收礼**（收入，绿色标签）与**随礼/还礼**（支出，红色标签）双向记账；
- **智能复合 NLP 记账**：支持自然语言输入（如“昨天李四儿子满月微信随了600，收张三结婚礼金888”），内置分词切分器自动拆分并批量解析入库；
- 支持大额中文数字转换（`cn2num`：贰佰元 -> 200）；
- 支持多维度筛选、关键词模糊检索、多格式数据批量导出（CSV / Excel）。

### 2. 专属宴席账本 (Banquets)
- 针对婚礼、寿宴、满月宴、乔迁宴等集中办事场景提供独立专项台账；
- 独家支持**卡片视图**与**紧凑表格视图**一键切换、全选/批量操作；
- **免登录协同外链**：可生成带有口令保护与有效期的只读共享链接，支持隐藏金额与备注等隐私信息。

### 3. 人情对账与还礼建议 (Reconciliation & Suggestions)
- 智能聚合双方所有历史收礼与送礼明细，自动核算净差额与资金流向；
- 根据亲疏关系、历史通胀与当地人情习俗，智能提供建议还礼参考区间。

### 4. 亲友纪念日备忘 (Anniversary Reminders)
- 记录亲友生日、结婚纪念日、重大节日，支持公历/农历智能转换；
- 支持多轮定时手动推送与阈值天数后台自动巡检主动推送。

### 5. 全系统统一回收站 (Recycle Bin)
- 礼金记录与亲友纪念日均采用软删除（`deleted_at`）防护机制；
- 具备独立权限管控、误删安全拦截与一键原位复原能力。

### 6. 企业微信智能机器人与多通道 Webhook
- **官方 SDK 深度集成**：完整引入企业微信智能机器人官方 SDK（`wecom-aibot-python-sdk`），支持 WebSocket 长连接双向打通与会话 `chatid` 自动捕获；
- **全渠道推送覆盖**：支持企业微信机器人、钉钉群机器人、飞书机器人、Server酱、PushPlus、Bark 等多通道按需触发；
- 支持多轮定时推送与日志全生命周期审计管理。

### 7. WebDAV 云端备份、加密与一键恢复 (Cloud Backup)
- 基于 `requests.Session` 连接池与流式传输，支持手动一键备份 SQLite 数据库至坚果云、群晖 NAS、Nextcloud 等外部存储，并提供安全还原；
- **AES-256 加密备份**：使用 `pyzipper` 生成加密 zip 备份，自动任务使用管理员预设密码加密，手动备份可自选是否加密；
- **定时备份调度器**：支持 Cron 表达式配置定时任务，后台守护线程每 60 秒巡检并自动执行，完整记录执行历史日志；
- **多用户隔离备份**：普通用户仅能备份含本人数据的过滤库（数据级权限隔离），恢复走数据级合并不覆盖全局表；备份功能与定时任务均需管理员分级授权。

### 8. 用户管理与细粒度多菜单权限控制 (RBAC)
- 独创六大子菜单独立授权机制（记账大厅、专属宴席、人情对账、纪念日备忘、回收站、备份管理）；
- 支持设置 0（禁止）、1（自身全权 + 他人仅查看）、2（自身全权 + 他人查看与修改）、3（自身全权 + 他人查看/修改/删除）；
- 阶梯式防越权设计：普通用户无论被赋予何种权限，均无法修改或删除管理员数据；
- **权限申请工单闭环**：新注册用户默认无任何菜单权限，需提交工单申请并由管理员审批（通过/驳回附理由/撤销）后方可使用；
- 管理员账号凭据查看配备二次身份核验。

### 9. AI 智能助手 (AI Assistant)
- **多会话聊天**：支持会话创建/重命名/删除，侧边栏会话列表 + 消息气泡对话区，推荐问题引导；
- **四级配置优先级容错**：用户多配置 → 用户旧版单配置 → 全局环境变量 → 管理员共享配置（仅被授权用户），逐级尝试直至成功；
- **联网搜索增强**：自动识别需要联网的关键词（天气/新闻/最新/实时等），通过 DuckDuckGo 搜索后结合 AI 生成摘要；
- **本地兜底引擎**：所有 AI 配置不可用时内置离线问答引擎，保障功能永不中断；
- **授权管理**：管理员可授权/撤销普通用户的 AI 使用权限，并维护多个 AI 服务配置（API Key + Base URL + Model，支持启用/禁用与优先级）。

### 10. 敏感数据零明文安全加密与日志脱敏 (Security & Privacy)
- **底层强加密 (AES-256-GCM)**：企业微信机器人 Bot Secret、Webhook 签名密钥、WebDAV 密码、备份加密密码、AI API Key、共享外链口令及用户安全凭据全部采用 AES-256-GCM 密文存储，杜绝数据库明文泄露；
- **日志全自动递归脱敏**：写入 `webhook_logs` 的请求载荷与响应内容自动扫描脱敏，彻底屏蔽密钥信息；审计日志支持 13 个模块可配置记录；
- **自适应数据卷探测**：适配 Docker Compose `/app/data/gift_bookkeeping.db` 持久化挂载目录；
- **SQLite WAL 模式高并发优化**：开启 WAL 模式与 30 秒忙等待超时，保障多容器/多进程并发读写绝对平稳。

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
# 将您的 server.crt 和 server.key 复制进 ssl/ 文件夹
```
> 💡 **快速测试证书生成**：如果没有真实证书，可先运行项目内置的生成脚本一键创建测试证书（`--domain` 写入 SNI 域名，支持域名或 IP，避免浏览器报证书域名不匹配）：
> ```bash
> python generate_ssl_certs.py --domain gift-docker.example.com
> # 证书自动生成于 ssl/server.crt 与 ssl/server.key
> ```
> 注：`run.sh start` 会自动传入 `--domain $SNI_DOMAIN` 生成证书，无需手工执行。

### 3. 启动服务并访问系统
```bash
chmod +x run.sh
SNI_DOMAIN=gift-docker.example.com ./run.sh start
```
- **HTTPS 访问地址**：`https://<您的SNI域名>`（`NGINX_PORT` 默认 443，标准端口无需附端口号；自定义非 443 端口时访问 `https://<域名>:<端口>`）
- **端口转发链路**：客户端 → 宿主机 Nginx（HTTPS 443，SNI 域名分流）→ 宿主机映射端口 `127.0.0.1:15000` → Web 容器 `11443`

---

## 🐳 运行脚本 `run.sh` 服务管理（Docker Compose 编排）

根目录下提供了 Docker 生命周期管理脚本 `run.sh`。运行 `start` 指令时，脚本会**自动生成/刷新 SSL 自签名证书（写入 SNI 域名）**、**渲染 Nginx SNI 配置文件**，然后使用 Docker Compose 拉起容器集群。

```bash
# 1. 赋予可执行权限
chmod +x run.sh

# 2. 启动服务（自动生成证书 + 渲染 Nginx SNI 配置 + 构建镜像 + 后台启动容器集群）
SNI_DOMAIN=gift-docker.example.com ./run.sh start

# 3. 服务管理指令
./run.sh start    # 启动服务
./run.sh stop     # 停止服务
./run.sh status   # 查看状态
./run.sh restart  # 重启服务
```

> 💡 **自定义管理员账号密码与端口拓扑**：
> 可在 `run.sh` 脚本头的环境变量配置区域修改 `PORT`（Web容器端口，默认 11443）、`HOST_PORT`（宿主机映射端口，默认 15000）、`NGINX_PORT`（Nginx监听端口，默认 443）、`ADMIN_USER` 和 `ADMIN_PASS`。
> 端口转发链路拓扑为：**客户端 -> 宿主机 Nginx (HTTPS $NGINX_PORT端口, SNI 域名分流) -> 宿主机映射端口 (127.0.0.1:$HOST_PORT) -> Web容器应用 ($PORT端口)**。
> 在执行 `./run.sh start` 或 `./run.sh restart` 时，系统将自动将设置的端口更新至 `docker-compose.yml` 及 Nginx 配置文件 `$PROJECT_NAME.conf`（默认 `gift_app_docker.conf`）中并重载生效。
>
> 💡 **多项目共用 443 端口 SNI 分流**（V10.10）：
> 同一台服务器多个项目可共用 443 端口，依靠域名（SNI）区分流量，各项目启动时指定专属变量即可：
> ```bash
> # 本项目（Docker 版，默认不作为兑底）
> SNI_DOMAIN=gift-docker.example.com PROJECT_NAME=gift_app_docker SNI_DEFAULT_SERVER=0 ./run.sh start
> # 另一项目（如萌芽平台，作为 443 兑底 default_server）
> PROJECT_NAME=mengyao SNI_DOMAIN=mengyao.example.com SNI_DEFAULT_SERVER=1 ./run.sh start
> ```
> - `PROJECT_NAME`：项目标识，决定 Nginx 配置文件名与 upstream 名（默认 `gift_app_docker`，与原生版 `gift_app` 自动区分）
> - `SNI_DOMAIN`：SNI 域名，写入 server_name 与证书 CN/SAN（默认 localhost；生产部署建议环境变量覆盖为实际域名，**为空时启动中止**）
> - `SNI_DEFAULT_SERVER`：是否作为 443 兑底 default_server，多项目只应有一个设为 1（默认 0；若同机原生版 `gift_app` 已作兑底则保持 0）
> - `SSL_CERT` / `SSL_KEY`：可指向正式证书路径，默认使用自动生成的自签证书

---

## ⚙️ 常用运维指令与 `run.sh` 使用指南

本项目提供了标准的 Docker 生命周期管理脚本 `run.sh`：

```bash
chmod +x run.sh

./run.sh start    # 自动检查/生成 SSL 证书（写入 SNI 域名），渲染 Nginx SNI 配置并使用 Docker Compose 启动容器集群 (暴露宿主机 15000 端口)
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
SNI_DOMAIN=gift-docker.example.com ./run.sh start
```
> 💡 **端口暴露机制**：Web 容器内开放 `11443` 端口，通过 `docker-compose.yml` 映射暴露为宿主机的 `15000` 端口，再由宿主机 Nginx 反向代理对外提供 HTTPS 443 服务。
> ⚠️ **首次部署 V10.10 同步版本需重新构建镜像**：本次同步新增 `openai`、`duckduckgo_search`、`pyzipper` 三个依赖，`./run.sh start`（含 `up -d --build`）会自动完成镜像重建。

### 3. Nginx SNI 反向代理（由 run.sh 自动完成）
`./run.sh start` 会自动完成以下三步，通常无需手工操作：
1. **生成自签名证书**：`generate_ssl_certs.py --domain $SNI_DOMAIN`，证书写入根目录 `ssl/`（如已有正式证书，通过 `SSL_CERT`/`SSL_KEY` 变量指向即可跳过自签）；
2. **渲染 Nginx 配置**：依据占位符模板 `nginx_ssl.conf` 生成 `$NGINX_CONF_DIR/$PROJECT_NAME.conf`（默认 `/etc/nginx/conf.d/gift_app_docker.conf`），写入 SNI 域名、监听端口（默认 443）与证书路径；
3. **互斥禁用冲突配置**：同机存在原生版部署时，自动将 `gift_app.conf` / `gift_app_native.conf` 及本版旧命名配置改名 `.disabled`，防止同端口多配置冲突导致 502；随后自动 `nginx -t` 校验并热重载。

如需手工校验与重载：
```bash
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

## 📦 开箱即用样例数据体系说明 (Sample Data)

为了便于开箱即用体验、UI 效果预览与全功能闭环联调，项目内置了全套高仿真、去隐私化且零明文落盘的样例数据：

1. **多角色用户账户**：
   - 超级管理员：`admin` / `admin123`（具备全部子菜单与系统管理控制权，密保答案经加盐哈希安全存储）
   - 普通测试用户：`testuser` / `test123456`（具备记账、宴席、对账与备忘权限）
2. **专属宴席台账 (4 场标准典范)**：
   - `2026年 儿子大婚浪漫喜宴`（事由：结婚，预算 6.8 万，花销 6.28 万，已关联收礼明细）
   - `2026年 宝宝周岁满月答谢宴`（事由：满月酒，预算 2 万，花销 1.68 万，已关联收礼明细）
   - `2026年 乔迁新居阖家福酒`（事由：乔迁，预算 1.5 万，花销 1.2 万）
   - `2026年 老父亲七十古稀寿宴`（事由：寿宴，预算 2.8 万，花销 2.56 万）
3. **礼金记账明细 (151 条高仿真记录)**：
   - **收礼 107 条**（合计约 13.1 万元）：涵盖婚宴、满月酒、百日宴、周岁宴、寿宴、升学宴、乔迁、开业、生日等全部典型人情往来场景，部分记录关联专属宴席台账；
   - **随礼 42 条**（合计约 2.3 万元）：涵盖参加他人婚宴、寿宴、满月酒、升学宴、乔迁、开业、白事、生日等随礼场景，与收礼记录形成完整的人情对账闭环（如「柏楚安」等亲友存在收礼+随礼双向往来，可直接体验人情对账的「待补礼/待还礼」状态流转）；
   - 姓名、电话、地址均为虚构演示数据，无真实个人信息；样例库随仓库分发，首次启动时 `init_database()` 自动补齐 AI 会话、权限工单等新表，开箱零配置。
4. **亲友纪念日备忘 (6 条预警配置)**：
   - 涵盖父亲七十大寿、结婚三周年纪念日、挚友生日、升学宴、岳母六十五寿辰、结婚十周年纪念日等；手机号码全量采用去隐私化虚拟测试号码（`13800000001`~`13800003002`）。
5. **智能机器人与 Webhook 通道 (3 组标准示例)**：
   - 企业微信官方智能机器人（WebSocket 长连接 openws 模式）
   - 企业微信群机器人（Webhook URL 模式）
   - 钉钉群机器人（Webhook URL 模式）
   - *安全说明*：所有机器人的密钥（`bot_secret` 与 `secret_token`）在数据库底层均经过 **AES-256-GCM 强加密存储**，开箱默认状态为已禁用（`is_enabled=0`），零明文落盘，绝无凭证泄露风险。
5. **大账本只读共享外链 (2 组)**：
   - 儿子大婚与宝宝满月对外分享外链，口令（`123456` / `666888`）底层通过 AES-256-GCM 强加密存储，支持设置隐藏金额/备注等安全查看策略。
6. **系统广播通知 (2 条)**：
   - 涵盖版本升级全量功能特性公告及初次使用安全提醒。
7. **WebDAV 外部云端备份配置**：
   - 预设坚果云标准 WebDAV 接入示例，应用密码经 AES-256-GCM 强加密存储，默认禁用自动备份。

---

## 🌐 项目多形态交付与仓库矩阵 (Ecosystem)

本套人情礼金记账系统提供三种产品部署与交付形态，源码均已同步发布至 GitHub：

| 形态 | GitHub 仓库地址 | 适用场景 |
|:---|:---|:---|
| 🖥️ **Web 原生部署版** | [gift-bookkeeping-app](https://github.com/18227370901/gift-bookkeeping-app.git) | 适合本地 Python 环境、虚拟主机、轻量 VPS 单机运行 |
| 🐳 **Docker Compose 版** | [gift-bookkeeping-app-docker](https://github.com/18227370901/gift-bookkeeping-app-docker.git) | 适合企业生产服务器、一键容器编排、Nginx 反代与 SSL 自动化管理 |
| 📱 **Android 原生 APK 版** | [gift_bookkeeping_apk](https://github.com/18227370901/gift_bookkeeping_apk.git) | 适合安卓手机与平板脱机随身离线使用 |

---

## 🔑 默认管理员账户与安全提醒
- 系统启动时会自动根据配置初始化管理员账户，建议成功部署后登录并设置密保问题！