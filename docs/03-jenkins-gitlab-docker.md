# 方案三：Jenkins + GitLab + Docker 部署

> **目标**：用 Docker / Docker Compose 将 GitLab 与 Jenkins（及可选 Runner、Agent、反向代理）容器化交付，实现一键拉起、环境一致、依赖隔离，并建立可持续的数据卷与升级策略。

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 开发/测试环境；希望快速复现 CI；小团队自托管 |
| 部署形态 | 单机 Compose 或「GitLab 机 + Jenkins 机」双 Compose |
| 编排工具 | Docker Engine + Docker Compose v2 |
| 相对前两案 | 抽象掉宿主机包管理差异；用镜像与卷固化运行时 |
| **配置目录** | [`deploy/03-docker/`](../deploy/03-docker/) |

学习重点从「操作系统目录」转向 **镜像分层、数据卷、网络、容器内 UID、升级与回滚**。

---

## 2. 架构图

```text
                     docker network: ci-net
 ┌────────────────────────────────────────────────────────────┐
 │  docker compose                                            │
 │                                                            │
 │   ┌──────────────┐   webhook    ┌──────────────────────┐   │
 │   │   gitlab     │ ───────────► │  jenkins (controller)│   │
 │   │  (Omnibus    │              │  image: jenkins/     │   │
 │   │   in Docker) │ ◄── git ───  │       jenkins:lts    │   │
 │   └──────┬───────┘              └──────────┬───────────┘   │
 │          │                                  │              │
 │          ▼                                  ▼              │
 │   volume: gitlab_data                 volume: jenkins_home │
 │   volume: gitlab_logs                 volume: jenkins_logs │
 │                                                            │
 │   （可选）nginx / gitlab-runner / jenkins-agent            │
 └────────────────────────────────────────────────────────────┘
          │ 80/443/22                    │ 8080/50000
          ▼                              ▼
        浏览器 / git client            浏览器 / Agent 连接
```

**两种拓扑**：

1. **单机 Compose**：适合笔记本或实验机（注意内存 ≥ 8G，推荐 16G）  
2. **双机 Compose**：A 只跑 GitLab；B 跑 Jenkins + Agent——更接近生产隔离  

---

## 3. 镜像与版本建议

| 服务 | 镜像示例 | 说明 |
|---|---|---|
| GitLab | `gitlab/gitlab-ce:17.x.x-ce.0` | **钉死小版本**，避免静默升级 |
| Jenkins | `jenkins/jenkins:2.462.x-lts-jdk17` | 用 LTS tag，不用 `latest` |
| Agent（可选） | `jenkins/inbound-agent:latest-jdk17` | 与 Controller 版本策略一致 |
| Nginx（可选） | `nginx:1.26-alpine` | TLS 终结 / 路径路由 |
| Docker-out-of-Docker（可选） | 挂载 `/var/run/docker.sock` 或 DinD | Pipeline 内 `docker build` 时需要 |

---

## 4. 目录与 Compose 骨架

推荐仓库内布局：

```text
deploy/03-docker/
├── .env.example
├── docker-compose.yml
├── compose.sh
├── jenkins/
│   ├── Dockerfile
│   └── plugins.txt
├── casc/
│   └── jenkins.yaml.example
└── nginx/
    └── default.conf.example
```

### 4.1 `.env` 示例

```env
GITLAB_HTTP_PORT=80
GITLAB_SSH_PORT=2222
GITLAB_HOSTNAME=gitlab.local
JENKINS_HTTP_PORT=8080
JENKINS_AGENT_PORT=50000
TZ=Asia/Shanghai
```

### 4.2 `docker-compose.yml` 示例（精简）

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:17.11.0-ce.0
    hostname: ${GITLAB_HOSTNAME}
    environment:
      TZ: ${TZ}
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://${GITLAB_HOSTNAME}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}
    ports:
      - "${GITLAB_HTTP_PORT}:80"
      - "${GITLAB_SSH_PORT}:22"
    volumes:
      - gitlab_config:/etc/gitlab
      - gitlab_data:/var/opt/gitlab
      - gitlab_logs:/var/log/gitlab
    shm_size: "256m"
    networks: [ci-net]
    restart: unless-stopped

  jenkins:
    image: jenkins/jenkins:2.462.3-lts-jdk17
    environment:
      TZ: ${TZ}
      JAVA_OPTS: "-Djenkins.install.runSetupWizard=true"
    ports:
      - "${JENKINS_HTTP_PORT}:8080"
      - "${JENKINS_AGENT_PORT}:50000"
    volumes:
      - jenkins_home:/var/jenkins_home
      # 若需在 Pipeline 里调用宿主机 Docker：
      # - /var/run/docker.sock:/var/run/docker.sock
    networks: [ci-net]
    restart: unless-stopped
    user: "1000:1000"

networks:
  ci-net:
    driver: bridge

volumes:
  gitlab_config:
  gitlab_data:
  gitlab_logs:
  jenkins_home:
```

启动：

```bash
cd deploy/03-docker
cp .env.example .env
bash compose.sh up
```

Jenkins 初始密码：

```bash
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

GitLab Root 密码：

```bash
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

---

## 5. 网络与主机名注意点

| 问题 | 处理 |
|---|---|
| 容器互访 | 用 Compose 服务名：`http://gitlab`、`http://jenkins:8080` |
| 浏览器访问 | 用宿主机端口映射；本机可改 hosts：`127.0.0.1 gitlab.local` |
| Webhook URL | GitLab **容器内** 回调 Jenkins 应写 `http://jenkins:8080/...`；浏览器打开仍用宿主机端口 |
| SSH Clone 端口 | 宿主机映射为 `2222` 时，Clone URL 需带端口或配置 `~/.ssh/config` |

**Webhook 双 URL 思维**：人类访问 URL ≠ 容器间访问 URL。可在 GitLab 填内网服务名，或在 Jenkins 前加 Nginx 统一域名。

---

## 6. Jenkins 在容器中的关键点

### 6.1 数据持久化

容器可删、卷不可丢。重要路径仍是容器内 `/var/jenkins_home`（即方案一的 `JENKINS_HOME`）：

- Job 配置、插件、凭证、用户、构建历史均在卷中  
- 升级镜像 ≈ 换容器 + 挂载同一卷  

### 6.2 插件与 CasC（建议）

```text
# plugins.txt 示例
git
gitlab-plugin
workflow-aggregator
credentials-binding
configuration-as-code
```

可用自定义 Dockerfile：

```dockerfile
FROM jenkins/jenkins:2.462.3-lts-jdk17
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
COPY casc/ /var/jenkins_home/casc_configs/
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs
```

这样团队可 **GitOps 式** 管理 Jenkins 配置，避免纯手点 UI。

### 6.3 Docker-in-Pipeline

常见三种做法：

| 方式 | 做法 | 风险 |
|---|---|---|
| Docker.sock 挂载 | 容器当客户端，用宿主机 Engine | 权限大，等同 root 宿主机 |
| DinD | sidecar `docker:dind` | 需 privileged，资源占用高 |
| Kaniko / Buildah | 无特权构建镜像 | 学习曲线，适合 K8s（方案四） |

实验环境可用 sock；生产更建议方案四或 rootless 构建。

---

## 7. GitLab 容器注意点

1. **内存**：Omnibus 容器建议宿主机空闲 ≥ 4–8G，否则频繁 OOM  
2. **`shm_size`**：不足可能导致 Prometheus 等组件异常  
3. **首次启动慢**：`docker compose logs -f gitlab` 等到 `gitlab Reconfigured!`  
4. **升级**：改 tag → `compose pull` → `compose up -d`；升级前备份卷  
5. **备份**：

```bash
docker compose exec gitlab gitlab-backup create
# 备份文件通常在 container 内 /var/opt/gitlab/backups
```

---

## 8. 联调流程（容器版）

1. 浏览器打开 GitLab，建项目 `demo/hello`，提交含 `Jenkinsfile` 的代码  
2. Jenkins 安装 Git / GitLab / Pipeline 插件（或镜像预装）  
3. Credentials 添加 GitLab Token  
4. 建 Pipeline Job，SCM 填：
   - **容器互通**：`http://gitlab/demo/hello.git`  
   - **凭证**：上一步 Token  
5. GitLab Webhook：`http://jenkins:8080/project/<job>`（服务名）  
6. Push 验证自动构建  

示例 `Jenkinsfile`：

```groovy
pipeline {
  agent any
  stages {
    stage('Info') {
      steps {
        sh 'git rev-parse --short HEAD && uname -a'
      }
    }
    stage('Build') {
      steps {
        sh 'echo build in dockerized jenkins'
      }
    }
  }
}
```

---

## 9. 运维速查

```bash
docker compose ps
docker compose logs -f --tail=200 gitlab
docker compose restart jenkins
docker volume ls | grep -E 'gitlab|jenkins'
docker compose down          # 停服务，默认保留 volume
docker compose down -v       # 危险：删卷
```

资源观察：

```bash
docker stats
```

---

## 10. 安全与生产基线（最小）

- [ ] 不使用 `latest`；镜像 tag 锁定  
- [ ] 密钥进 Docker secrets / 环境注入，不进 Git  
- [ ] Jenkins / GitLab 管理界面勿裸露公网；加 VPN 或 IP 白名单  
- [ ] 定期备份 `jenkins_home` 与 GitLab backup  
- [ ] 谨慎挂载 `docker.sock`  
- [ ] 使用反向代理开启 HTTPS  

---

## 11. 优缺点与边界

**优点**

- 交付快、环境一致、回滚相对简单（镜像 + 卷）  
- 与云主机、笔记本、CI 实验机都能对齐  
- 为方案四（K8s）打好镜像与配置拆分基础  

**缺点**

- 单机 Compose 无真正高可用  
- GitLab 容器资源敏感，弱机体验差  
- 存储与备份仍需自己设计  

**何时上方案四**：多团队、多 Agent 弹性、要声明式调度与自愈、要标准 Ingress/TLS/存储类时。

---

## 12. 验收清单

- [ ] `docker compose up -d` 后两侧 UI 可访问  
- [ ] 卷持久化：删容器重建后 Job/仓库仍在  
- [ ] 容器网络下 Webhook 自动构建成功  
- [ ] 完成一次 Jenkins 小版本镜像升级  
- [ ] 文档中写清「人类 URL」与「容器 URL」的区别  
- [ ] （可选）自定义镜像预装插件 + CasC 生效  

---

## 13. 相关文档

- [方案一：独立服务器（结构学习）](./01-jenkins-gitlab-standalone.md)  
- [方案二：Supervisor 进程守护](./02-jenkins-gitlab-supervisor.md)  
- [方案四：Docker + Kubernetes](./04-jenkins-gitlab-docker-k8s.md)  
- [方案五：当前项目内 Jenkins 配置（推荐作本仓本地入口）](./05-jenkins-project-local.md)  
