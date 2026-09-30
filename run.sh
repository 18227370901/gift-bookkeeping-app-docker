#!/bin/sh

# ============================================================
# run.sh (Docker版) — 模块加载与命令分发（V10.10.21 瘦身：263 → 约 40 行）
# 自定义配置: bin/config.sh（账密/端口/SNI/PG 默认值；支持 bin/config.local.sh 服务器专属覆盖，不入库）
# 启停操作:   bin/service.sh | 帮助文本: bin/help.sh
# 用法: ./run.sh {start|stop|restart|status|logs|build|clean}
#       ./run.sh {start|restart} --reconfig      重选数据库模式后执行
#       ./run.sh {start|restart} --reconfig-db   同上（完整别名）
# ============================================================

# ===== 加载 bin/ 模块（按依赖顺序） =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/bin/config.sh"         # ① 配置（必须最先，其余模块全部依赖这里的变量）
. "$SCRIPT_DIR/bin/common.sh"         # ② 彩色输出 + 文件覆盖决策
. "$SCRIPT_DIR/bin/cleanup.sh"        # ③ Docker 依赖检查 + 缓存清理
. "$SCRIPT_DIR/bin/ssl_certs.sh"      # ④ SSL 证书
. "$SCRIPT_DIR/bin/nginx_config.sh"   # ⑤ Nginx SNI 配置
. "$SCRIPT_DIR/bin/port_conflict.sh"  # ⑥ 端口冲突检测
. "$SCRIPT_DIR/bin/db_setup.sh"       # ⑦ 数据库模式函数（SQLite/共享PG/独立PG）
. "$SCRIPT_DIR/bin/db_select.sh"     # ⑧ 数据库选择（含 DB_ENV_FILE 定义与交互菜单）
. "$SCRIPT_DIR/bin/service.sh"       # ⑨ 启停操作函数
. "$SCRIPT_DIR/bin/help.sh"          # ⑩ 帮助文本

# ===== 主逻辑 =====
check_docker

# V10.10.23: --reconfig / --reconfig-db 后缀参数解析（替代 DB_RESET=1 环境变量，更直观）
# 用法: ./run.sh restart --reconfig  或  ./run.sh start --reconfig-db
# $1=子命令，$2 可选 --reconfig/--reconfig-db；DB_RESET=1 环境变量仍保留兼容（cron/CI 场景）
case "$2" in
    --reconfig|--reconfig-db)
        DB_RESET=1
        ;;
esac

case "$1" in
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status|ps) status_service ;;
    logs) logs_service ;;
    build) build_service ;;
    clean) cleanup_cache ;;
    *) show_help; exit 1 ;;
esac

exit 0
