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
FLANNEL_MANIFEST="${SCRIPT_DIR}/manifests/kube-flannel.yml"
LOCAL_PATH_MANIFEST="${SCRIPT_DIR}/manifests/local-path-storage.yaml"
# 兼容旧环境变量：若仍指定 URL 则优先 URL（不推荐，国内常连不上 GitHub）
FLANNEL_URL="${FLANNEL_URL:-}"
LOCAL_PATH_URL="${LOCAL_PATH_URL:-}"

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
  echo "已拉取镜像："
  crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock images 2>/dev/null \
    | grep -E 'kube-|etcd|pause|coredns|IMAGE' || true

  # containerd 默认要 registry.k8s.io/pause:3.10.1；用已拉取的阿里云 pause 打别名，避免 DaoCloud 403
  k8s_ensure_pause_aliases

  echo
  echo "==== [master] 写入 kubeadm 配置并 init ===="
  KUBEADM_CFG="$(mktemp /tmp/kubeadm-init.XXXXXX.yaml)"
  # v1beta3 兼容 1.31
  cat >"${KUBEADM_CFG}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable-${K8S_MAJOR_MINOR}
imageRepository: ${IMAGE_REPOSITORY}
networking:
  podSubnet: ${POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

  set +e
  kubeadm init --config="${KUBEADM_CFG}" --upload-certs --v=5
  INIT_RC=$?
  set -e
  rm -f "${KUBEADM_CFG}"

  if [[ "${INIT_RC}" -ne 0 ]]; then
    echo >&2
    echo "==== kubeadm init 失败，自动诊断 ====" >&2
    bash "${SCRIPT_DIR}/diagnose-k8s-init.sh" || true
    echo >&2
    echo "处理建议：" >&2
    echo "  1) 看上面 crictl/kubelet 是否在拉镜像失败或 CrashLoop" >&2
    echo "  2) sudo bash uninstall-k8s.sh 后重试" >&2
    echo "  3) 若镜像站不稳定: sudo IMAGE_REPOSITORY=registry.k8s.io APISERVER_ADVERTISE_ADDRESS=${MASTER_IP} bash install-k8s.sh master" >&2
    exit "${INIT_RC}"
  fi

  k8s_setup_kubeconfig /etc/kubernetes/admin.conf
fi

export KUBECONFIG=/root/.kube/config

echo
echo "==== [master] 安装 CNI（Flannel，本地清单，不依赖 GitHub）===="
if [[ -n "${FLANNEL_URL}" ]]; then
  kubectl apply -f "${FLANNEL_URL}"
elif [[ -f "${FLANNEL_MANIFEST}" ]]; then
  kubectl apply -f "${FLANNEL_MANIFEST}"
else
  echo "未找到 Flannel 清单: ${FLANNEL_MANIFEST}" >&2
  exit 1
fi

echo "等待节点 Ready..."
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
if [[ -n "${LOCAL_PATH_URL}" ]]; then
  kubectl apply -f "${LOCAL_PATH_URL}"
elif [[ -f "${LOCAL_PATH_MANIFEST}" ]]; then
  kubectl apply -f "${LOCAL_PATH_MANIFEST}"
else
  echo "未找到 local-path 清单: ${LOCAL_PATH_MANIFEST}" >&2
  exit 1
fi
kubectl annotate storageclass local-path \
  storageclass.kubernetes.io/is-default-class=true --overwrite || true

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
  echo "==== [master] 安装 Helm（get.helm.sh / 华为云，不走 GitHub raw）===="
  k8s_install_helm || echo "Helm 未装上，将跳过依赖 Helm 的步骤；可用本地清单装 Ingress"
fi

if [[ "${WITH_INGRESS}" == "1" ]]; then
  echo
  echo "==== [master] 安装 ingress-nginx ===="
  INGRESS_MANIFEST="${SCRIPT_DIR}/manifests/ingress-nginx-nodeport.yaml"
  INGRESS_OK=0
  if k8s_need_cmd helm; then
    if helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null \
      && helm repo update 2>/dev/null \
      && helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30080 \
        --set controller.service.nodePorts.https=30443 \
        --set controller.image.registry=m.daocloud.io/registry.k8s.io \
        --wait --timeout 10m; then
      INGRESS_OK=1
    else
      echo "Helm 安装 ingress-nginx 失败，回退到本地清单..."
    fi
  fi
  if [[ "${INGRESS_OK}" != "1" ]]; then
    if [[ -f "${INGRESS_MANIFEST}" ]]; then
      kubectl apply -f "${INGRESS_MANIFEST}"
      INGRESS_OK=1
    else
      echo "未找到 Ingress 清单且 Helm 不可用，跳过 Ingress" >&2
    fi
  fi
  if [[ "${INGRESS_OK}" == "1" ]]; then
    echo "Ingress HTTP NodePort : 30080"
    echo "Ingress HTTPS NodePort: 30443"
  fi
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
