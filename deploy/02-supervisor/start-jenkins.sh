#!/usr/bin/env bash
set -euo pipefail

export JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
WAR="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"

if [[ ! -x "${JAVA_HOME}/bin/java" ]]; then
  # 常见发行版路径回退
  if command -v java >/dev/null 2>&1; then
    JAVA_BIN="$(command -v java)"
  else
    echo "找不到 Java，请设置 JAVA_HOME" >&2
    exit 1
  fi
else
  JAVA_BIN="${JAVA_HOME}/bin/java"
fi

mkdir -p "${JENKINS_HOME}"
cd "${JENKINS_HOME}"

exec "${JAVA_BIN}" \
  -Xms512m -Xmx1024m \
  -Dhudson.lifecycle=hudson.lifecycle.ExitLifecycle \
  -jar "${WAR}" \
  --httpPort="${HTTP_PORT}" \
  --httpListenAddress=0.0.0.0
