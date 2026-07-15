#!/usr/bin/env bash
# 方案四：安装 GitLab Helm Chart（资源需求高，建议先跑通 Jenkins）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${GITLAB_NAMESPACE:-gitlab}"
RELEASE="${GITLAB_RELEASE:-gitlab}"
VALUES="${SCRIPT_DIR}/values-gitlab.yaml"

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm upgrade --install "${RELEASE}" gitlab/gitlab \
  -n "${NS}" \
  -f "${VALUES}" \
  --timeout 30m

echo
echo "==== GitLab 安装命令已提交 ===="
echo "查看 Pod: kubectl -n ${NS} get pods"
echo "初始 root 密码通常来自 Secret（以 Chart 文档为准）:"
echo "  kubectl -n ${NS} get secret ${RELEASE}-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d; echo"
