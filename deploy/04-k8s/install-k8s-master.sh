#!/usr/bin/env bash
# 方案四：kubeadm 安装 Master（控制面）—— 一主两从之「主」
# 用法：
#   sudo bash install-k8s-master.sh
#   sudo APISERVER_ADVERTISE_ADDRESS=192.168.1.10 bash install-k8s-master.sh
#   sudo bash install-k8s-master.sh --no-ingress
#
# 完成后会在本目录生成 worker-join.sh，拷到两台从节点执行即可。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/k8s-common.sh"

WITH_INGRESS=1
INSTALL_HELM="${INSTALL_HELM:-1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
JOIN_SCRIPT="${SCRIPT_DIR}/worker-join.sh"
FLANNEL_URL="${FLANNEL_URL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"
LOCAL_PATH_URL="${LOCAL_PATH_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml}"

for arg in "$@"; do
  case "${arg}" in
    --with-ingress) WITH_INGRESS=1 ;;
    --no-ingress) WITH_INGRESS=0 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: ${arg}" >&2
      exit 1
      ;;
  esac
done

k8s_require_root
k8s_detect_os

MASTER_IP="$(k8s_detect_primary_ip)"
if [[ -z "${MASTER_IP}" ]]; then
  echo "无法探测 Master IP，请设置: APISERVER_ADVERTISE_ADDRESS=x.x.x.x" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/admin.conf ]] && kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes >/dev/null 2>&1; then
  echo "检测到本机已有可用控制面，跳过 kubeadm init。"
  echo "如需重建请先: sudo bash ${SCRIPT_DIR}/uninstall-k8s.sh"
  k8s_setup_kubeconfig /etc/kubernetes/admin.conf
else
  k8s_prepare_node "master"

  echo
  echo "==== [master] 预拉取控制面镜像 ===="
  echo "imageRepository: ${IMAGE_REPOSITORY}"
  echo "若仍失败：检查本机能否访问镜像站，或改 IMAGE_REPOSITORY / 镜像加速变量"
  if ! kubeadm config images pull --image-repository="${IMAGE_REPOSITORY}"; then
    echo >&2
    echo "镜像拉取失败。当前环境多半无法直连 registry.k8s.io（*.pkg.dev）。" >&2
    echo "脚本默认已用: IMAGE_REPOSITORY=${IMAGE_REPOSITORY}" >&2
    echo "可重试：" >&2
    echo "  sudo bash uninstall-k8s.sh" >&2
    echo "  # 方案 A：继续阿里云（默认）" >&2
    echo "  sudo APISERVER_ADVERTISE_ADDRESS=${MASTER_IP} bash install-k8s.sh master" >&2
    echo "  # 方案 B：官方名 + DaoCloud 代理" >&2
    echo "  sudo IMAGE_REPOSITORY=registry.k8s.io APISERVER_ADVERTISE_ADDRESS=${MASTER_IP} bash install-k8s.sh master" >&2
    exit 1
  fi

  echo
  echo "==== [master] kubeadm init (advertise=${MASTER_IP}, podCIDR=${POD_CIDR}) ===="
  kubeadm init \
    --apiserver-advertise-address="${MASTER_IP}" \
    --pod-network-cidr="${POD_CIDR}" \
    --image-repository="${IMAGE_REPOSITORY}" \
    --upload-certs

  k8s_setup_kubeconfig /etc/kubernetes/admin.conf

  echo
  echo "==== [master] 安装 CNI（Flannel）===="
  kubectl apply -f "${FLANNEL_URL}"

  echo "等待控制面节点 Ready..."
  for i in $(seq 1 90); do
    if kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then
      break
    fi
    sleep 2
    if [[ "${i}" -eq 90 ]]; then
      echo "节点长时间未 Ready，请检查: kubectl get pods -n kube-flannel -o wide" >&2
      kubectl get nodes -o wide || true
      kubectl get pods -A || true
      exit 1
    fi
  done

  echo
  echo "==== [master] 安装 local-path StorageClass（Jenkins PVC）===="
  kubectl apply -f "${LOCAL_PATH_URL}"
  # 设为默认存储类
  kubectl annotate storageclass local-path \
    storageclass.kubernetes.io/is-default-class=true --overwrite || true
fi

export KUBECONFIG=/root/.kube/config

echo
echo "==== [master] 生成 Worker 加入脚本 ===="
JOIN_CMD="$(kubeadm token create --print-join-command)"
cat >"${JOIN_SCRIPT}" <<EOF
#!/usr/bin/env bash
# 由 install-k8s-master.sh 自动生成 —— 在两台 Worker 上执行：
#   sudo bash install-k8s-worker.sh
# 或直接：
#   sudo bash worker-join.sh
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "\${SCRIPT_DIR}/k8s-common.sh"
k8s_require_root
k8s_detect_os
k8s_prepare_node "worker"
${JOIN_CMD}
echo
echo "==== Worker 已加入，请到 Master 执行: kubectl get nodes -o wide ===="
EOF
chmod 700 "${JOIN_SCRIPT}"
echo "已写入: ${JOIN_SCRIPT}"
echo "Token 默认 24h 有效；过期后在 Master 执行:"
echo "  kubeadm token create --print-join-command"

if [[ "${INSTALL_HELM}" == "1" ]]; then
  echo
  echo "==== [master] 安装 Helm ===="
  if k8s_need_cmd helm; then
    echo "Helm 已存在: $(helm version --short 2>/dev/null || true)"
  else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  helm version --short
fi

if [[ "${WITH_INGRESS}" == "1" ]]; then
  echo
  echo "==== [master] 安装 ingress-nginx ===="
  if ! k8s_need_cmd helm; then
    echo "未找到 helm，无法安装 ingress-nginx。请设置 INSTALL_HELM=1 重试。" >&2
    exit 1
  fi
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --wait --timeout 10m
  echo "Ingress HTTP NodePort : 30080"
  echo "Ingress HTTPS NodePort: 30443"
fi

echo
echo "==== [master] 集群状态 ===="
kubectl get nodes -o wide
kubectl get sc
kubectl get pods -A

echo
echo "==== Master 安装完成（一主两从：请再装 2 台 Worker）===="
echo "Master IP : ${MASTER_IP}"
echo "kubeconfig: /root/.kube/config"
echo
echo "在两台从节点上（需能访问 ${MASTER_IP}:6443）："
echo "  1. 把本目录拷过去（至少含 k8s-common.sh + worker-join.sh + install-k8s-worker.sh）"
echo "  2. sudo bash install-k8s-worker.sh"
echo "     # 或: sudo bash worker-join.sh"
echo
echo "三台都 Ready 后："
echo "  bash ${SCRIPT_DIR}/check-cluster.sh"
echo "  bash ${SCRIPT_DIR}/install-jenkins.sh"
echo
echo "建议规格: Master ≥ 2C/4G；每 Worker ≥ 2C/4G；跑 Jenkins 建议合计 ≥ 4C/8G"
echo "防火墙放行: 6443/tcp 10250/tcp 8472/udp(Flannel) 30080,30443/tcp"
