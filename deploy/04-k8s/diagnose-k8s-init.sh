#!/usr/bin/env bash
# 诊断 kubeadm init / wait-control-plane 失败（在 Master 上执行）
# 用法: sudo bash diagnose-k8s-init.sh
set -euo pipefail

echo "==== 1. 服务状态 ===="
systemctl is-active containerd || true
systemctl is-active kubelet || true
systemctl status kubelet --no-pager -l | head -40 || true

echo
echo "==== 2. swap / cgroup ===="
swapon --show || true
echo "cgroup: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"

echo
echo "==== 3. containerd / SystemdCgroup / sandbox ===="
grep -E 'SystemdCgroup|sandbox_image|config_path' /etc/containerd/config.toml 2>/dev/null | head -20 || true

echo
echo "==== 4. 本机已有 k8s 相关镜像 ===="
if command -v crictl >/dev/null 2>&1; then
  crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock images || true
else
  ctr -n k8s.io images ls 2>/dev/null | head -40 || true
fi

echo
echo "==== 5. kube / pause 容器 ===="
if command -v crictl >/dev/null 2>&1; then
  crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a | grep -E 'kube|etcd|pause|coredns' || true
  echo
  echo "---- 最近失败容器日志（若有）----"
  while read -r cid; do
    [[ -z "${cid}" ]] && continue
    echo "### ${cid}"
    crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock logs --tail 30 "${cid}" 2>/dev/null || true
  done < <(crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a --state Exited -q 2>/dev/null | head -5)
else
  echo "未安装 crictl，跳过。可: apt-get install -y cri-tools"
fi

echo
echo "==== 6. kubelet 最近日志 ===="
journalctl -u kubelet -n 60 --no-pager || true

echo
echo "==== 7. 静态 Pod 清单 ===="
ls -la /etc/kubernetes/manifests 2>/dev/null || echo "尚无 manifests（init 可能未写完）"

echo
echo "把以上输出发回来；常见处理见 README「wait-control-plane / context deadline」一节。"
