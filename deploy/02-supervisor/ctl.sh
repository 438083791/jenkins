#!/usr/bin/env bash
# supervisorctl 常用封装（方案二：管业务应用，默认 program=web-test）
set -euo pipefail

PROGRAM="${PROGRAM_NAME:-web-test}"
ACTION="${1:-status}"

case "${ACTION}" in
  status|start|stop|restart)
    supervisorctl "${ACTION}" "${PROGRAM}"
    ;;
  logs|tail)
    supervisorctl tail -f "${PROGRAM}"
    ;;
  reload)
    supervisorctl reread
    supervisorctl update
    supervisorctl status
    ;;
  *)
    echo "用法: PROGRAM_NAME=web-test $0 {status|start|stop|restart|logs|reload}" >&2
    exit 1
    ;;
esac
