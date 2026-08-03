#!/usr/bin/env bash
# 方案四：kubeadm 公共准备（由 master/worker 脚本 source）
# 勿直接执行。

: "${K8S_MAJOR_MINOR:=1.31}"
: "${K8S_PKG_VERSION:=}"   # 空 = 仓库最新 1.31.x；可钉如 1.31.4-1.1

# 控制面镜像仓库（国内默认阿里云；可直连官方时设 IMAGE_REPOSITORY=registry.k8s.io）
: "${IMAGE_REPOSITORY:=registry.aliyuncs.com/google_containers}"
# pause / sandbox；默认跟 IMAGE_REPOSITORY 走
: "${PAUSE_IMAGE:=${IMAGE_REPOSITORY}/pause:3.10}"

# containerd 镜像加速（DaoCloud）；registry.k8s.io 代理常 403，默认只加速 docker/ghcr/quay
: "${CONTAINERD_MIRROR:=1}"
: "${MIRROR_K8S_ENABLE:=0}"   # 设为 1 才加速 registry.k8s.io（DaoCloud 若 403 请保持 0）
: "${MIRROR_K8S:=https://m.daocloud.io/registry.k8s.io}"
: "${MIRROR_DOCKER:=https://docker.m.daocloud.io}"
: "${MIRROR_GHCR:=https://ghcr.m.daocloud.io}"
: "${MIRROR_QUAY:=https://quay.m.daocloud.io}"

# Helm 二进制（避免 raw.githubusercontent.com）
: "${HELM_VERSION:=v3.16.4}"
: "${HELM_TGZ_URLS:=https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz https://mirrors.huaweicloud.com/helm/${HELM_VERSION}/helm-${HELM_VERSION}-linux-amd64.tar.gz}"

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

# 仅写 certs.d（不往 config.toml 追加已废弃的 v1.cri.registry 段，避免 containerd 2.x 起不来）
k8s_write_registry_hosts() {
  if [[ "${CONTAINERD_MIRROR}" != "1" ]]; then
    echo "已跳过 containerd 镜像加速（CONTAINERD_MIRROR=${CONTAINERD_MIRROR}）"
    return 0
  fi

  local certs_d="/etc/containerd/certs.d"
  echo "==== 配置 containerd 镜像加速（DaoCloud / certs.d）===="
  mkdir -p \
    "${certs_d}/docker.io" \
    "${certs_d}/ghcr.io" \
    "${certs_d}/quay.io"

  # registry.k8s.io：DaoCloud 对部分 tag（如 pause:3.10.1）会 403，默认不配代理
  if [[ "${MIRROR_K8S_ENABLE}" == "1" ]]; then
    mkdir -p "${certs_d}/registry.k8s.io"
    cat >"${certs_d}/registry.k8s.io/hosts.toml" <<EOF
server = "https://registry.k8s.io"

[host."${MIRROR_K8S}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
    echo "registry.k8s.io -> ${MIRROR_K8S}"
  else
    rm -rf "${certs_d}/registry.k8s.io"
    echo "registry.k8s.io 不走代理（MIRROR_K8S_ENABLE=0）；sandbox 请用阿里云 pause）"
  fi

  cat >"${certs_d}/docker.io/hosts.toml" <<EOF
server = "https://docker.io"

[host."${MIRROR_DOCKER}"]
  capabilities = ["pull", "resolve"]
EOF

  cat >"${certs_d}/ghcr.io/hosts.toml" <<EOF
server = "https://ghcr.io"

[host."${MIRROR_GHCR}"]
  capabilities = ["pull", "resolve"]
EOF

  cat >"${certs_d}/quay.io/hosts.toml" <<EOF
server = "https://quay.io"

[host."${MIRROR_QUAY}"]
  capabilities = ["pull", "resolve"]
EOF

  echo "docker.io       -> ${MIRROR_DOCKER}"
  echo "ghcr.io         -> ${MIRROR_GHCR}"
}

# 把阿里云（或 IMAGE_REPOSITORY）上的 pause 打成 containerd/kubelet 默认会要的官方名
k8s_ensure_pause_aliases() {
  local src="${PAUSE_IMAGE}"
  echo "==== 确保 pause 可用: ${src} ===="
  if command -v crictl >/dev/null 2>&1; then
    crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock pull "${src}" 2>/dev/null || true
  fi
  if ! command -v ctr >/dev/null 2>&1; then
    echo "无 ctr，跳过 pause 别名打标"
    return 0
  fi
  # containerd 2.x 默认常要 pause:3.10.1；kubeadm 文档常见 3.10
  local tag
  for tag in \
    registry.k8s.io/pause:3.10 \
    registry.k8s.io/pause:3.10.1 \
    registry.k8s.io/pause:3.9
  do
    ctr -n k8s.io images tag "${src}" "${tag}" 2>/dev/null || true
  done
  echo "已尝试将 ${src} 标记为 registry.k8s.io/pause:3.10 / 3.10.1"
}

# 生成兼容 containerd 1.x / 2.x 的 config.toml（Ubuntu 24.04 为 2.x）
k8s_write_containerd_config() {
  local cfg="/etc/containerd/config.toml"
  mkdir -p /etc/containerd
  if [[ -f "${cfg}" ]]; then
    cp -f "${cfg}" "${cfg}.bak.$(date +%s)" || true
  fi

  # 先出默认配置，再做最小替换（不要 insert/append 旧版 plugin 段）
  containerd config default >"${cfg}"

  # kubeadm / kubelet 使用 systemd cgroup
  if grep -q 'SystemdCgroup = false' "${cfg}"; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${cfg}"
  fi

  # 强制所有 sandbox_image 行指向国内 pause（双引号 / 单引号都改）
  if grep -qE 'sandbox_image\s*=' "${cfg}"; then
    sed -i -E "s|sandbox_image\s*=\s*\"[^\"]*\"|sandbox_image = \"${PAUSE_IMAGE}\"|g" "${cfg}"
    sed -i -E "s|sandbox_image\s*=\s*'[^']*'|sandbox_image = \"${PAUSE_IMAGE}\"|g" "${cfg}"
  else
    echo "提示: 默认配置无 sandbox_image 字段，将依赖 pause 别名（${PAUSE_IMAGE}）"
  fi

  # 把 config_path 指到 certs.d
  if grep -qE '^\s*config_path\s*=' "${cfg}"; then
    sed -i -E 's|^(\s*config_path\s*=\s*).*$|\1"/etc/containerd/certs.d"|' "${cfg}"
  fi

  echo "当前 sandbox_image 配置："
  grep -E 'sandbox_image' "${cfg}" || true

  k8s_write_registry_hosts
}

k8s_restart_containerd() {
  systemctl enable containerd >/dev/null 2>&1 || true
  if ! systemctl restart containerd; then
    echo "containerd 启动失败，最近日志：" >&2
    journalctl -u containerd -n 40 --no-pager >&2 || true
    echo >&2
    echo "可尝试恢复默认配置后排查：" >&2
    echo "  containerd config default | sudo tee /etc/containerd/config.toml" >&2
    echo "  sudo systemctl restart containerd" >&2
    echo "  journalctl -u containerd -e" >&2
    exit 1
  fi
  systemctl is-active --quiet containerd
  echo "containerd 已运行；sandbox_image 目标 -> ${PAUSE_IMAGE}"
}

# 系统内核参数、关 swap、装基础包、containerd、kubeadm/kubelet/kubectl
k8s_prepare_node() {
  local role="$1"
  echo "==== [${role}] 系统准备 ===="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates apt-transport-https gnupg lsb-release \
    socat conntrack ipset nfs-common cri-tools

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

  echo "==== [${role}] 安装 / 配置 containerd ===="
  # Ubuntu 24.04 自带 containerd 2.x；保持发行版包，避免与 Docker 源混用
  apt-get install -y containerd
  k8s_write_containerd_config
  k8s_restart_containerd

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

  # Worker 加入前也需要 pause；Master 会在 images pull 后再打一次别名
  if [[ "${role}" == "worker" ]]; then
    crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock pull "${PAUSE_IMAGE}" 2>/dev/null || true
    k8s_ensure_pause_aliases
  fi
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

# 不依赖 GitHub raw 脚本安装 Helm
k8s_install_helm() {
  if k8s_need_cmd helm; then
    echo "Helm 已存在: $(helm version --short 2>/dev/null || true)"
    return 0
  fi

  local url tgz="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  local ok=0
  for url in ${HELM_TGZ_URLS}; do
    echo "下载 Helm: ${url}"
    if curl -fL --connect-timeout 15 --max-time 180 "${url}" -o "${tgz}"; then
      ok=1
      break
    fi
    echo "下载失败，尝试下一个源..."
  done
  if [[ "${ok}" != "1" ]]; then
    echo "Helm 下载失败（多源均不可用）。可稍后手动安装，或设 INSTALL_HELM=0 跳过。" >&2
    return 1
  fi

  tar -xzf "${tgz}" -C /tmp
  install -m 755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/linux-amd64 "${tgz}"
  helm version --short
}
