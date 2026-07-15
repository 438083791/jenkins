#!/usr/bin/env bash
# 方案一：在 Jenkins 服务器上安装 Jenkins LTS（官方 deb）
# 用法：sudo bash install-jenkins.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-17-jdk fontconfig curl gnupg

if [[ ! -f /usr/share/keyrings/jenkins-keyring.asc ]]; then
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    -o /usr/share/keyrings/jenkins-keyring.asc
fi

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

apt-get update
apt-get install -y jenkins

# 可选：从环境变量覆盖端口
if [[ -n "${JENKINS_HTTP_PORT:-}" ]]; then
  if grep -q '^HTTP_PORT=' /etc/default/jenkins; then
    sed -i "s/^HTTP_PORT=.*/HTTP_PORT=${JENKINS_HTTP_PORT}/" /etc/default/jenkins
  else
    echo "HTTP_PORT=${JENKINS_HTTP_PORT}" >> /etc/default/jenkins
  fi
fi

systemctl enable jenkins
systemctl restart jenkins
systemctl --no-pager status jenkins || true

echo
echo "==== Jenkins 安装完成 ===="
echo "访问: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${JENKINS_HTTP_PORT:-8080}"
echo "初始管理员密码:"
if [[ -f /var/lib/jenkins/secrets/initialAdminPassword ]]; then
  cat /var/lib/jenkins/secrets/initialAdminPassword
else
  echo "等待服务就绪后执行: sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
fi
