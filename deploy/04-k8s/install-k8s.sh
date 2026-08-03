#!/usr/bin/env bash
# 方案四：Kubernetes 一主两从安装入口（kubeadm）
#
# 拓扑：
#   Master x1  —— sudo bash install-k8s.sh master
#   Worker x2  —— sudo bash install-k8s.sh worker   （每台从节点各执行一次）
#
# 也可直接调用：
#   sudo bash install-k8s-master.sh
#   sudo bash install-k8s-worker.sh
#
# 环境变量（可选）：
#   APISERVER_ADVERTISE_ADDRESS  Master 宣告 IP
#   K8S_MAJOR_MINOR             默认 1.31
#   K8S_PKG_VERSION             钉死 deb 版本，如 1.31.4-1.1
#   POD_CIDR                    默认 10.244.0.0/16（Flannel）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE="${1:-}"

usage() {
  cat <<EOF
用法:
  sudo bash install-k8s.sh master [--no-ingress]
  sudo bash install-k8s.sh worker [--join-file=./worker-join.sh]

一主两从推荐步骤:
  1) 三台 Ubuntu/Debian，主机名互不相同，网络互通
  2) Master:  sudo bash install-k8s.sh master
  3) 把 deploy/04-k8s/（含生成的 worker-join.sh）同步到两台 Worker
  4) Worker:  sudo bash install-k8s.sh worker   # 两台各执行一次
  5) Master:  kubectl get nodes -o wide         # 应看到 3 个 Ready
  6) Master:  bash check-cluster.sh && bash install-jenkins.sh

说明见: ${SCRIPT_DIR}/README.md
EOF
}

case "${ROLE}" in
  master|control-plane)
    shift || true
    exec bash "${SCRIPT_DIR}/install-k8s-master.sh" "$@"
    ;;
  worker|node|agent)
    shift || true
    exec bash "${SCRIPT_DIR}/install-k8s-worker.sh" "$@"
    ;;
  -h|--help|"")
    usage
    [[ -n "${ROLE}" ]] || exit 1
    exit 0
    ;;
  *)
    echo "未知角色: ${ROLE}" >&2
    usage
    exit 1
    ;;
esac
