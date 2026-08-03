#!/usr/bin/env bash
# 方案四：集群前置检查（一主两从预期 3 个 Ready 节点）
set -euo pipefail

echo "== kubectl =="
kubectl version --client || true
kubectl get nodes -o wide

NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || true)"
echo "节点数: ${NODE_COUNT}（含 Ready 字样行: ${READY_COUNT}）；一主两从预期合计 3"
if [[ "${NODE_COUNT:-0}" -lt 3 ]]; then
  echo "提示: 节点不足 3，请确认两台 Worker 已执行 install-k8s.sh worker"
fi

echo
echo "== StorageClass =="
kubectl get sc

echo
echo "== Ingress controller (best-effort) =="
kubectl get ns | grep -Ei 'ingress|nginx' || true
kubectl get pods -A | grep -Ei 'ingress|nginx' || true

echo
echo "== 现有 jenkins/gitlab NS =="
kubectl get ns jenkins gitlab 2>/dev/null || true
