#!/usr/bin/env bash
# Jenkins 启动脚本（无 Docker）。现行 LTS 需要 Java 21+
set -euo pipefail

LOG_DIR="${LOG_DIR:-/opt/ci/logs}"
mkdir -p "${LOG_DIR}"
START_LOG="${LOG_DIR}/jenkins-start.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "${START_LOG}" >&2; }

export JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
export CASC_JENKINS_CONFIG="${CASC_JENKINS_CONFIG:-${JENKINS_HOME}/casc_configs}"
HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
WAR="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"

resolve_java() {
  local candidates=()
  if [[ -n "${JAVA_HOME_JENKINS:-}" ]]; then
    candidates+=("${JAVA_HOME_JENKINS}")
  fi
  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidates+=("${JAVA_HOME}")
  fi
  candidates+=(
    /usr/lib/jvm/java-21-openjdk-amd64
    /usr/lib/jvm/java-21-openjdk-arm64
    /usr/lib/jvm/temurin-21-jdk-amd64
    /usr/lib/jvm/java-25-openjdk-amd64
    /usr/lib/jvm/default-java
  )
  local home
  for home in "${candidates[@]}"; do
    if [[ -x "${home}/bin/java" ]]; then
      echo "${home}/bin/java"
      return 0
    fi
  done
  if command -v java >/dev/null 2>&1; then
    command -v java
    return 0
  fi
  return 1
}

JAVA_BIN="$(resolve_java || true)"
if [[ -z "${JAVA_BIN}" ]]; then
  log "ERROR: 找不到 java。请安装 openjdk-21-jdk"
  log "ls /usr/lib/jvm: $(ls /usr/lib/jvm 2>&1 || true)"
  exit 1
fi

# 简单校验主版本 >= 21
JAVA_VER="$("${JAVA_BIN}" -version 2>&1 | awk -F'"' '/version/ {print $2}')"
MAJOR="${JAVA_VER%%.*}"
if [[ "${MAJOR}" == "1" ]]; then
  MAJOR="$(echo "${JAVA_VER}" | cut -d. -f2)"
fi
if [[ "${MAJOR}" -lt 21 ]]; then
  log "ERROR: Jenkins 现行 LTS 需要 Java 21+，当前为 ${JAVA_VER} (${JAVA_BIN})"
  log "请执行: sudo apt-get install -y openjdk-21-jdk && sudo bash set-default-jdk21.sh"
  exit 1
fi

if [[ ! -f "${WAR}" ]]; then
  log "ERROR: 找不到 war: ${WAR}"
  exit 1
fi

WAR_SIZE="$(stat -c%s "${WAR}" 2>/dev/null || echo 0)"
if [[ "${WAR_SIZE}" -lt 50000000 ]]; then
  log "ERROR: war 过小 (${WAR_SIZE} bytes): ${WAR}"
  exit 1
fi

mkdir -p "${JENKINS_HOME}"
log "JAVA_BIN=${JAVA_BIN} (version ${JAVA_VER})"
log "JENKINS_HOME=${JENKINS_HOME}"
log "WAR=${WAR} (${WAR_SIZE} bytes)"

cd "${JENKINS_HOME}"

JAVA_OPTS_EXTRA=()
if [[ "${SKIP_SETUP_WIZARD:-false}" == "true" ]]; then
  JAVA_OPTS_EXTRA+=("-Djenkins.install.runSetupWizard=false")
fi
if [[ -d "${CASC_JENKINS_CONFIG}" ]]; then
  JAVA_OPTS_EXTRA+=("-Dcasc.jenkins.config=${CASC_JENKINS_CONFIG}")
fi

exec "${JAVA_BIN}" \
  -Xms256m -Xmx1024m \
  "${JAVA_OPTS_EXTRA[@]}" \
  -jar "${WAR}" \
  --httpPort="${HTTP_PORT}" \
  --httpListenAddress=0.0.0.0
