# 方案一：Jenkins + GitLab 独立服务器部署

> **目标**：在两台（或多台）独立机器上分别部署 GitLab 与 Jenkins，走通「代码托管 → Webhook → 构建」全链路，深入理解 Jenkins 目录结构、配置模型、插件体系与 Job 执行细节。

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 学习 / 实验 / 小型团队首次落地 CI |
| 部署形态 | 物理机或虚拟机，**非容器**，进程级安装 |
| 组件分布 | 服务器 A：GitLab；服务器 B：Jenkins（可再加 Agent） |
| 核心收益 | 看清原生安装目录、配置文件、日志与进程模型 |
| **配置目录** | [`deploy/01-standalone/`](../deploy/01-standalone/) |

本方案刻意不用 Docker / K8s，便于直接观察文件系统与 systemd 服务行为。

---

## 2. 架构图

```text
┌─────────────────────┐         Webhook / API          ┌─────────────────────┐
│   服务器 A：GitLab  │ ──────────────────────────────► │  服务器 B：Jenkins  │
│                     │                                 │                     │
│  · Git 仓库         │ ◄────── Checkout / Clone ────── │  · Controller       │
│  · CI Token / Hook  │                                 │  · 可选 Agent 节点  │
│  · Users / Groups   │                                 │  · 构建工作区       │
└─────────────────────┘                                 └──────────┬──────────┘
                                                                   │
                                                                   ▼
                                                          构建产物 / 测试报告
                                                          （本地磁盘或制品库）
```

**推荐网络关系**：两台机器互通 `80/443`（GitLab）、`8080`（Jenkins，生产建议反代到 443），以及 Git SSH `22`。

---

## 3. 环境与版本建议

| 组件 | 建议版本 | 备注 |
|---|---|---|
| OS | Ubuntu 22.04+ / 25.x | 文档以 Ubuntu 为例 |
| GitLab | GitLab CE 最新稳定版（Omnibus） | 自带 Nginx、PostgreSQL、Redis |
| Jenkins | 现行 LTS（`jenkins.war`） | **复用方案五** `without-docker` 安装脚本，不用 apt deb |
| JDK | **21**（跑 Jenkins）；构建可另配 8 | 现行 LTS **不支持** 用 17 启动 Controller |
| Git | 系统自带即可 | Jenkins 侧需配置 Git 工具 |

资源起步建议：

- GitLab：4C / 8G / 50G+ 磁盘（Omnibus 较吃内存）
- Jenkins Controller：2C / 4G / 40G（含工作区与插件）

---

## 4. GitLab 独立部署要点

### 4.1 安装（Omnibus）

```bash
# Ubuntu 示例
sudo apt-get update
sudo apt-get install -y curl openssh-server ca-certificates tzdata perl
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
sudo EXTERNAL_URL="http://gitlab.example.com" apt-get install -y gitlab-ce
```

安装完成后，Root 初始密码在：

```text
/etc/gitlab/initial_root_password
```

### 4.2 关键配置文件与目录

| 路径 | 作用 |
|---|---|
| `/etc/gitlab/gitlab.rb` | Omnibus 主配置（外部 URL、端口、邮件等） |
| `/var/opt/gitlab` | 运行数据（Git 仓、PostgreSQL、Redis 等） |
| `/var/log/gitlab` | 各组件日志 |
| `/opt/gitlab` | 程序本身 |

修改配置后：

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl status
```

### 4.3 为 Jenkins 准备集成要素

1. 创建 Group / Project（如 `demo/hello`）
2. 创建 **Project Access Token** 或 **Personal Access Token**（`api`、`read_repository`）
3. 在项目 **Settings → Webhooks** 预留 Jenkins 触发地址（见第 6 节）
4. （可选）启用 GitLab Runner——本方案主路径是 Jenkins 拉代码构建，Runner 可不装

---

## 5. Jenkins 独立部署与结构深挖

### 5.1 安装（Ubuntu，复用方案五脚本）

现行 Jenkins LTS 需要 **JDK 21+**。方案一的 `install-jenkins.sh` 会调用方案五无 Docker 脚本（`jenkins.war` + `systemd`），全仓库只维护这一套宿主机安装逻辑：

```bash
cd deploy/01-standalone
cp .env.example .env   # 可选，改端口 / 密码
sudo bash install-jenkins.sh
# 内部等价于：
#   sudo bash ../05-project-local/without-docker/install-prereqs.sh
#   sudo bash ../05-project-local/without-docker/install-jenkins.sh
```

访问：`http://<jenkins-host>:8080`（端口见 `.env` 中 `JENKINS_HTTP_PORT`）。

```bash
systemctl status jenkins-local
# CasC 已配置密码时用 admin；否则：
sudo cat /opt/ci/jenkins/home/secrets/initialAdminPassword
```

JDK 说明见 [`docs/06-install-jdk8-and-jdk17.md`](./06-install-jdk8-and-jdk17.md)。

### 5.2 核心目录结构（学习重点）

本方案实际 `JENKINS_HOME` 为 **`/opt/ci/jenkins/home`**（war 方式）。下面以官方 deb 的 `/var/lib/jenkins` 作对照说明，概念相同——学习时把路径替换为本方案路径即可。

```text
/opt/ci/jenkins/home/             # 本方案 JENKINS_HOME
/opt/ci/jenkins/jenkins.war       # 主程序 WAR
/opt/ci/jenkins/start-jenkins.sh  # 启动脚本（校验 Java >= 21）
# systemd: jenkins-local.service

# --- 以下为 Jenkins 通用布局（deb 默认路径对照）---
/var/lib/jenkins/                 # 官方 deb 的 JENKINS_HOME（对照用）
├── config.xml                    # 全局配置（安全、执行器数、工具等）
├── credentials.xml               # 凭证密文存储
├── secrets/                      # 主密钥与节点密钥
├── users/                        # 用户配置
├── plugins/                      # 已安装插件 *.jpi / *.hpi 与解压目录
├── jobs/                         # 所有 Job / Folder
│   └── <job-name>/
│       ├── config.xml            # Job 定义（SCM、触发器、构建步骤）
│       ├── nextBuildNumber
│       └── builds/               # 每次构建产物与元数据
│           ├── 1/
│           │   ├── build.xml
│           │   ├── log
│           │   └── ...
│           └── lastSuccessfulBuild -> ...
├── workspace/                    # 默认工作区（Checkout 后的代码）
├── nodes/                        # 静态 Agent 节点配置
└── logs/                         # Jenkins 自身日志摘要

/etc/default/jenkins              # deb 包启动参数（本方案不使用）
/usr/share/java/jenkins.war       # deb 包 WAR（本方案用 /opt/ci/jenkins/jenkins.war）
/var/log/jenkins/jenkins.log      # deb 包日志（本方案用 journalctl -u jenkins-local）
```

**建议动手练习**：

1. 改 `/etc/default/jenkins` 中的 `HTTP_PORT`、`JAVA_OPTS`，`systemctl restart jenkins`，观察效果  
2. 用 UI 创建一个 Freestyle Job，再对比 `jobs/<name>/config.xml` 的 XML 结构  
3. 触发一次构建，对照 `builds/1/log` 与 `workspace/` 内容  
4. 安装插件后查看 `plugins/` 目录变更

### 5.3 Jenkins 核心概念对照

| 概念 | 含义 | 本方案中的落点 |
|---|---|---|
| Controller | 调度与配置中心 | 服务器 B 上的 jenkins 服务 |
| Agent / Node | 实际执行构建的节点 | 可先用 Controller 自建（Built-in），再扩独立 Agent |
| Executor | 并发构建槽位 | Manage Jenkins → 系统配置 |
| Job / Pipeline | 构建定义 | Freestyle 或 Pipeline（Jenkinsfile） |
| Credential | 密码/Token/SSH Key | GitLab Token、SSH Deploy Key |
| Plugin | 扩展能力 | Git、GitLab、Pipeline、Credentials Binding 等 |

### 5.4 推荐插件（本方案最小集）

- Git plugin  
- GitLab Plugin（Webhook 触发与状态回写）  
- Pipeline / Workflow（学习声明式流水线）  
- Credentials Binding  
- SSH Agent（若用 SSH 拉仓）

---

## 6. GitLab ↔ Jenkins 联调步骤

### 6.1 Jenkins 侧

1. **Manage Jenkins → Credentials**：添加 GitLab Token（类型：Secret text 或 Username with password）  
2. **Manage Jenkins → System → GitLab**：填写 GitLab Connection（URL + Credential）  
3. 新建 Pipeline Job（或 Freestyle）：
   - SCM：Git，Repository URL 指向 GitLab 项目 HTTP/SSH
   - 构建触发：勾选 GitLab webhook 相关触发选项（插件提供）

示例 `Jenkinsfile`（可放在 GitLab 仓库根目录）：

```groovy
pipeline {
  agent any
  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }
    stage('Build') {
      steps {
        sh 'echo "build on $(hostname)" && ls -la'
      }
    }
    stage('Test') {
      steps {
        sh 'echo "run tests..."'
      }
    }
  }
  post {
    always {
      echo "build finished: ${currentBuild.currentResult}"
    }
  }
}
```

### 6.2 GitLab 侧 Webhook

在项目 **Settings → Webhooks**：

- URL：`http://<jenkins-host>:8080/project/<job-name>`（以 GitLab Plugin 实际路径为准）  
- Trigger：Push events / Merge request events  
- （可选）Secret Token 与 Jenkins Job 中一致  

验证：向仓库推送一次 commit，确认 Jenkins 出现新构建，GitLab 提交页可看到 pipeline/status（若已配置状态回写）。

### 6.3 SSH 拉代码备选

1. 在 Jenkins 生成 SSH Key，公钥加入 GitLab Deploy Keys  
2. Jenkins Credential 选 SSH Username with private key  
3. Job SCM URL 使用 `git@gitlab.example.com:group/project.git`

---

## 7. 进程与运维观察（理解细节）

```bash
# 服务状态
systemctl status jenkins
systemctl status gitlab-runsvdir   # Omnibus 由 runit 管多进程

# Jenkins JVM
ps aux | grep jenkins
jcmd <pid> VM.flags

# 日志
tail -f /var/log/jenkins/jenkins.log
sudo gitlab-ctl tail
```

关注点：

- Jenkins 以系统用户 `jenkins` 运行，工作区与插件权限均属该用户  
- GitLab Omnibus 是「套件」：Nginx、Puma、Sidekiq、PostgreSQL、Gitaly、Redis 等多进程协同  
- 备份：`JENKINS_HOME` 整目录 tar；GitLab 用 `gitlab-backup create`

---

## 8. 分阶段学习路径（建议按序完成）

| 阶段 | 任务 | 验收标准 |
|---|---|---|
| P0 | 两机装好，浏览器可登录 | 两侧 UI 正常 |
| P1 | Freestyle Job 手动拉 GitLab 代码并 echo | Workspace 有代码 |
| P2 | 看懂 `JENKINS_HOME` 与单次 `builds/` | 能口述目录用途 |
| P3 | Webhook 自动触发 | Push 即构建 |
| P4 | 改用 Pipeline + Jenkinsfile | 仓库内声明流水线 |
| P5 | 增加一台 Linux Agent，标签调度 | Job 在 Agent 上跑 |

---

## 9. 优缺点与边界

**优点**

- 配置透明，便于排查与学习 Jenkins 内部结构  
- 无容器层抽象，问题更「原始」、好复盘  
- 与企业历史裸机部署方式接近  

**缺点**

- 环境漂移大，换机复现成本高  
- 依赖冲突（多 JDK / 多语言工具链）难管理  
- 扩缩容、升级、蓝绿均需人工  

**不适合**：大规模多团队、频繁发布、强要求弹性伸缩的场景（请看方案三 / 四）。

---

## 10. 验收清单

- [ ] GitLab、Jenkins 分别可访问，时区与主机名正确  
- [ ] Token / SSH Credential 配置完成且可 Clone  
- [ ] Push 触发 Webhook → Jenkins 构建成功  
- [ ] 能指出 `config.xml`、`jobs/`、`workspace/`、`plugins/` 的作用  
- [ ] 完成至少一次插件安装与一次 Job `config.xml` 对比阅读  
- [ ] 备份过一次 `JENKINS_HOME` 并演练恢复思路  

---

## 11. 下一步

学完本方案结构后，可进入：

- [方案二：Jenkins + GitLab + Supervisor](./02-jenkins-gitlab-supervisor.md) — 用进程管理器统一托管、加强自愈与日志规范  
- 或直接对比 [方案三 Docker 化](./03-jenkins-gitlab-docker.md) 看抽象层差异  
- 若要把配置收进**本示例仓库根目录**（Jenkinsfile / `jenkins/casc`），见 [方案五：项目内 Jenkins 配置](./05-jenkins-project-local.md)  
- 虚拟机上同时准备构建 JDK 与 Jenkins 运行 JDK：见 [同时安装 JDK 8 与 JDK 17](./06-install-jdk8-and-jdk17.md)
