#!/usr/bin/env bash
# 方案一：在 GitLab 服务器上安装 GitLab CE（Omnibus）
# 用法：
#   cp .env.example .env   # 可选，改 GITLAB_EXTERNAL_URL
#   sudo bash install-gitlab.sh [EXTERNAL_URL]
#
# 说明：GitLab 官方 apt 仅支持 Ubuntu LTS（20.04/22.04/24.04）。
# Ubuntu 25.x（如 questing）会自动改用 noble（24.04）仓库安装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

# 优先级：命令行参数 > .env > 脚本默认值
EXTERNAL_URL="${1:-${GITLAB_EXTERNAL_URL:-http://gitlab.example.com}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

# GitLab 官方支持的 Ubuntu 代号 → 不在列表则回退到最近 LTS
resolve_gitlab_apt_dist() {
  local codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  case "${codename}" in
    focal|jammy|noble) echo "${codename}" ;;
    *) echo "noble" ;;
  esac
}

NATIVE_CODENAME=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  NATIVE_CODENAME="${VERSION_CODENAME:-unknown}"
fi
GITLAB_APT_DIST="$(resolve_gitlab_apt_dist)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl openssh-server ca-certificates tzdata perl postfix

# 清理上次失败留下的残缺源配置
rm -f /etc/apt/sources.list.d/gitlab_gitlab-ce.list \
      /etc/apt/sources.list.d/gitlab_gitlab-ce.list.disabled \
      /etc/apt/sources.list.d/gitlab_gitlab-ce.sources 2>/dev/null || true

if [[ "${GITLAB_APT_DIST}" != "${NATIVE_CODENAME}" ]]; then
  echo "==== 注意 ===="
  echo "当前系统: Ubuntu ${NATIVE_CODENAME}（GitLab 官方尚未提供该代号仓库）"
  echo "将使用:   os=ubuntu dist=${GITLAB_APT_DIST} （通常为 24.04 noble）"
  echo "详见: https://docs.gitlab.com/install/package/ubuntu/"
  echo
fi

echo "配置 GitLab apt 源 (ubuntu/${GITLAB_APT_DIST})..."
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh \
  | os=ubuntu dist="${GITLAB_APT_DIST}" bash

apt-get update
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
