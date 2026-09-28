# -*- coding: utf-8 -*-
"""
Gunicorn 配置文件
V10.10.16 性能优化：
1. 默认 1 worker + gthread 4 线程（并发能力与原 4 sync workers 持平，内存降至 1/4）
2. timeout=60 防止 AI 聊天长响应被杀
3. max_requests 周期回收内存，防止长驻进程 RSS 缓涨
4. GUNICORN_WORKERS 环境变量可调，适配不同负载场景
"""

import os
import multiprocessing

# Worker 数量：默认 1（家庭/小团队场景够用），通过环境变量可调
workers = int(os.environ.get('GUNICORN_WORKERS', '1'))

# 使用 gthread 多线程模式，单进程内 4 线程并发
# （原 4 sync worker = 4 并发 → 1 worker × 4 threads = 4 并发，持平）
worker_class = 'gthread'
threads = int(os.environ.get('GUNICORN_THREADS', '4'))

# 请求超时：AI 聊天可能有 30s+ 长响应，原默认 30s 会误杀 worker
timeout = int(os.environ.get('GUNICORN_TIMEOUT', '60'))

# 绑定地址
bind = os.environ.get('GUNICORN_BIND', '0.0.0.0:11443')

# 预加载应用：关闭（与模块级守护线程启动冲突，会导致线程丢失）
preload_app = False

# 工作进程周期回收：每个 worker 处理 2000 个请求后优雅重启（±200 抖动避免同时回收）
max_requests = int(os.environ.get('GUNICORN_MAX_REQUESTS', '2000'))
max_requests_jitter = 200

# 日志
accesslog = '-'
errorlog = '-'
loglevel = os.environ.get('GUNICORN_LOG_LEVEL', 'warning')

# 优雅关闭超时（收到 SIGTERM 后等待 worker 处理完当前请求的最长时间）
graceful_timeout = 15

# 保持连接
keepalive = 5

# 进程名（便于容器内识别）
proc_name = 'gift-bookkeeping'

# 当 worker 意外退出时自动重启
daemon = False
