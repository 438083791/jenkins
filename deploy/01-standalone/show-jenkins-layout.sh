#!/usr/bin/env bash
# 方案一：打印 JENKINS_HOME 关键路径，便于学习目录结构
set -euo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"

echo "JENKINS_HOME=${JENKINS_HOME}"
echo
for p in \
  config.xml \
  credentials.xml \
  secrets \
  users \
  plugins \
  jobs \
  workspace \
  nodes \
  logs
do
  target="${JENKINS_HOME}/${p}"
  if [[ -e "${target}" ]]; then
    ls -ld "${target}"
  else
    echo "(missing) ${target}"
  fi
done

echo
echo "最近 Job 构建（若存在）:"
find "${JENKINS_HOME}/jobs" -maxdepth 3 -type d -name builds 2>/dev/null | head -n 20 || true
