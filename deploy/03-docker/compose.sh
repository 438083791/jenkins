#!/usr/bin/env bash
# 方案三：启动 / 停止 / 查看状态
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  echo "未找到 .env，正在从 .env.example 复制..."
  cp .env.example .env
fi

ACTION="${1:-up}"
case "${ACTION}" in
  up)
    docker compose pull
    docker compose up -d
    docker compose ps
    ;;
  down)
    docker compose down
    ;;
  down-v)
    echo "将删除 volumes，请确认了解风险。5 秒后继续 Ctrl+C 取消..."
    sleep 5
    docker compose down -v
    ;;
  logs)
    docker compose logs -f --tail=200 "${2:-}"
    ;;
  ps|status)
    docker compose ps
    ;;
  passwords)
    echo "=== Jenkins initialAdminPassword ==="
    docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword || true
    echo
    echo "=== GitLab initial_root_password ==="
    docker compose exec gitlab cat /etc/gitlab/initial_root_password || true
    ;;
  *)
    echo "用法: $0 {up|down|down-v|logs|ps|passwords}" >&2
    exit 1
    ;;
esac
