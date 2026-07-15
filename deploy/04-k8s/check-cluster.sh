#!/usr/bin/env bash
# 方案四：集群前置检查
set -euo pipefail

echo "== kubectl =="
kubectl version --client || true
kubectl get nodes -o wide

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
