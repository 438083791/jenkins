#!/usr/bin/env bash
# 方案一：开放 GitLab / Jenkins 常用端口（ufw）
# 用法：
#   sudo bash configure-firewall.sh gitlab
#   sudo bash configure-firewall.sh jenkins
set -euo pipefail

ROLE="${1:-}"
if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  apt-get update && apt-get install -y ufw
fi

ufw allow OpenSSH

case "${ROLE}" in
  gitlab)
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 22/tcp
    ;;
  jenkins)
    ufw allow "${JENKINS_HTTP_PORT:-8080}/tcp"
    ufw allow 50000/tcp
    ;;
  *)
    echo "用法: $0 {gitlab|jenkins}" >&2
    exit 1
    ;;
esac

ufw --force enable
ufw status verbose
