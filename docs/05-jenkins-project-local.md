# 方案五：面向当前项目（web-test）的 Jenkins 部署 —— 有 Docker / 无 Docker

> **目标**：以仓库内 Spring Boot 示例 [`web-test/`](../web-test/)（**Java 8 + Maven + Spring Boot 2.2**）为业务对象，提供两套本仓库自举 CI：
>
> 1. **有 Docker**：Compose 拉起 Jenkins，流水线用 Maven 容器编译，并构建/冒烟运行应用镜像  
> 2. **无 Docker**：宿主机安装 JDK8/Maven + Jenkins WAR，流水线直接 `mvn package` 并启动 jar 冒烟  

配置目录：[`deploy/05-project-local/`](../deploy/05-project-local/)

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 示例应用 | `web-test`（`com.example:web-test`，接口 `/hello` → `hello`） |
| 配置即代码 | 根目录 `Jenkinsfile` / `Jenkinsfile.docker` + `deploy/05-project-local/**` |
| 有 Docker | [`with-docker/`](../deploy/05-project-local/with-docker/) |
| 无 Docker | [`without-docker/`](../deploy/05-project-local/without-docker/) |

| 对比 | 有 Docker | 无 Docker |
|---|---|---|
| Jenkins 怎么装 | Compose + 自定义镜像 | WAR + systemd |
| 怎么编译 | `agent { docker { image 'maven:…-8' } }` | 宿主机 `jdk8` + `maven3`（CasC 工具） |
| 怎么验证 | `docker build` + `docker run` + curl | `java -jar` + curl |
| 依赖 | Docker Engine | JDK8、JDK17（跑 Jenkins）、Maven、curl |

---

## 2. 仓库布局

```text
jenkins/                              # 仓库根
├── Jenkinsfile                       # 无 Docker 流水线（默认）
├── Jenkinsfile.docker                # 有 Docker 流水线
├── web-test/                         # Spring Boot 示例
│   ├── pom.xml                       # java.version=1.8
│   ├── mvnw / mvnw.cmd
│   ├── Dockerfile                    # 运行镜像（JRE 8 + jar）
│   └── src/...
├── deploy/05-project-local/
│   ├── README.md
│   ├── with-docker/
│   │   ├── up.sh
│   │   ├── docker-compose.yml
│   │   ├── Dockerfile                # Jenkins + docker CLI + 插件
│   │   ├── plugins.txt
│   │   ├── casc/jenkins.yaml
│   │   └── Jenkinsfile               # 与根目录 Jenkinsfile.docker 同逻辑
│   └── without-docker/
│       ├── install-prereqs.sh        # JDK8/17 + Maven
│       ├── install-jenkins.sh
│       ├── start-jenkins.sh
│       ├── jenkins.service
│       ├── casc/jenkins.yaml         # 注册 jdk8 / maven3
│       ├── local-build.sh            # 不启 Jenkins 也能本机验证构建
│       └── Jenkinsfile
└── docs/05-jenkins-project-local.md
```

---

## 3. 架构对比

### 3.1 有 Docker

```text
宿主机 Docker Engine
        ▲ docker.sock
        │
┌───────┴──────── compose ─────────────────────────┐
│  Jenkins Controller（含 docker CLI）              │
│    stage1: docker run maven:…-8 → mvn package    │
│    stage2: docker build -t web-test:ci web-test  │
│    stage3: docker run web-test:ci → curl /hello  │
└──────────────────────────────────────────────────┘
```

### 3.2 无 Docker

```text
宿主机
├── openjdk-8  + maven     ← 构建 web-test
├── openjdk-21 + jenkins.war ← 跑 Controller
└── Pipeline:
      tools { jdk 'jdk8'; maven 'maven3' }
      dir('web-test') { sh 'mvn -B clean package' }
      java -jar target/*.jar --server.port=18080
      curl /hello
```

---

## 4. 有 Docker：操作步骤

```bash
cd deploy/05-project-local/with-docker
bash up.sh
```

1. 浏览器打开 `http://localhost:8080`，用户 `admin`，密码见 `.env` 中 `JENKINS_ADMIN_PASSWORD`  
2. New Item → Pipeline → Definition 选 **Pipeline script**（本地 compose 未配 Git 时不要选 from SCM）  
3. 粘贴本目录 `Jenkinsfile` 全部内容（与根目录 `Jenkinsfile.docker` 相同）  
4. 脚本会把挂载的 `/workspace/project/web-test` **同步到 Job workspace** 再构建（避免 Linux 上挂载目录属主为 root 时出现 `AccessDeniedException: …@tmp`）  

**说明**：

- 需挂载 `/var/run/docker.sock`；Linux 下 `up.sh` 会尝试写入 `DOCKER_GID`  
- Windows / Docker Desktop：一般可直接挂载命名管道/ sock，权限问题按 Desktop 文档处理  
- 应用镜像见 `web-test/Dockerfile`（`eclipse-temurin:8-jre`）  
- 冒烟通过后会常驻启动容器 `web-test`，宿主机访问：`http://localhost:8088/hello`  

冒烟成功标准：容器内服务响应 `GET /hello` 含文本 `hello`。

---

## 5. 无 Docker：操作步骤

### 5.1 安装工具链与 Jenkins

```bash
cd deploy/05-project-local/without-docker
sudo bash install-prereqs.sh
sudo bash install-jenkins.sh
```

- Jenkins 单元：`jenkins-local.service`  
- CasC：`casc/jenkins.yaml` 中工具名 **`jdk8`**、**`maven3`** 必须与 `Jenkinsfile` 的 `tools {}` 一致  
- 插件：按 `plugins-hint.txt` 在 UI 安装（至少 Pipeline、Git、JUnit、Configuration as Code）  

### 5.2 创建 Job

1. Pipeline script from SCM → Script Path：`Jenkinsfile`  
2. 或复制 `without-docker/Jenkinsfile`  

### 5.3 不启 Jenkins、只验证应用能编过

```bash
bash deploy/05-project-local/without-docker/local-build.sh
# Windows（在 web-test 目录）:
#   .\mvnw.cmd -B clean package
```

### 5.4 SSH 部署到另一台机器（无 Docker）

详细步骤见：[`without-docker/remote/README.md`](../deploy/05-project-local/without-docker/remote/README.md)

摘要：

1. **目标机**：`sudo bash prepare-target.sh`（装 JDK8 + systemd 单元 `web-test`）  
2. **Jenkins**：安装插件 `ssh-agent`，凭据 ID `web-test-deploy-ssh`  
3. **构建参数**：`DEPLOY_TO_REMOTE=true`，填写 `DEPLOY_HOST` / `DEPLOY_USER`  
4. 流水线在本地冒烟后执行 `deploy-via-ssh.sh`（scp jar → `systemctl restart web-test` → 远程 curl `/hello`）

默认 `DEPLOY_TO_REMOTE=false`，不配远程也不会影响日常构建。

---

## 6. 流水线阶段对照（web-test）

| 阶段 | 无 Docker（`Jenkinsfile`） | 有 Docker（`Jenkinsfile.docker`） |
|---|---|---|
| 编译测试 | 宿主机 `mvn -B clean package` | `maven:3.8.8-eclipse-temurin-8` 容器内 Maven |
| 产物 | `archiveArtifacts` jar + JUnit | 同左 |
| 冒烟 | `java -jar` 监听 18080 | `docker run -p 18080:8080` |
| 远程部署 | 可选：SSH + systemd（见 5.4） | 可自行扩展镜像部署 |
| 探活 | `curl .../hello` | 同左 |

`web-test` 关键属性：

| 项 | 值 |
|---|---|
| Spring Boot | 2.2.6.RELEASE |
| Java | 1.8 |
| 探活路径 | `/hello` |
| 产物 jar | `web-test/target/web-test-0.0.1-SNAPSHOT.jar` |

---

## 7. 在 Jenkins UI 里快速建 Job（挂载仓库时）

有 Docker 的 compose 将仓库挂到容器内 `/workspace/project`。可建 Pipeline，脚本写：

```groovy
node {
  dir('/workspace/project') {
    // 有 Docker：
    load 'Jenkinsfile.docker'   // 若报错，改为直接粘贴 Jenkinsfile.docker 内容
  }
}
```

更稳妥：Pipeline from SCM，指向 GitLab/本仓，选择对应 Script Path。

---

## 8. 密钥与忽略文件

- `with-docker/.env`：密码等，勿提交（根 `.gitignore` 已忽略 `.env`）  
- CasC 中 Token 只用 `${GITLAB_TOKEN}` 占位  

---

## 9. 验收清单

**公共**

- [ ] `web-test` 能本地 `mvn/mvnw package` 成功  
- [ ] `/hello` 返回 `hello`  

**有 Docker**

- [ ] `bash with-docker/up.sh` 后 Jenkins UI 可登录  
- [ ] Job 跑通 `Jenkinsfile.docker`（含镜像构建与容器冒烟）  

**无 Docker**

- [ ] `install-prereqs.sh` 后 `java`/`mvn` 可用，存在 JDK8 路径  
- [ ] `jenkins-local` 服务 RUNNING，CasC 工具 jdk8/maven3 可见  
- [ ] Job 跑通根目录 `Jenkinsfile`  

---

## 10. 选型建议

| 场景 | 建议 |
|---|---|
| 本机已装 Docker、求环境一致 | **有 Docker** |
| 教学看清 JDK/Maven/Jenkins 进程与目录 | **无 Docker** |
| 生产构建隔离 | 优先有 Docker / 方案四动态 Agent |

---

## 11. 相关文档

- [方案一：独立服务器部署](./01-jenkins-gitlab-standalone.md)  
- [方案二：Supervisor 部署](./02-jenkins-gitlab-supervisor.md)  
- [方案三：Docker Compose 部署](./03-jenkins-gitlab-docker.md)  
- [方案四：Docker + Kubernetes](./04-jenkins-gitlab-docker-k8s.md)  
- [同时安装 JDK 8 与 JDK 17](./06-install-jdk8-and-jdk17.md)  
