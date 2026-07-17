#!/usr/bin/env bash
# 方案二：安装 JDK、Supervisor，并准备 /opt/ci 目录
# 用法：sudo bash install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
# 现行 Jenkins LTS 需要 Java 21+（Ubuntu 25 亦适用）
apt-get install -y openjdk-21-jdk git curl supervisor

id -u jenkins >/dev/null 2>&1 || useradd -r -m -d /opt/ci/jenkins/home -s /bin/bash jenkins

mkdir -p /opt/ci/jenkins /opt/ci/logs /opt/ci/jenkins/home
chown -R jenkins:jenkins /opt/ci

install -m 0755 "${SCRIPT_DIR}/start-jenkins.sh" /opt/ci/jenkins/start-jenkins.sh
chown jenkins:jenkins /opt/ci/jenkins/start-jenkins.sh

if [[ ! -f /opt/ci/jenkins/jenkins.war ]]; then
  echo "下载 jenkins.war (LTS)..."
  sudo -u jenkins curl -fL -o /opt/ci/jenkins/jenkins.war \
    https://get.jenkins.io/war-stable/latest/jenkins.war
fi

install -m 0644 "${SCRIPT_DIR}/jenkins.conf" /etc/supervisor/conf.d/jenkins.conf

# 可选 Agent 模板（默认不启用，需自行改 secret 后去掉 .disabled）
if [[ -f "${SCRIPT_DIR}/jenkins-agent.conf.example" ]]; then
  install -m 0644 "${SCRIPT_DIR}/jenkins-agent.conf.example" \
    /etc/supervisor/conf.d/jenkins-agent.conf.example
fi

supervisorctl reread
supervisorctl update
supervisorctl status jenkins || true

echo
echo "==== Supervisor + Jenkins 就绪 ===="
echo "启停: supervisorctl {start|stop|restart} jenkins"
echo "日志: supervisorctl tail -f jenkins"
echo "初始密码: cat /opt/ci/jenkins/home/secrets/initialAdminPassword"
