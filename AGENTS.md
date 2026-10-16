# 人情礼金记账系统 (Gift Bookkeeping App - Docker 版) - AI 协作与维护规范

本项目已全面实行**模块化文档分层治理**与**Docker 容器化规范架构**。后续任何 AI 编程助手（包括 Codex、Cursor、Claude Code、Windsurf、Aider、Copilot、ChatGPT 等）在接手、维护、重构或升级本项目时，**必须严格遵循本规范**。

---

## 一、文档维护铁律（强制执行）

### 1. `README.md` 首页极简规范
- **篇幅上限**：严格控制在 150 ~ 180 行以内（约 6~10 KB）。
- **内容范围**：仅允许包含项目标题、核心徽章、产品定位、默认管理员账号与安全警示、9 大核心业务能力概览、快速启动指南（Docker Compose 与 run.sh）、系统架构概览树、文档导航索引及开源许可证。
- **严禁行为**：**严禁在 `README.md` 中追加任何版本的详细更新日志、版本升级公告、冗长命令或深层技术细节！**

### 2. 文档专属路由与分流规则
当产生新功能、Bug 修复、发布记录或架构改动时，请一律将信息写入 `docs/` 下的对应专属文档，绝对不得堆砌在根目录：
- 📜 **版本发布与全量更新日志** ➔ 一律追加至 `docs/CHANGELOG.md`
  - 新版本请按时间与版本号降序追加在 `## 🌟 V10.11 系列全版本演化与架构升级记录` 最上方；
  - 必须记录版本号、发布日期、核心变更、修复缺陷及验证结果。
- 📐 **架构设计规范与 ADR 决策记录** ➔ 一律追加至 `docs/PSD_Design_Document.md` 并同步更新 `docs/PSD_Design_Document.html`
  - 架构重组、重大设计决策请按序号递增记录新的 ADR（如 ADR-53、ADR-54 等）。
- 🛠️ **Docker 部署手册、Compose 编排、免构建镜像、Nginx 443 SNI 分流与服务器运维** ➔ 一律更新至 `docs/DEPLOYMENT.md`
- 📦 **样例数据库说明、敏感数据脱敏与推送前 9 项核查规范** ➔ 一律更新至 `docs/SAMPLE_DATA.md`
- 📱 **Android 原生 APK 打包与 CI/CD** ➔ 一律更新至 `docs/ANDROID_BUILD.md`

---

## 二、代码架构与文件分层规范

项目根目录保持高度整洁，仅保留核心启动入口与基础文件：
```text
gift_bookkeeping_app-docker/
├── app.py                     # [核心] Flask 主应用启动入口
├── gunicorn.conf.py           # [核心] Gunicorn 生产容器启动配置 (1 worker + 4 gthread)
├── Dockerfile                 # [核心] 生产级多阶段优化构建文件 (Python 3.11-slim)
├── docker-compose.yml         # [核心] Docker Compose 主编排文件 (SQLite 默认)
├── docker-compose.db.yml      # [核心] 独立 PostgreSQL 数据库编排文件
├── run.sh                     # [核心] Linux 一键后台运维与服务管理脚本
├── requirements.txt           # [核心] Python 依赖清单
├── gift_bookkeeping.db        # [数据] 开箱即用官方样例数据库 (方案 A 保留)
├── README.md                  # [自述] 极简项目说明与快速上手导航 (< 180 行)
├── AGENTS.md                  # [规范] 跨 AI 协作与维护指南
├── .gitignore / .dockerignore # [规则] Git 与 Docker 构建排除规则
│
├── docs/                      # 📁 [文档中心] 统一管理系统设计、运维手册与发布日志
├── config/                    # 📁 [配置中心] Nginx 代理与模板配置 (支持双路径向后兼容)
├── bin/                       # 运维管理子脚本模块 (service, config, db_setup 等)
├── routes/                    # Flask 业务路由注册包 (routes_ext, routes_ai 等)
├── services/                  # 核心服务层与数据模型 (models, ai_service 等)
├── templates/                 # 前端 HTML 模板
├── static/                    # 前端静态静态资源
├── tools/                     # 工具脚本 (SSL 证书生成等)
├── aibot/                     # 企微 SDK 源码包
├── data/                      # 生产持久化运行库与附件 (Docker 卷挂载，不入库)
└── logs/                      # 运行日志/PID/备份/API 缓存 (仅本地，不入库)
```

---

## 三、开发与修改规范

1. **零业务破坏原则**：
   - 结构重构与文件移动必须遵循等价替换与向后兼容，不得私自更改已有业务逻辑、路由端点与数据模型字段。
   - 文件移动后必须同步检查相对路径（如 `__file__` 锚点层级）、`import` 路径及 Shell 脚本的引用路径。
2. **零明文安全原则**：
   - 严禁将真实凭证（Webhook Token、WebDAV 密码、真实手机号或真实人名）提交进 Git。
   - 敏感信息与服务器专属配置必须存放在 `bin/config.local.sh` 或 `config/*.local.*`，它们已被 `.gitignore` 规则保护，绝不入库。
3. **验证闭环**：
   - 每次代码改动后，必须至少执行语法验证（如 `python -m py_compile` 或 `ast.parse`）；
   - 涉及 Shell 脚本修改，必须执行 `sh -n` 校验语法。
