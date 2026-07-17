#!/usr/bin/env bash
# 方案一 · Jenkins：复用方案五 without-docker 安装脚本
# （JDK 21 + jenkins.war + systemd jenkins-local）
#
# 用法：
#   cp .env.example .env   # 可选
#   sudo bash install-jenkins.sh
#
# 不再使用官方 deb 包（Ubuntu 25 / 现行 LTS 需要 Java 21；
# 与本仓库 web-test 示例统一走方案五脚本，避免两套安装逻辑）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

WITHOUT_DOCKER="$(cd "${SCRIPT_DIR}/../05-project-local/without-docker" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

export JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
export JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
export JENKINS_WAR="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"
export TZ="${TZ:-Asia/Shanghai}"
export JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-admin}"

echo "==== [1/2] 安装 JDK 21（Jenkins）/ JDK 8 + Maven（可选构建）===="
bash "${WITHOUT_DOCKER}/install-prereqs.sh"

echo
echo "==== [2/2] 安装并启动 Jenkins（war + systemd）===="
bash "${WITHOUT_DOCKER}/install-jenkins.sh"

echo
echo "==== 方案一 Jenkins 安装完成（复用方案五脚本）===="
echo "访问: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${JENKINS_HTTP_PORT}"
echo "服务: systemctl status jenkins-local"
echo "布局: /opt/ci/jenkins/ （非 apt deb 的 /var/lib/jenkins）"
