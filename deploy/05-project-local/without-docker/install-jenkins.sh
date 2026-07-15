#!/usr/bin/env bash
# 无 Docker：下载 jenkins.war 并放置目录与 CasC
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
WAR_DIR="$(dirname "${JENKINS_HOME}")"
WAR_PATH="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"

id -u jenkins >/dev/null 2>&1 || useradd -r -m -d "${JENKINS_HOME}" -s /bin/bash jenkins
mkdir -p "${JENKINS_HOME}/casc_configs" "${WAR_DIR}" /opt/ci/logs
chown -R jenkins:jenkins /opt/ci

install -m 0755 "${SCRIPT_DIR}/start-jenkins.sh" /opt/ci/jenkins/start-jenkins.sh
install -m 0644 "${SCRIPT_DIR}/casc/jenkins.yaml" "${JENKINS_HOME}/casc_configs/jenkins.yaml"
chown -R jenkins:jenkins "${JENKINS_HOME}" /opt/ci/jenkins/start-jenkins.sh

# 若存在上次失败的半截文件，先清掉
if [[ -f "${WAR_PATH}" ]]; then
  size="$(stat -c%s "${WAR_PATH}" 2>/dev/null || echo 0)"
  if [[ "${size}" -lt 50000000 ]]; then
    echo "发现不完整的 jenkins.war (${size} bytes)，删除后重新下载"
    rm -f "${WAR_PATH}"
  fi
fi

# 校验已有 war 是否为 ZIP（防 corrupt jar）
if [[ -f "${WAR_PATH}" ]]; then
  magic="$(head -c 4 "${WAR_PATH}" | od -An -tx1 | tr -d ' \n')"
  if [[ "${magic}" != "504b0304" ]]; then
    echo "jenkins.war 文件头非法 (magic=${magic})，删除后重新下载"
    rm -f "${WAR_PATH}"
  fi
fi

if [[ ! -f "${WAR_PATH}" ]]; then
  echo "下载 jenkins.war (LTS)..."
  bash "${SCRIPT_DIR}/download-jenkins-war.sh" "${WAR_PATH}"
  chown jenkins:jenkins "${WAR_PATH}"
fi

# systemd 单元（无 Docker / 无 Supervisor 的简易方式）
install -m 0644 "${SCRIPT_DIR}/jenkins.service" /etc/systemd/system/jenkins-local.service
systemctl daemon-reload
systemctl enable jenkins-local
systemctl restart jenkins-local

echo
echo "==== Jenkins（无 Docker）已启动 ===="
echo "systemctl status jenkins-local"
echo "日志: journalctl -u jenkins-local -f"
echo "初始密码（若未走 CasC 密码）: ${JENKINS_HOME}/secrets/initialAdminPassword"
echo "建议在 UI 安装插件后导入 Job，Pipeline 使用仓库根目录 Jenkinsfile"
echo "或使用本目录 plugins-hint.txt 手动安装插件列表"
