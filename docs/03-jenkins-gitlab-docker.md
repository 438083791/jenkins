# 方案三：Jenkins + GitLab + Docker 部署

> **目标**：用 Docker Compose 一键拉起 GitLab 与 Jenkins（**Controller 使用 JDK 21**，与方案五宿主机/`with-docker` 一致），配置 Webhook 后实现：
>
> **用户提交代码 → GitLab 通知 Jenkins → Jenkins 打包构建 → Docker 部署应用**

> **配置目录**：[`deploy/03-docker/`](../deploy/03-docker/)

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 开发/测试；希望 GitLab + Jenkins 容器化，并用 Docker 交付应用 |
| 部署形态 | 单机 Compose（推荐入门）；也可拆成双机各跑一份 Compose |
| Jenkins 运行时 | 自定义镜像：`jenkins/jenkins:*-lts-jdk21` + docker CLI（参考方案五 `with-docker` Dockerfile） |
| 应用构建 | Pipeline 内用 `maven:*-temurin-8` 容器编 `web-test`（Java 8） |
| 应用部署 | Jenkins 经 `docker.sock` 调用宿主机 Engine：`docker build` / `docker run` |
| **配置目录** | [`deploy/03-docker/`](../deploy/03-docker/) |

**标准流程**

```text
1. bash compose.sh up          # Docker 安装 GitLab + Jenkins（JDK21）
2. 配置 GitLab Webhook、Jenkins Pipeline（SCM = GitLab 仓库）
3. 用户 git push
4. GitLab → Webhook → Jenkins
5. Jenkins：mvn package → docker build → docker run（部署）
6. 探活 http://localhost:8088/hello
```

---

## 2. 架构图

```text
                     docker network: ci-net
 ┌────────────────────────────────────────────────────────────┐
 │  docker compose                                            │
 │                                                            │
 │   ┌──────────────┐   webhook    ┌──────────────────────┐   │
 │   │   gitlab     │ ───────────► │  jenkins             │   │
 │   │  (Omnibus)   │              │  JDK21 + docker CLI  │   │
 │   │              │ ◄── git ───  │  (自定义镜像)         │   │
 │   └──────────────┘              └──────────┬───────────┘   │
 │                                            │ docker.sock   │
 │                                            ▼               │
 │                                   宿主机 Docker Engine     │
 │                                   docker build / run       │
 │                                   └─ container: web-test   │
 │                                      port 8088→8080        │
 └────────────────────────────────────────────────────────────┘
          │ 80/443/22                    │ 8080/50000
          ▼                              ▼
        浏览器 / git                   浏览器 / Agent
```

---

## 3. 镜像与版本

| 服务 | 镜像 / 构建 | 说明 |
|---|---|---|
| GitLab | `gitlab/gitlab-ce:17.x.x-ce.0`（`.env` 钉死） | Omnibus 容器 |
| Jenkins | `deploy/03-docker/jenkins/Dockerfile` → `my-project-jenkins:scheme03` | **基础镜像 `jenkins/jenkins:2.568.1-lts-jdk21`**（同方案五） |
| 构建 Agent | `maven:3.8.8-eclipse-temurin-8` | 仅编应用，不跑 Controller |
| 应用镜像 | `web-test/Dockerfile` → `web-test:ci` | Temurin 8 JRE |

> 现行 Jenkins LTS Controller **需要 Java 21+**；不要再用 jdk17 标签跑新 LTS。

---

## 4. 目录与启动

```text
deploy/03-docker/
├── .env.example
├── docker-compose.yml
├── compose.sh
├── README.md
├── Jenkinsfile.example      # 打包 → 镜像 → 部署
├── jenkins/
│   ├── Dockerfile           # JDK21 + docker CLI + 插件
│   └── plugins.txt
├── casc/
│   └── jenkins.yaml.example
└── nginx/
    └── default.conf.example
```

### 4.1 启动

```bash
cd deploy/03-docker
cp .env.example .env
bash compose.sh up          # 含 --build；Linux 自动写 DOCKER_GID
bash compose.sh passwords
```

- Jenkins：`http://localhost:8080`  
- GitLab：按 `GITLAB_HTTP_PORT` / `GITLAB_HOSTNAME`  
- 应用（部署成功后）：`http://localhost:8088/hello`  

### 4.2 Compose 要点

- Jenkins **build** 自 `./jenkins`（JDK21），不再直接用未含 docker 的官方裸镜像作为最终运行镜像  
- 默认挂载 `/var/run/docker.sock`（实验环境；生产需评估安全）  
- `group_add: DOCKER_GID` 避免 sock 权限问题（与方案五 `with-docker/up.sh` 同思路）  
- 网络名 `ci-net`：冒烟/常驻容器加入后，Jenkins 用**容器名**探活（勿用 `127.0.0.1` 访问其它容器）  

---

## 5. 网络与 Webhook URL

| 场景 | URL 示例 |
|---|---|
| 浏览器开 Jenkins | `http://localhost:8080` |
| 浏览器开 GitLab | `http://localhost` 或 `http://gitlab.local`（需 hosts） |
| 容器内 Jenkins → GitLab Clone | `http://gitlab/<group>/<project>.git` |
| GitLab Webhook → Jenkins | `http://jenkins:8080/project/<job>` |

人类访问 URL ≠ 容器互通 URL。

---

## 6. Jenkins（JDK21）与 Docker-in-Pipeline

### 6.1 与方案五的关系

| 能力 | 方案五 `without-docker` | 方案五 `with-docker` | 本方案 `03-docker` |
|---|---|---|---|
| Jenkins 怎么跑 | 宿主机 war + systemd，**JDK21** | Compose 自定义镜像 **JDK21** | Compose 自定义镜像 **JDK21**（同 Dockerfile 思路） |
| 是否带 GitLab | 否（用 01） | 否 | **是（同 Compose）** |
| 应用怎么部署 | SSH + systemd/Supervisor | `docker run` | `docker run`（本方案主路径） |

安装/镜像构建参考：

- 宿主机脚本：[`deploy/05-project-local/without-docker/install-jenkins.sh`](../deploy/05-project-local/without-docker/install-jenkins.sh)（JDK21 校验）  
- 容器 Dockerfile：[`deploy/05-project-local/with-docker/Dockerfile`](../deploy/05-project-local/with-docker/Dockerfile)（与本方案 `jenkins/Dockerfile` 同源思路）  

### 6.2 插件

`jenkins/plugins.txt` 含 `git`、`gitlab-plugin`、`docker-workflow` 等，构建镜像时预装。

### 6.3 Docker 部署方式（本方案默认）

| 方式 | 本方案 | 说明 |
|---|---|---|
| Docker.sock 挂载 | **默认启用** | Pipeline 可 `docker build` / `run` |
| DinD | 未默认 | 可自行加 sidecar |
| Kaniko 等 | 见方案四 | 更适合 K8s |

---

## 7. GitLab 容器注意点

1. **内存**：建议宿主机空闲 ≥ 4–8G  
2. **`shm_size`**：compose 已设 `256m`  
3. **首次启动慢**：`bash compose.sh logs gitlab` 等到就绪  
4. **备份**：`docker compose exec gitlab gitlab-backup create`  

---

## 8. 联调流程（完整交付）

1. `bash compose.sh up`，两侧 UI 可打开，记下密码  
2. GitLab 建项目，推送含应用与 Pipeline 的代码（可用本仓库，Script Path 见下）  
3. Jenkins：凭据添加 GitLab Token / Deploy Key  
4. 新建 Pipeline Job（Pipeline script from SCM）：  
   - SCM：`http://gitlab/<group>/<project>.git`  
   - Script Path：`deploy/03-docker/Jenkinsfile.example`（独立 `web-test` 仓则拷贝到根并设参数 `APP_SUBDIR=.`）  
5. GitLab Webhook：`http://jenkins:8080/project/<job>`，勾选 Push  
6. `git push` → 观察 Jenkins：Maven → `docker build` → 冒烟 → `docker run`  
7. 宿主机访问：`curl http://localhost:8088/hello`  

流水线阶段摘要：

```text
Prepare → Maven package（temurin-8 容器）
       → Docker build app image
       → Smoke run container
       → Docker deploy（常驻 web-test，端口 8088）
```

---

## 9. 运维速查

```bash
bash compose.sh ps
bash compose.sh logs jenkins
bash compose.sh logs gitlab
bash compose.sh down          # 保留 volume
bash compose.sh down-v        # 删卷（危险）
docker ps --filter name=web-test
docker stats
```

---

## 10. 安全与生产基线（最小）

- [ ] 镜像 tag 锁定，不用 `latest`  
- [ ] 密钥不进 Git  
- [ ] 管理界面勿裸露公网  
- [ ] 备份 `jenkins_home` 与 GitLab  
- [ ] **评估 docker.sock 风险**；生产可改为专用构建节点或方案四  
- [ ] HTTPS / 反代  

---

## 11. 优缺点与边界

**优点**

- 一条 Compose 同时有 GitLab + Jenkins，联调路径短  
- Jenkins JDK21 与方案五一致，避免 Controllers 版本踩坑  
- 默认打通「构建 → Docker 部署」，与方案二（Supervisor）形成对照  

**缺点**

- 单机 Compose 无真正高可用  
- sock 挂载权限大  
- GitLab 容器吃内存  

**何时上方案四**：要弹性 Agent、标准 Ingress/存储/多租户时。

---

## 12. 验收清单

- [ ] `compose.sh up` 后 GitLab、Jenkins UI 可访问；Jenkins 为 **JDK21** 镜像  
- [ ] 卷持久化：重建容器后 Job/仓库仍在  
- [ ] Webhook：Push 自动触发构建  
- [ ] Pipeline 完成 `docker build` 与常驻 `docker run`  
- [ ] `curl http://localhost:8088/hello` 成功  
- [ ] 能分清浏览器 URL 与容器内 Webhook/Clone URL  

---

## 13. 相关文档

- [方案一：独立服务器（结构学习）](./01-jenkins-gitlab-standalone.md)  
- [方案二：Jenkins 打包上传 + Supervisor 管应用](./02-jenkins-gitlab-supervisor.md)  
- [方案四：Docker + Kubernetes](./04-jenkins-gitlab-docker-k8s.md)  
- [方案五：当前项目内 Jenkins 配置（JDK21 安装参考）](./05-jenkins-project-local.md)  
- 脚本目录：[`deploy/03-docker/`](../deploy/03-docker/)  
