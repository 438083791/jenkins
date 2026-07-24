# 方案四：Jenkins + GitLab + Docker + Kubernetes 部署

> **目标**：在 Kubernetes 上以容器方式运行 GitLab 与 Jenkins，实现弹性 Agent、声明式配置、标准 Ingress/存储/密钥管理，摸清云原生 CI 的落地形态与复杂度边界。

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 多团队共享 CI；需要弹性构建节点；已有 K8s 平台 |
| 部署形态 | 集群内 Helm/清单安装；GitLab 与 Jenkins 分 Namespace |
| 关键能力 | Jenkins Kubernetes 插件动态起 Agent Pod |
| 相对方案三 | 从「单机 Compose」升级到「编排 + 调度 + 弹性」 |
| **配置目录** | [`deploy/04-k8s/`](../deploy/04-k8s/) |

本方案假设已具备：可用的 K8s 集群（1.28+）、默认 StorageClass、可配 Ingress Controller（如 ingress-nginx）、能申请 TLS（cert-manager 可选）。

---

## 2. 架构图

```text
                         Kubernetes Cluster
 ┌─────────────────────────────────────────────────────────────────┐
 │  NS: gitlab                                                      │
 │   ┌─────────────────────────────────────┐                        │
 │   │  GitLab Chart / Omnibus on K8s      │                        │
 │   │  webservice / gitaly / postgres ... │                        │
 │   └───────────────┬─────────────────────┘                        │
 │                   │ Ingress: https://gitlab.example.com          │
 │                   │                                              │
 │  NS: jenkins                                                     │
 │   ┌──────────────────────┐     动态调度 Agent Pod                │
 │   │ Jenkins Controller   │ ───────────────────────────────┐      │
 │   │ (Deployment + PVC)   │                                │      │
 │   └──────────┬───────────┘                                ▼      │
 │              │ Ingress                         ┌────────────────┐│
 │              │ https://ci.example.com          │ Agent Pods     ││
 │              │                                 │ (按标签/模板)  ││
 │              │                                 └────────────────┘│
 │              ▼                                                   │
 │         PVC: jenkins-home     Secrets: gitlab-token / tls        │
 └─────────────────────────────────────────────────────────────────┘
        ▲ Push / MR                         │ Webhook
        │                                   ▼
   开发者 Git 客户端                 Controller 触发 Pipeline
```

**推荐原则**：GitLab 与 Jenkins **分 Namespace**；生产环境 GitLab 有状态组件多，资源与备份策略独立规划。

---

## 3. 组件与安装方式建议

| 组件 | 推荐安装 | 说明 |
|---|---|---|
| Jenkins | 官方 Helm Chart `jenkinsci/jenkins` | 易集成 CasC、RBAC、Agent 模板 |
| GitLab | 官方 Helm Chart `gitlab/gitlab` | **重资源**；实验可用精简 values，生产按官方 sizing |
| Ingress | ingress-nginx | 统一 HTTPS 入口 |
| cert-manager | 可选 | 自动证书 |
| 镜像仓库 | Harbor / GitLab Registry | Pipeline 推送产物镜像 |

> 实验资源不够时：GitLab 可仍用方案三 Compose 跑在集群外，仅 Jenkins 进 K8s——也是常见过渡架构。

---

## 4. 集群前置检查

```bash
kubectl version --short
kubectl get nodes
kubectl get sc
kubectl get ns
kubectl -n ingress-nginx get pods   # 视实际 Ingress 命名空间而定
```

最低实验规格（单节点学习集群）：

| 角色 | CPU | 内存 | 备注 |
|---|---|---|---|
| 仅 Jenkins + 动态 Agent | 4C | 8G | 可接受 |
| Jenkins + 完整 GitLab Chart | 8C+ | 16G+ | 笔记本勉强，建议远端集群 |

---

## 5. Jenkins on Kubernetes（核心）

### 5.1 Namespace 与 Helm 安装示意

```bash
kubectl create namespace jenkins
helm repo add jenkinsci https://charts.jenkins.io
helm repo update

# values-jenkins.yaml 见下节
helm upgrade --install jenkins jenkinsci/jenkins \
  -n jenkins \
  -f values-jenkins.yaml
```

### 5.2 `values-jenkins.yaml` 关键片段

```yaml
controller:
  image:
    tag: "2.462.3-lts-jdk17"
  numExecutors: 0          # 构建全部交给 Agent Pod，Controller 不本地跑重任务
  jenkinsUrl: "https://ci.example.com"
  installPlugins:
    - kubernetes:2465.v4b_3d0e8eab_6d  # 版本号以安装时稳定版为准
    - gitlab-plugin:1.9.x
    - git:5.x.x
    - configuration-as-code:1.x
  JCasC:
    configScripts:
      welcome-message: |
        jenkins:
          systemMessage: "Jenkins on Kubernetes"
      gitlab-cred: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - string:
                      scope: GLOBAL
                      id: gitlab-token
                      secret: ${GITLAB_TOKEN}
                      description: "GitLab API token"
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "2Gi"
  persistence:
    enabled: true
    size: 20Gi

agent:
  enabled: true
  # Chart 会生成默认 podTemplate；也可在 CasC / UI 自定义

ingress:
  enabled: true
  hostName: ci.example.com
  tls:
    - secretName: jenkins-tls
      hosts:
        - ci.example.com
```

安装后取初始密码：

```bash
kubectl -n jenkins get secret jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 -d
```

### 5.3 动态 Agent：理解一次构建

1. Pipeline 声明 `agent { kubernetes { ... } }` 或使用默认 cloud  
2. Controller 调用 K8s API 创建 Pod（含 jnlp 容器 + 构建容器）  
3. Agent 连回 Controller（WebSocket 或 JNLP，视配置）  
4. 执行 stages，结束后 Pod 被销毁  

**这是本方案相对 Compose 的最大差异**：构建环境用完即弃，宿主机不被工具链污染。

示例 Pipeline：

```groovy
pipeline {
  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: maven
    image: maven:3.9-eclipse-temurin-17
    command: ['cat']
    tty: true
"""
    }
  }
  stages {
    stage('Build') {
      steps {
        container('maven') {
          sh 'mvn -v'
        }
      }
    }
  }
}
```

### 5.4 RBAC 要点

Jenkins Controller ServiceAccount 需要在目标 Namespace（常为同 NS 或专用 `jenkins-agents`）创建/删除 Pod、读 Secret 等权限。Helm Chart 默认会创建 Role/RoleBinding；若跨 NS 起 Agent，需额外 RoleBinding。

---

## 6. GitLab on Kubernetes

### 6.1 官方 Chart 概念

GitLab Helm Chart 会拆出多个组件：Webservice、Sidekiq、Gitaly、PostgreSQL、Redis、MinIO/对象存储、Registry 等。实验环境务必在 values 中 **降规格**，否则调度失败。

```bash
helm repo add gitlab https://charts.gitlab.io/
kubectl create namespace gitlab

helm upgrade --install gitlab gitlab/gitlab \
  -n gitlab \
  -f values-gitlab.yaml
```

### 6.2 实验向 values 片段（示意，需按版本文档校对）

```yaml
global:
  hosts:
    domain: example.com
    gitlab:
      name: gitlab.example.com
  ingress:
    configureCertmanager: true
    class: nginx

certmanager-issuer:
  email: admin@example.com

# 显著缩小资源（仅实验！）
gitlab:
  webservice:
    minReplicas: 1
    maxReplicas: 1
  sidekiq:
    minReplicas: 1
  gitlab-shell:
    minReplicas: 1
```

### 6.3 过渡架构（推荐学习路径）

若集群吃不下完整 GitLab：

```text
[ GitLab Compose / 独立 VM ]  ---Webhook--->  [ Jenkins in K8s ]
```

先把 **Jenkins 动态 Agent** 跑通，再迁 GitLab，复杂度和失败面更小。

---

## 7. 集成：Webhook 与凭证

| 项 | K8s 下的做法 |
|---|---|
| Jenkins 对外 URL | Ingress `https://ci.example.com` |
| GitLab Webhook | 填 Ingress 地址，或集群内 `http://jenkins.jenkins.svc.cluster.local:8080/...` |
| 凭证 | K8s Secret → 经 CasC / Credentials Provider 注入，避免明文进 Git |
| SSH Clone | 网络策略需放行 GitLab Shell；或统一 HTTPS + Token |

集群内服务发现示例：

```text
http://jenkins.jenkins.svc.cluster.local:8080
http://gitlab-webservice-default.gitlab.svc.cluster.local:8181
```

（具体 Service 名以 `kubectl get svc -n <ns>` 为准。）

---

## 8. 存储、备份与升级

### 8.1 存储

- Jenkins：`PVC` 挂载 `jenkins-home`（必须持久化）  
- GitLab：Gitaly / PostgreSQL / 对象存储均为有状态，**生产务必外置对象存储与可靠磁盘**  
- 动态 Agent：默认 emptyDir，构建产物需显式 `archiveArtifacts`、推镜像或上传制品库  

### 8.2 备份

| 对象 | 方法 |
|---|---|
| Jenkins | 备份 PVC；或 PeriodicBackup / 同步 Job 配置到 Git（Job DSL / CasC） |
| GitLab | Chart 提供的 backup-utility；或官方备份文档流程 |
| 密钥 | 独立备份 Secret / 密封密钥方案（如 Sealed Secrets、ESO） |

### 8.3 升级顺序建议

1. 读发行说明（Jenkins LTS / GitLab Chart）  
2. 备份 PVC / GitLab  
3. 先升 Jenkins Chart（小版本），验证 Pipeline  
4. 再升 GitLab（变更面更大）  

---

## 9. 网络策略与安全基线

- [ ] Controller 管理面仅内网 / SSO；限制公网 Ingress  
- [ ] Agent Pod 使用非特权容器；避免默认挂载高权限 SA  
- [ ] 用 NetworkPolicy 限制 Agent 出站（可访问 GitLab、制品库即可）  
- [ ] Pipeline 镜像来自可信仓库；尽量钉 digest  
- [ ] 禁用 Controller 上的本地 Executor（`numExecutors: 0`）  
- [ ] 审计：谁能 create namespace / 绑 cluster-admin  

构建镜像推荐：

- **Kaniko / BuildKit rootless / Podman** 等在 Pod 内构建，避免 DinD + privileged  

---

## 10. 与前三方案对比

| 维度 | 方案一 裸机 | 方案二 Supervisor 管应用 | 方案三 Compose | 本方案 K8s |
|---|---|---|---|---|
| 学习重点 | Jenkins 文件与进程 | 构建分发 + 应用守护 | 镜像/卷/网络 | 调度、弹性、RBAC |
| Agent 弹性 | 手工加节点 | 手工节点 | 固定容器 | Pod 按需创建 |
| 复杂度 | 低 | 低-中 | 中 | 高 |
| HA / 多租户 | 弱 | 弱 | 弱 | 可设计较强 |
| 资源门槛 | 低 | 低 | 中 | 高 |

---

## 11. 分阶段落地路径

| 阶段 | 内容 | 退出标准 |
|---|---|---|
| K0 | 集群 + Ingress 就绪 | 域名能反代任意演示服务 |
| K1 | 仅 Helm 装 Jenkins | UI 可访问，PVC 正常 |
| K2 | 一条 Kubernetes Agent Pipeline | Pod 创建并成功销毁 |
| K3 | 对接外部或集群内 GitLab Webhook | Push 自动构建 |
| K4 | CasC + 插件锁定 + 备份演练 | Git 可重建 Controller 配置 |
| K5 | （可选）GitLab Chart / Registry / 网络策略 | 符合团队安全基线 |

---

## 12. 优缺点与边界

**优点**

- 构建环境弹性、隔离、可版本化（Pod 模板即环境）  
- 契合云原生运维与平台工程  
- 便于多团队共用同一套 Controller（配合 Folder/权限）  

**缺点**

- GitLab 全量进群成本高  
- 调试链路长（DNS、Ingress、RBAC、PVC、镜像拉取）  
- 需要平台能力，不适合作为「第一个了解 Jenkins 目录结构」的入门路径（入门请用方案一）  

---

## 13. 验收清单

- [ ] Jenkins Helm 安装成功，Ingress HTTPS 可访问  
- [ ] `numExecutors=0`，样例 Pipeline 在动态 Agent Pod 中跑通  
- [ ] GitLab（集群内或外部）Webhook 触发成功  
- [ ] Controller PVC 删除 Pod 后数据仍在  
- [ ] 明确 Agent 用的 ServiceAccount 与权限范围  
- [ ] 完成一次 Chart / 镜像小版本升级演练  
- [ ] （可选）NetworkPolicy 与制品镜像推送打通  

---

## 14. 相关文档

- [方案一：独立服务器部署](./01-jenkins-gitlab-standalone.md)  
- [方案二：Jenkins 打包上传 + Supervisor 管应用](./02-jenkins-gitlab-supervisor.md)  
- [方案三：Docker Compose 部署](./03-jenkins-gitlab-docker.md)  
- [方案五：当前项目内 Jenkins 配置](./05-jenkins-project-local.md)  
