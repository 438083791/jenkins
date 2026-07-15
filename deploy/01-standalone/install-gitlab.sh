#!/usr/bin/env bash
# 方案一：在 GitLab 服务器上安装 GitLab CE（Omnibus）
# 用法：sudo bash install-gitlab.sh [EXTERNAL_URL]
set -euo pipefail

EXTERNAL_URL="${1:-${GITLAB_EXTERNAL_URL:-http://gitlab.example.com}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl openssh-server ca-certificates tzdata perl postfix

if [[ ! -f /etc/apt/sources.list.d/gitlab_gitlab-ce.list ]] && [[ ! -f /etc/apt/sources.list.d/gitlab_gitlab-ce.list.disabled ]]; then
  curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
fi

EXTERNAL_URL="${EXTERNAL_URL}" apt-get install -y gitlab-ce

gitlab-ctl reconfigure
gitlab-ctl status

echo
echo "==== GitLab 安装完成 ===="
echo "访问: ${EXTERNAL_URL}"
echo "Root 初始密码文件: /etc/gitlab/initial_root_password"
if [[ -f /etc/gitlab/initial_root_password ]]; then
  echo "（首次安装后 24 小时内有效）"
  grep '^Password:' /etc/gitlab/initial_root_password || true
fi
