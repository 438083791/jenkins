#!/usr/bin/env bash
# 由安装脚本 source：自动加载同目录 .env（若存在）
# 用法：source "${SCRIPT_DIR}/load-env.sh"
#
# 兼容 Windows 编辑产生的 CRLF（.env / env.sh）
_LOAD_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOAD_ENV_FILE=""
if [[ -f "${_LOAD_ENV_DIR}/.env" ]]; then
  _LOAD_ENV_FILE="${_LOAD_ENV_DIR}/.env"
elif [[ -f "${_LOAD_ENV_DIR}/env.sh" ]]; then
  _LOAD_ENV_FILE="${_LOAD_ENV_DIR}/env.sh"
fi

if [[ -n "${_LOAD_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  # 去掉 \r，避免 CRLF 导致 "$'\r': 未找到命令"
  # shellcheck disable=SC2046
  eval "$(sed 's/\r$//' "${_LOAD_ENV_FILE}")"
  set +a
fi
unset _LOAD_ENV_DIR _LOAD_ENV_FILE
