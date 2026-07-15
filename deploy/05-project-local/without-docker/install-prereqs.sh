#!/usr/bin/env bash
# 安装：Git、JDK8（编 web-test）、JDK21（跑 Jenkins）、Maven
# 安装完成后将系统默认 JDK 设为 21
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  git curl unzip openssh-client \
  openjdk-8-jdk \
  openjdk-21-jdk \
  maven
# 现行 Jenkins LTS 要求 Java 21+；系统默认设为 21
bash "${SCRIPT_DIR}/set-default-jdk21.sh"

echo
echo "==== 工具版本（默认应为 21）===="
java -version || true
javac -version || true
mvn -version || true

echo
echo "常见 JDK 路径："
echo "  Java 8 : /usr/lib/jvm/java-8-openjdk-amd64   （构建 web-test）"
echo "  Java 21: /usr/lib/jvm/java-21-openjdk-amd64  （Jenkins Controller，系统默认）"
update-java-alternatives -l 2>/dev/null || true
