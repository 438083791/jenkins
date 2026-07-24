#!/usr/bin/env bash
# supervisorctl 常用封装（方案二：管业务应用，默认 program=web-test）
#
# 查看更多日志：
#   bash ctl.sh logs              # 跟踪（等同 supervisorctl tail -f）
#   bash ctl.sh tail              # 同上
#   bash ctl.sh last              # 最近约 500KB（supervisorctl，单位是字节不是行）
#   bash ctl.sh last 2000000      # 最近约 2MB
#   bash ctl.sh file              # 直接读日志文件，默认最后 500 行
#   bash ctl.sh file 2000         # 最后 2000 行（更全，推荐）
set -euo pipefail

PROGRAM="${PROGRAM_NAME:-web-test}"
ACTION="${1:-status}"
ARG2="${2:-}"
LOG_DIR="${LOG_DIR:-/opt/app-logs}"
OUT_LOG="${OUT_LOG:-${LOG_DIR}/${PROGRAM}.out.log}"
ERR_LOG="${ERR_LOG:-${LOG_DIR}/${PROGRAM}.err.log}"

case "${ACTION}" in
  status|start|stop|restart)
    supervisorctl "${ACTION}" "${PROGRAM}"
    ;;
  logs|tail)
    supervisorctl tail -f "${PROGRAM}"
    ;;
  last)
    # supervisorctl tail -<N> 的 N 是「字节数」，不是行数
    BYTES="${ARG2:-512000}"
    echo "==== stdout（最近 ${BYTES} 字节）===="
    supervisorctl tail "-${BYTES}" "${PROGRAM}" stdout
    echo
    echo "==== stderr（最近 ${BYTES} 字节）===="
    supervisorctl tail "-${BYTES}" "${PROGRAM}" stderr || true
    ;;
  file)
    # 直接读文件，可指定行数，比 Web UI / supervisorctl 默认更全
    LINES="${ARG2:-500}"
    echo "==== ${OUT_LOG}（最后 ${LINES} 行）===="
    if [[ -f "${OUT_LOG}" ]]; then
      tail -n "${LINES}" "${OUT_LOG}"
    else
      echo "(文件不存在)"
    fi
    echo
    echo "==== ${ERR_LOG}（最后 ${LINES} 行）===="
    if [[ -f "${ERR_LOG}" ]]; then
      tail -n "${LINES}" "${ERR_LOG}"
    else
      echo "(文件不存在)"
    fi
    ;;
  reload)
    supervisorctl reread
    supervisorctl update
    supervisorctl status
    ;;
  *)
    echo "用法: PROGRAM_NAME=web-test $0 {status|start|stop|restart|logs|last [字节]|file [行数]|reload}" >&2
    exit 1
    ;;
esac
