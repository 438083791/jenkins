# 方案四：Kubernetes 集群（一主两从）+ Jenkins / GitLab

> 详细说明见 [`docs/04-jenkins-gitlab-docker-k8s.md`](../../docs/04-jenkins-gitlab-docker-k8s.md)。

本目录提供 **kubeadm 一主两从** 安装脚本（1 个 Master + 2 个 Worker），装完再部署 Jenkins / GitLab。

## 拓扑

```text
                    ┌─────────────────────┐
                    │  Master（控制面）    │
                    │  kube-apiserver 等   │
                    │  + kubectl / Helm    │
                    └──────────┬──────────┘
               6443/tcp        │
         ┌─────────────────────┼─────────────────────┐
         ▼                     ▼                     ▼
  ┌─────────────┐       ┌─────────────┐       ┌─────────────┐
  │  Worker-1   │       │  Worker-2   │       │ （业务 Pod   │
  │  kubelet    │       │  kubelet    │       │  调度到从节点）│
  └─────────────┘       └─────────────┘       └─────────────┘
```

| 角色 | 数量 | 建议规格 | 脚本 |
|---|---|---|---|
| Master | 1 | ≥ 2C / 4G / 40G | `install-k8s.sh master` |
| Worker | 2 | 各 ≥ 2C / 4G / 40G | `install-k8s.sh worker` |

跑 Jenkins 动态 Agent 时，三台合计建议 **≥ 4C / 8G**；再上 GitLab Chart 建议更高。

## 标准流程

```text
Master: install-k8s.sh master
  → 生成 worker-join.sh，同步到两台 Worker
Worker×2: install-k8s.sh worker
  → Master: kubectl get nodes（3 个 Ready）
  → check-cluster.sh → install-jenkins.sh
```

## 安装集群（一主两从）

**环境**：三台 Ubuntu / Debian；主机名互不相同；互相能 ping；Master 对 Worker 开放 API。

**防火墙放行（至少）**：`6443/tcp`、`10250/tcp`、`8472/udp`（Flannel VXLAN）、`30080/tcp`、`30443/tcp`。

### 1. Master

```bash
cd deploy/04-k8s
# 多网卡时请显式指定宣告 IP
sudo APISERVER_ADVERTISE_ADDRESS=192.168.1.10 bash install-k8s.sh master
```

Master 会完成：关 swap → containerd → kubeadm init → Flannel → local-path 存储类 → Helm → ingress-nginx，并生成 **`worker-join.sh`**（含 join token，勿提交 Git）。

### 2. 同步脚本到两台 Worker

把整个 `deploy/04-k8s/`（必须含 `k8s-common.sh`、`worker-join.sh`、`install-k8s-worker.sh`）拷到两台从节点，例如：

```bash
scp -r deploy/04-k8s user@worker1:~/
scp -r deploy/04-k8s user@worker2:~/
```

### 3. 两台 Worker 各执行一次

```bash
cd ~/04-k8s   # 或你的实际路径
sudo bash install-k8s.sh worker
```

### 4. 回到 Master 验收

```bash
kubectl get nodes -o wide
# 应看到 1 个 control-plane + 2 个 Ready 的 worker

bash check-cluster.sh
bash install-jenkins.sh
```

### 常用变量

```bash
# 钉 Kubernetes 小版本线 / deb 包版本
sudo K8S_MAJOR_MINOR=1.31 K8S_PKG_VERSION=1.31.4-1.1 bash install-k8s.sh master

# 不装 ingress-nginx
sudo bash install-k8s.sh master --no-ingress

# 镜像仓库（国内默认已是阿里云 google_containers）
# sudo IMAGE_REPOSITORY=registry.aliyuncs.com/google_containers bash install-k8s.sh master
# 可直连或走 DaoCloud 代理时：
# sudo IMAGE_REPOSITORY=registry.k8s.io bash install-k8s.sh master
# 关闭 containerd 加速：CONTAINERD_MIRROR=0

# Token 过期后，在 Master 重新生成并覆盖 worker-join.sh：
kubeadm token create --print-join-command
# 或再跑一遍 master 脚本中的生成逻辑（集群已存在时会跳过 init 并刷新 join 脚本）
```

### 安装时常见日志 / 报错

| 日志 | 含义 |
|---|---|
| `remote version is much newer ... stable-1.31` | 正常：脚本钉在 1.31 线 |
| `Pulling images required...` | 正在拉控制面镜像 |
| `sandbox image "" ... inconsistent` | pause 未配置；新脚本已写入 |
| `dial tcp ...pkg.dev:443: connection refused` | **国内无法直连 registry.k8s.io**；请用下方「带镜像源重装」 |
| `Job for containerd.service failed` | 多为写坏了 `config.toml`（Ubuntu 24.04 是 containerd 2.x）。同步最新脚本后重装；或先 `containerd config default \| sudo tee /etc/containerd/config.toml && sudo systemctl restart containerd` |

**带国内镜像源重装（你当前的报错就走这个）：**

```bash
# 1. 把本仓库最新 deploy/04-k8s 同步到 Master
# 2. 清理失败残留后重装（默认已用阿里云镜像仓库 + DaoCloud 加速）
sudo bash uninstall-k8s.sh
sudo APISERVER_ADVERTISE_ADDRESS=192.168.122.136 bash install-k8s.sh master
```

若阿里云缺某个 tag，可改走官方名 + DaoCloud：

```bash
sudo bash uninstall-k8s.sh
sudo IMAGE_REPOSITORY=registry.k8s.io \
  APISERVER_ADVERTISE_ADDRESS=192.168.122.136 \
  bash install-k8s.sh master
```

### `wait-control-plane` / `context deadline exceeded`

含义：kubeadm 已写证书和静态 Pod，但在超时时间内 **API Server 一直没起来**（常见是 kubelet / 控制面容器挂了）。

在 Master 上立刻跑：

```bash
sudo bash diagnose-k8s-init.sh
```

或手工：

```bash
systemctl status kubelet --no-pager
journalctl -xeu kubelet -n 80 --no-pager
crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a | grep kube
crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock images
```

常见原因与处理：

| 现象 | 处理 |
|---|---|
| `pause:3.10.1` + `m.daocloud.io ... 403 Forbidden` | **当前根因**：sandbox 去拉官方 pause，DaoCloud 403。见下方「pause 403 急救」 |
| 控制面容器 `Exited` / 一直 `Pending` | 多半镜像或 pause 有问题；`uninstall` 后重装 |
| kubelet `inactive` / 报错连不上 containerd | `systemctl restart containerd kubelet` |
| 虚拟机磁盘/CPU 很慢 | 加资源后重装 |
| 仍有 swap | `swapoff -a` 并检查 `/etc/fstab` |

**pause 403 急救（你已有阿里云 pause:3.10 时可先试，不必重装系统）：**

```bash
# 1) 去掉会 403 的 registry.k8s.io 代理
sudo rm -rf /etc/containerd/certs.d/registry.k8s.io

# 2) 把已有阿里云 pause 打成 kubelet 要的名字
sudo ctr -n k8s.io images tag \
  registry.aliyuncs.com/google_containers/pause:3.10 \
  registry.k8s.io/pause:3.10.1
sudo ctr -n k8s.io images tag \
  registry.aliyuncs.com/google_containers/pause:3.10 \
  registry.k8s.io/pause:3.10

# 3) sandbox 指到阿里云（若配置里有该字段）
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.10"|g' \
  /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl restart kubelet

# 4) 等 1～2 分钟看控制面是否起来
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a | grep kube
sudo ss -lntp | grep 6443 || true
```

若仍起不来，再完整重装（同步最新脚本后）：

```bash
sudo bash uninstall-k8s.sh
sudo APISERVER_ADVERTISE_ADDRESS=192.168.122.165 bash install-k8s.sh master
```
| `pause:3.10.1` + DaoCloud `403 Forbidden` | **根因**：沙箱仍拉官方 pause，代理 403。控制面镜像其实已在阿里云。执行 `sudo bash fix-pause-sandbox.sh` |

### 卸载

在**要拆除的那台机器**上：

```bash
sudo bash uninstall-k8s.sh
# Worker 卸完后到 Master: kubectl delete node <hostname>
```

只卸 Jenkins/GitLab、保留集群：

```bash
bash uninstall.sh jenkins    # 或 gitlab / all
```

> 已有云托管集群时可跳过本节，直接从 `check-cluster.sh` 开始。

## 安装 Jenkins / GitLab

```bash
bash check-cluster.sh
bash install-jenkins.sh
# 资源充足再装 GitLab Chart（很重）
bash install-gitlab.sh
```

取 Jenkins 初始密码：

```bash
kubectl -n jenkins get secret jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

暂未配域名时：

```bash
kubectl -n jenkins port-forward svc/jenkins 8080:8080
# http://127.0.0.1:8080
```

Ingress：把 `values-jenkins.yaml` 中的 `ci.example.com` 写入 `/etc/hosts`，访问 `http://<任意节点IP>:30080`。

## 文件

| 文件 | 作用 |
|---|---|
| `install-k8s.sh` | 入口：`master` / `worker` |
| `install-k8s-master.sh` | 安装控制面 + CNI + 存储类 + Helm + Ingress |
| `install-k8s-worker.sh` | 工作节点加入集群 |
| `k8s-common.sh` | 公共准备（containerd / kubeadm 包） |
| `worker-join.sh` | **Master 生成**，含 join 命令（勿入库） |
| `uninstall-k8s.sh` | 本机 `kubeadm reset` |
| `check-cluster.sh` | 节点 / StorageClass / Ingress 检查 |
| `install-jenkins.sh` / `install-gitlab.sh` | Helm 装应用 |
| `values-*.yaml` / `namespaces.yaml` | Chart values / Namespace |
| `uninstall.sh` | 卸载 Jenkins / GitLab Release |
| `Jenkinsfile.k8s-agent.example` | 动态 Agent 示例 |

## 验收建议

1. `kubectl get nodes` 共 **3** 个节点且均为 Ready  
2. `kubectl get sc` 能看到默认 `local-path`  
3. `install-jenkins.sh` 成功，`port-forward` 能打开 UI  
4. 跑通 `Jenkinsfile.k8s-agent.example`（Agent Pod 在 Worker 上创建后销毁）  
