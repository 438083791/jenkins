#!/usr/bin/env bash
# 方案三：启动 / 停止 GitLab + Jenkins（JDK21 自定义镜像，支持 Docker 部署）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  echo "未找到 .env，正在从 .env.example 复制..."
  cp .env.example .env
fi

# Linux：把容器用户加入宿主机 docker 组，避免 docker.sock permission denied
if [[ -z "${DOCKER_GID:-}" ]] && [[ -S /var/run/docker.sock ]]; then
  if command -v stat >/dev/null 2>&1; then
    DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || stat -f '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
    export DOCKER_GID
  fi
fi
if [[ -n "${DOCKER_GID:-}" ]] && ! grep -q '^DOCKER_GID=' .env 2>/dev/null; then
  echo "DOCKER_GID=${DOCKER_GID}" >> .env
fi

ACTION="${1:-up}"
case "${ACTION}" in
  up)
    # 构建带 JDK21 + docker CLI 的 Jenkins 镜像，再拉起 GitLab
    docker compose up -d --build
    docker compose ps
    echo
    echo "Jenkins: http://localhost:\${JENKINS_HTTP_PORT:-8080} （见 .env）"
    echo "GitLab:  http://localhost:\${GITLAB_HTTP_PORT:-80} （external_url 见 GITLAB_HOSTNAME）"
    echo "密码:    bash compose.sh passwords"
    echo "流水线:  Script Path 可用 deploy/03-docker/Jenkinsfile.example"
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
