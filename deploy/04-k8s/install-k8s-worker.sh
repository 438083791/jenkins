#!/usr/bin/env bash
# 方案四：kubeadm 安装 Worker（工作节点）—— 一主两从之「从」
# 用法（在两台从节点上各执行一次）：
#   sudo bash install-k8s-worker.sh
#   sudo bash install-k8s-worker.sh --join-file=/path/to/worker-join.sh
#
# 前提：Master 已跑完 install-k8s-master.sh，并生成同目录 worker-join.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/k8s-common.sh"

JOIN_FILE="${SCRIPT_DIR}/worker-join.sh"
JOIN_CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --join-file)
      JOIN_FILE="${2:?}"
      shift 2
      ;;
    --join-file=*)
      JOIN_FILE="${1#*=}"
      shift
      ;;
    --join-cmd)
      JOIN_CMD="${2:?}"
      shift 2
      ;;
    --join-cmd=*)
      JOIN_CMD="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

k8s_require_root
k8s_detect_os

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "检测到本机似乎已加入集群（存在 /etc/kubernetes/kubelet.conf）。"
  echo "如需重加请先: sudo bash ${SCRIPT_DIR}/uninstall-k8s.sh"
  exit 0
fi

if [[ -z "${JOIN_CMD}" ]]; then
  if [[ ! -f "${JOIN_FILE}" ]]; then
    echo "未找到加入脚本: ${JOIN_FILE}" >&2
    echo "请从 Master 拷贝 worker-join.sh 到本目录，或传入:" >&2
    echo "  --join-cmd 'kubeadm join ...'" >&2
    exit 1
  fi
  # worker-join.sh 已含完整准备 + join；若用户直接拿生成文件也可
  # 这里解析其中的 kubeadm join 行，避免重复 source 准备两次时仍可用 install-k8s-worker
  JOIN_CMD="$(grep -E '^[[:space:]]*kubeadm join ' "${JOIN_FILE}" | tail -1 | sed 's/^[[:space:]]*//')"
  if [[ -z "${JOIN_CMD}" ]]; then
    echo "无法从 ${JOIN_FILE} 解析 kubeadm join 命令" >&2
    exit 1
  fi
fi

k8s_prepare_node "worker"

echo
echo "==== [worker] 加入集群 ===="
echo "执行: ${JOIN_CMD}"
# shellcheck disable=SC2086
eval "${JOIN_CMD}"

echo
echo "==== Worker 安装完成 ===="
echo "请到 Master 执行: kubectl get nodes -o wide"
echo "预期一主两从共 3 个节点均为 Ready"
echo "卸载本节点: sudo bash ${SCRIPT_DIR}/uninstall-k8s.sh"
