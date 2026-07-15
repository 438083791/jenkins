#!/usr/bin/env bash
# 稳健下载 jenkins.war（绕过 HTTP/2 中断、支持重试与镜像）
# 用法：
#   bash download-jenkins-war.sh [目标路径]
# 默认目标：/opt/ci/jenkins/jenkins.war
set -euo pipefail

DEST="${1:-/opt/ci/jenkins/jenkins.war}"
DEST_DIR="$(dirname "${DEST}")"
TMP="${DEST}.partial"

mkdir -p "${DEST_DIR}"

# 官方 + 镜像（按顺序尝试）
URLS=(
  "https://get.jenkins.io/war-stable/latest/jenkins.war"
  "https://mirrors.tuna.tsinghua.edu.cn/jenkins/war-stable/latest/jenkins.war"
  "https://mirrors.aliyun.com/jenkins/war-stable/latest/jenkins.war"
  "https://ftp.osuosl.org/pub/mirrors/jenkins/war-stable/latest/jenkins.war"
)

download_one() {
  local url="$1"
  echo "尝试: ${url}"
  # --http1.1 避免部分网络下 HTTP/2 PROTOCOL_ERROR
  # -C - 断点续传；失败则删 partial 重来一次完整下载
  if curl --http1.1 -fL --retry 5 --retry-delay 3 --retry-all-errors \
      -C - -o "${TMP}" "${url}"; then
    return 0
  fi
  rm -f "${TMP}"
  curl --http1.1 -fL --retry 5 --retry-delay 3 --retry-all-errors \
    -o "${TMP}" "${url}"
}

if [[ -f "${DEST}" ]] && [[ -s "${DEST}" ]]; then
  echo "已存在: ${DEST} ($(du -h "${DEST}" | awk '{print $1}'))"
  exit 0
fi

# 上次失败残留
rm -f "${DEST}" "${TMP}"

ok=0
for url in "${URLS[@]}"; do
  if download_one "${url}"; then
    ok=1
    break
  fi
  echo "失败，换下一个源..." >&2
  rm -f "${TMP}"
done

if [[ "${ok}" -ne 1 ]]; then
  echo "所有镜像均下载失败" >&2
  exit 1
fi

# war 一般为几十 MB；过小视为失败
size="$(stat -c%s "${TMP}" 2>/dev/null || stat -f%z "${TMP}")"
if [[ "${size}" -lt 50000000 ]]; then
  echo "文件过小 (${size} bytes)，不像完整 war（通常 ~90MB+）" >&2
  rm -f "${TMP}"
  exit 1
fi

# jar/war 实质是 ZIP，开头应为 PK\x03\x04
magic="$(head -c 4 "${TMP}" | od -An -tx1 | tr -d ' \n')"
if [[ "${magic}" != "504b0304" ]]; then
  echo "文件头不是合法 ZIP/JAR (magic=${magic})，可能是 HTML 错误页或半截下载" >&2
  head -c 200 "${TMP}" >&2 || true
  echo >&2
  rm -f "${TMP}"
  exit 1
fi

# 可选：unzip 完整性检查
if command -v unzip >/dev/null 2>&1; then
  if ! unzip -tqq "${TMP}" >/dev/null; then
    echo "unzip 校验失败，war 已损坏" >&2
    rm -f "${TMP}"
    exit 1
  fi
fi

mv -f "${TMP}" "${DEST}"
chmod 644 "${DEST}"
echo "下载完成: ${DEST} ($(du -h "${DEST}" | awk '{print $1}'))"
