#!/usr/bin/env bash
# supervisorctl 常用封装
set -euo pipefail
ACTION="${1:-status}"
case "${ACTION}" in
  status|start|stop|restart)
    supervisorctl "${ACTION}" jenkins
    ;;
  logs|tail)
    supervisorctl tail -f jenkins
    ;;
  reload)
    supervisorctl reread
    supervisorctl update
    supervisorctl status
    ;;
  *)
    echo "用法: $0 {status|start|stop|restart|logs|reload}" >&2
    exit 1
    ;;
esac
