#!/usr/bin/env bash
# Supervisor 拉起业务应用（web-test.jar）
# 由 supervisord 以 APP_USER 身份执行；Jenkins 只负责覆盖 jar 后 restart。
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/web-test}"
JAR="${APP_JAR:-${APP_DIR}/web-test.jar}"
APP_PORT="${APP_PORT:-8088}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}"

if [[ ! -x "${JAVA_HOME}/bin/java" ]]; then
  for cand in \
    /usr/lib/jvm/java-8-openjdk-amd64 \
    /usr/lib/jvm/java-8-openjdk-arm64 \
    /usr/lib/jvm/temurin-8-jdk-amd64 \
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
  echo "找不到 Java，请安装 openjdk-8-jdk 并设置 JAVA_HOME" >&2
  exit 1
fi

if [[ ! -f "${JAR}" ]]; then
  echo "应用 jar 不存在: ${JAR}（等待 Jenkins 首次上传）" >&2
  exit 1
fi

cd "${APP_DIR}"
exec "${JAVA_BIN}" -jar "${JAR}" --server.port="${APP_PORT}"
