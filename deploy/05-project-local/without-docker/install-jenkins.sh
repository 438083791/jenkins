#!/usr/bin/env bash
# 无 Docker：下载 jenkins.war 并放置目录与 CasC（JDK 21+）
# 也可被方案一 install-jenkins.sh 调用（唯一的宿主机 Jenkins 安装入口）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 可选：同目录 .env（方案五）或调用方已 export 的变量（方案一）
# 兼容 Windows CRLF
_ENV_FILE=""
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  _ENV_FILE="${SCRIPT_DIR}/.env"
elif [[ -f "${SCRIPT_DIR}/env.sh" ]]; then
  _ENV_FILE="${SCRIPT_DIR}/env.sh"
fi
if [[ -n "${_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  eval "$(sed 's/\r$//' "${_ENV_FILE}")"
  set +a
fi
unset _ENV_FILE

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
WAR_DIR="$(dirname "${JENKINS_HOME}")"
WAR_PATH="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"
JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
JAVA_HOME_JENKINS="${JAVA_HOME_JENKINS:-/usr/lib/jvm/java-21-openjdk-amd64}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-admin}"

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

# 按环境变量生成 systemd 单元（避免端口写死）
SERVICE_TMP="$(mktemp)"
sed \
  -e "s|^Environment=JENKINS_HOME=.*|Environment=JENKINS_HOME=${JENKINS_HOME}|" \
  -e "s|^Environment=CASC_JENKINS_CONFIG=.*|Environment=CASC_JENKINS_CONFIG=${JENKINS_HOME}/casc_configs|" \
  -e "s|^Environment=JENKINS_HTTP_PORT=.*|Environment=JENKINS_HTTP_PORT=${JENKINS_HTTP_PORT}|" \
  -e "s|^Environment=JENKINS_WAR=.*|Environment=JENKINS_WAR=${WAR_PATH}|" \
  -e "s|^Environment=JAVA_HOME_JENKINS=.*|Environment=JAVA_HOME_JENKINS=${JAVA_HOME_JENKINS}|" \
  -e "s|^Environment=JENKINS_ADMIN_PASSWORD=.*|Environment=JENKINS_ADMIN_PASSWORD=${JENKINS_ADMIN_PASSWORD}|" \
  "${SCRIPT_DIR}/jenkins.service" > "${SERVICE_TMP}"
install -m 0644 "${SERVICE_TMP}" /etc/systemd/system/jenkins-local.service
rm -f "${SERVICE_TMP}"

systemctl daemon-reload
systemctl enable jenkins-local
systemctl restart jenkins-local

echo
echo "==== Jenkins（无 Docker / war）已启动 ===="
echo "systemctl status jenkins-local"
echo "日志: journalctl -u jenkins-local -f"
echo "访问: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${JENKINS_HTTP_PORT}"
echo "初始密码（若未走 CasC 密码）: ${JENKINS_HOME}/secrets/initialAdminPassword"
echo "建议在 UI 安装插件后导入 Job；本目录 plugins-hint.txt 有插件列表"
