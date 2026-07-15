#!/usr/bin/env bash
# 方案四：安装 Jenkins Helm Chart
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${JENKINS_NAMESPACE:-jenkins}"
RELEASE="${JENKINS_RELEASE:-jenkins}"
VALUES="${SCRIPT_DIR}/values-jenkins.yaml"

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

helm repo add jenkinsci https://charts.jenkins.io
helm repo update

helm upgrade --install "${RELEASE}" jenkinsci/jenkins \
  -n "${NS}" \
  -f "${VALUES}" \
  --wait --timeout 15m

echo
echo "==== Jenkins 已安装 ===="
echo "获取管理员密码:"
echo "  kubectl -n ${NS} get secret ${RELEASE} -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo"
echo "端口转发（若暂未配 Ingress）:"
echo "  kubectl -n ${NS} port-forward svc/${RELEASE} 8080:8080"
