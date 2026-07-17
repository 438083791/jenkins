#!/usr/bin/env bash
set -euo pipefail

export JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
WAR="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"

if [[ ! -x "${JAVA_HOME}/bin/java" ]]; then
  # 常见发行版路径回退（优先 21）
  for cand in \
    /usr/lib/jvm/java-21-openjdk-amd64 \
    /usr/lib/jvm/java-21-openjdk-arm64 \
    /usr/lib/jvm/temurin-21-jdk-amd64 \
    /usr/lib/jvm/default-java
  do
    if [[ -x "${cand}/bin/java" ]]; then
      JAVA_HOME="${cand}"
      break
    fi
  done
fi

if [[ -x "${JAVA_HOME}/bin/java" ]]; then
  JAVA_BIN="${JAVA_HOME}/bin/java"
elif command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(command -v java)"
else
  echo "找不到 Java 21+，请安装 openjdk-21-jdk 并设置 JAVA_HOME" >&2
  exit 1
fi

# 校验主版本 >= 21
JAVA_VER="$("${JAVA_BIN}" -version 2>&1 | awk -F'"' '/version/ {print $2}')"
MAJOR="${JAVA_VER%%.*}"
if [[ "${MAJOR}" == "1" ]]; then
  MAJOR="$(echo "${JAVA_VER}" | cut -d. -f2)"
fi
if [[ "${MAJOR}" -lt 21 ]]; then
  echo "Jenkins 现行 LTS 需要 Java 21+，当前为 ${JAVA_VER}" >&2
  exit 1
fi

mkdir -p "${JENKINS_HOME}"
cd "${JENKINS_HOME}"

exec "${JAVA_BIN}" \
  -Xms512m -Xmx1024m \
  -Dhudson.lifecycle=hudson.lifecycle.ExitLifecycle \
  -jar "${WAR}" \
  --httpPort="${HTTP_PORT}" \
  --httpListenAddress=0.0.0.0
