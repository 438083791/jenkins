#!/usr/bin/env bash
# 方案四：kubeadm 公共准备（由 master/worker 脚本 source）
# 勿直接执行。

: "${K8S_MAJOR_MINOR:=1.31}"
: "${K8S_PKG_VERSION:=}"   # 空 = 仓库最新 1.31.x；可钉如 1.31.4-1.1

k8s_require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请使用 root 或 sudo 运行" >&2
    exit 1
  fi
}

k8s_detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo "无法识别操作系统（需要 /etc/os-release）" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      echo "警告: 未专门验证发行版 '${ID:-unknown}'，将继续尝试..."
      ;;
  esac
}

k8s_need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# 系统内核参数、关 swap、装基础包、containerd、kubeadm/kubelet/kubectl
k8s_prepare_node() {
  local role="$1"
  echo "==== [${role}] 系统准备 ===="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates apt-transport-https gnupg lsb-release \
    socat conntrack ipset nfs-common

  if swapon --show | grep -q .; then
    echo "关闭 swap..."
    swapoff -a
    if [[ -f /etc/fstab ]]; then
      sed -i.bak -E 's|^([^#].*\sswap\s.*)$|# \1  # disabled by install-k8s|' /etc/fstab || true
    fi
  fi

  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system >/dev/null

  echo "==== [${role}] 安装 containerd ===="
  apt-get install -y containerd
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  # kubeadm 要求使用 systemd cgroup 驱动
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  systemctl restart containerd

  echo "==== [${role}] 安装 kubeadm / kubelet / kubectl (v${K8S_MAJOR_MINOR}) ===="
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update

  local pkgs=(kubelet kubeadm kubectl)
  if [[ -n "${K8S_PKG_VERSION}" ]]; then
    pkgs=(
      "kubelet=${K8S_PKG_VERSION}"
      "kubeadm=${K8S_PKG_VERSION}"
      "kubectl=${K8S_PKG_VERSION}"
    )
  fi
  apt-get install -y "${pkgs[@]}"
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet
}

k8s_setup_kubeconfig() {
  local src="${1:-/etc/kubernetes/admin.conf}"
  install -d -m 755 /root/.kube
  cp -f "${src}" /root/.kube/config
  chmod 600 /root/.kube/config

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    if [[ -n "${sudo_home}" && -d "${sudo_home}" ]]; then
      install -d -m 755 -o "${SUDO_USER}" -g "${SUDO_USER}" "${sudo_home}/.kube"
      cp -f "${src}" "${sudo_home}/.kube/config"
      chown "${SUDO_USER}:${SUDO_USER}" "${sudo_home}/.kube/config"
      chmod 600 "${sudo_home}/.kube/config"
    fi
  fi
  export KUBECONFIG=/root/.kube/config
}

k8s_detect_primary_ip() {
  if [[ -n "${APISERVER_ADVERTISE_ADDRESS:-}" ]]; then
    echo "${APISERVER_ADVERTISE_ADDRESS}"
    return
  fi
  # 优先默认路由出口 IP
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${ip}"
}
