#!/usr/bin/env bash
# 在无 Jenkins 时，本机直接验证 web-test 构建（无 Docker）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP="${ROOT}/web-test"

export JAVA_HOME="${JAVA_HOME_BUILD:-${JAVA_HOME:-}}"
if [[ -z "${JAVA_HOME}" ]] && [[ -d /usr/lib/jvm/java-8-openjdk-amd64 ]]; then
  export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

cd "${APP}"
if command -v mvn >/dev/null 2>&1; then
  mvn -B clean package
elif [[ -x ./mvnw ]]; then
  ./mvnw -B clean package
elif [[ -f ./mvnw.cmd ]]; then
  echo "请在 Windows 下执行: .\\mvnw.cmd -B clean package" >&2
  exit 1
else
  echo "未找到 mvn / mvnw" >&2
  exit 1
fi

echo "产物: $(ls -1 target/web-test-*.jar 2>/dev/null | grep -v original || true)"
