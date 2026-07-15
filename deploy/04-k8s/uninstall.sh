#!/usr/bin/env bash
# 卸载示例（需显式确认）
set -euo pipefail
TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "用法: $0 {jenkins|gitlab|all}" >&2
  exit 1
fi

uninstall_jenkins() {
  helm uninstall jenkins -n jenkins || true
  kubectl delete namespace jenkins --wait=false || true
}

uninstall_gitlab() {
  helm uninstall gitlab -n gitlab || true
  kubectl delete namespace gitlab --wait=false || true
}

echo "将卸载: ${TARGET} —— 5 秒后继续，Ctrl+C 取消"
sleep 5

case "${TARGET}" in
  jenkins) uninstall_jenkins ;;
  gitlab) uninstall_gitlab ;;
  all) uninstall_jenkins; uninstall_gitlab ;;
  *) echo "未知目标" >&2; exit 1 ;;
esac
