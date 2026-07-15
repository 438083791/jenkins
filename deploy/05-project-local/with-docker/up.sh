#!/usr/bin/env bash
# 方案五 · 有 Docker：启动绑定本仓库的 Jenkins（可 docker build / docker agent）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已生成 .env"
fi

# Linux 下将容器用户加入宿主机 docker 组，避免 permission denied
if [[ -z "${DOCKER_GID:-}" ]] && [[ -S /var/run/docker.sock ]]; then
  if command -v stat >/dev/null 2>&1; then
    export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
  fi
fi

# 写入 compose 可读的环境
if ! grep -q '^DOCKER_GID=' .env 2>/dev/null; then
  echo "DOCKER_GID=${DOCKER_GID:-0}" >> .env
fi

ACTION="${1:-up}"
case "${ACTION}" in
  up)
    docker compose up -d --build
    docker compose ps
    echo
    echo "Jenkins: http://localhost:\${JENKINS_HTTP_PORT:-8080} （见 .env）"
    echo "Pipeline 脚本: 仓库根目录 Jenkinsfile.docker"
    echo "或本目录 Jenkinsfile（内容相同）"
    ;;
  down)
    docker compose down
    ;;
  down-v)
    echo "将删除 jenkins_home 卷。5 秒后继续..."
    sleep 5
    docker compose down -v
    ;;
  logs)
    docker compose logs -f --tail=200
    ;;
  *)
    echo "用法: $0 {up|down|down-v|logs}" >&2
    exit 1
    ;;
esac
