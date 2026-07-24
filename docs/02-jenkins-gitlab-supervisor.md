# 方案二：Jenkins + GitLab + Supervisor 部署

> **目标**：打通「代码提交 → 自动构建 → 上传目标机 → Supervisor 统一管应用启停」的交付链路。  
> GitLab 管代码与通知，Jenkins 管打包与上传，**Supervisor 只托管业务应用进程**（不托管 Jenkins / GitLab）。

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 虚机/物理机交付 Java（或其它常驻）应用；暂未上 Docker |
| 相对方案一 | 方案一侧重 Jenkins 自身安装与目录；本方案补齐 **构建产物如何上线并由进程管理器守护** |
| 典型拓扑 | A：GitLab；B：Jenkins；C：应用机（Supervisor 管 `web-test` 等） |
| **配置目录** | [`deploy/02-supervisor/`](../deploy/02-supervisor/) |

**标准流程（本方案核心）**

```text
用户 git push
    → GitLab 收到提交
    → Webhook 通知 Jenkins
    → Jenkins：检出 → 编译打包 → 上传产物到应用机
    → 应用机：Supervisor 重启/拉起程序（统一启停与自愈）
```

**边界澄清**

| 组件 | 谁管进程 | 本方案职责 |
|---|---|---|
| GitLab | Omnibus 自带 runit | 仓库 + Webhook |
| Jenkins | systemd / 官方包（同方案一） | CI：构建、归档、SSH 上传 |
| 业务应用（如 web-test） | **Supervisor** | 常驻运行、崩溃重启、日志 |

不要用 Supervisor 再包一层 GitLab/Jenkins——两者已有成熟进程模型；Supervisor 的价值在 **统一管理多业务程序**。

---

## 2. 架构图

```text
┌────────────────────┐   Webhook    ┌────────────────────┐
│ 服务器 A：GitLab   │ ───────────► │ 服务器 B：Jenkins  │
│ 仓库 / Token       │ ◄── clone ── │ mvn package        │
└────────────────────┘              │ scp jar 到 C       │
                                    └─────────┬──────────┘
                                              │ SSH / scp
                                              ▼
                                    ┌────────────────────┐
                                    │ 服务器 C：应用机    │
                                    │  Supervisor         │
                                    │    └─ program:      │
                                    │       web-test      │
                                    │  /opt/web-test/     │
                                    │  /opt/app-logs/     │
                                    └────────────────────┘
```

演示可将 B/C 合并为一台机；生产建议 Jenkins 与业务应用分离。

---

## 3. 环境准备

| 角色 | 组件建议 |
|---|---|
| A GitLab | Omnibus CE（同[方案一](./01-jenkins-gitlab-standalone.md)） |
| B Jenkins | 官方包或方案一 / 方案五无 Docker 安装；JDK17/21 跑 Jenkins，JDK8 编应用 |
| C 应用机 | OpenJDK 8（跑 Spring Boot 示例）、Supervisor、openssh-server |

应用机目录规划：

```text
/opt/web-test/
├── web-test.jar          # Jenkins 每次覆盖上传
└── start-app.sh          # Supervisor command
/opt/app-logs/
├── web-test.out.log
└── web-test.err.log
/etc/supervisor/conf.d/
└── web-test.conf
```

---

## 4. GitLab 侧

1. 创建项目，推送含 `pom.xml` / `Jenkinsfile` 的代码（可用 [`web-test/`](../web-test/)）  
2. 为 Jenkins 准备 Deploy Token 或 SSH Deploy Key（只读 Clone）  
3. 项目 → Settings → Webhooks：URL 指向 Jenkins Job 触发地址（安装 GitLab 插件后形如 `http://<jenkins>:8080/project/<job>`）  
4. Push 事件勾选；Secret Token 与 Jenkins 侧一致  

详情与 Token 配置可对照[方案一第 6 节](./01-jenkins-gitlab-standalone.md)。

---

## 5. Jenkins 侧

### 5.1 安装与工具

- 安装方式复用方案一或 [`deploy/05-project-local/without-docker/`](../deploy/05-project-local/without-docker/)  
- 工具：`jdk8`、`maven3`（名称需与 Pipeline `tools {}` 一致）  
- 插件：GitLab Plugin（Webhook）、Credentials Binding（SSH 私钥）  
- 系统包：`openssh-client`

### 5.2 SSH 凭据

1. 在应用机执行一次 `setup-deploy-ssh-key.sh`（见第 6 节）  
2. Jenkins → Credentials → **SSH Username with private key**  
   - ID：`web-test-deploy-ssh`  
   - Username：与应用机 `DEPLOY_USER` 一致（默认 `deploy`）  
   - Private Key：目标机生成的私钥全文  

### 5.3 Pipeline

使用本方案部署脚本（**走 Supervisor，不是 systemd**）：

- 示例：[`deploy/02-supervisor/Jenkinsfile.example`](../deploy/02-supervisor/Jenkinsfile.example)  
- 部署脚本：[`deploy/02-supervisor/deploy-via-ssh.sh`](../deploy/02-supervisor/deploy-via-ssh.sh)  

若独立仓是 `web-test/`，可将 `Jenkinsfile.example` 拷到仓库根，并把 `ci/deploy-via-ssh.sh` 换成指向本方案脚本，或保持 Script Path 指向本仓库路径。

Job 关键参数：

| 参数 | 说明 | 示例 |
|---|---|---|
| `DEPLOY_TO_REMOTE` | 是否部署 | `true` |
| `DEPLOY_HOST` | 应用机 | `192.168.122.144` |
| `DEPLOY_USER` | SSH 用户 | `deploy` |
| `APP_RUN_USER` | Supervisor `user=` | `deploy` |
| `DEPLOY_PATH` | 安装目录 | `/opt/web-test` |
| `APP_HTTP_PORT` | 应用端口 | `8088` |
| `SSH_CREDENTIALS_ID` | 凭据 ID | `web-test-deploy-ssh` |

构建阶段预期：

```text
Prepare → Test & Package → Smoke（Jenkins 节点本地）→ Deploy remote
  Deploy：scp jar → 安装到 /opt/web-test
       → supervisorctl restart web-test
       → curl /hello
       → supervisorctl status web-test（自动执行并校验 RUNNING，无需手工）
```

---

## 6. 应用机：Supervisor 部署（只做一次）

脚本目录：`deploy/02-supervisor/`。

```bash
cd deploy/02-supervisor
sudo bash install.sh
# 分离运行用户与部署用户时：
# sudo APP_USER=webapp DEPLOY_USER=deploy bash install.sh

sudo bash setup-deploy-ssh-key.sh
# sudo DEPLOY_USER=deploy bash setup-deploy-ssh-key.sh
```

`install.sh` 会：

1. 安装 `openjdk-8-jdk`、`supervisor`、`curl`、`openssh-server`  
2. 创建 `APP_USER` / `DEPLOY_USER` 与 `/opt/web-test`、`/opt/app-logs`  
3. 安装 `start-app.sh`、`web-test.conf`、sudoers（允许 `supervisorctl` 等）  
4. `supervisorctl reread && update`（首次无 jar 时可能 FATAL，属正常；首次 Jenkins 部署成功后变为 RUNNING）

### 6.1 Supervisor 程序配置（摘要）

`/etc/supervisor/conf.d/web-test.conf`：

```ini
[program:web-test]
command=/opt/web-test/start-app.sh
directory=/opt/web-test
user=deploy
autostart=true
autorestart=true
startsecs=5
startretries=3
stopwaitsecs=30
stopsignal=TERM
stdout_logfile=/opt/app-logs/web-test.out.log
stderr_logfile=/opt/app-logs/web-test.err.log
environment=APP_PORT="8088",JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"
```

### 6.2 常用运维

```bash
# 封装脚本
bash ctl.sh status
bash ctl.sh restart
bash ctl.sh logs

# 或直接
sudo supervisorctl status web-test
sudo supervisorctl restart web-test
sudo supervisorctl tail -f web-test
```

放行应用端口：

```bash
sudo ufw allow 8088/tcp
```

---

## 7. 端到端联调步骤

1. 应用机：`install.sh` + SSH 密钥 → 私钥导入 Jenkins  
2. Jenkins：建 Pipeline Job，Webhook 与 GitLab 打通  
3. 本地改代码 → `git push` 到 GitLab  
4. 确认 GitLab Webhook 返回 200，Jenkins 构建排队并成功  
5. 在 Jenkins 控制台日志中确认已自动打印 `supervisorctl status web-test` 且为 RUNNING  
6. （可选）本机再 `curl http://<应用机>:8088/hello` 复核  

排错：

| 现象 | 排查 |
|---|---|
| Webhook 失败 | Jenkins URL 是否 GitLab 可达；Secret；防火墙 8080 |
| Clone 失败 | Deploy Key / Token；凭据 ID |
| scp / SSH 失败 | 私钥、Username、`BatchMode`、目标机 `authorized_keys` |
| supervisorctl 失败 | `/etc/sudoers.d/` 是否含 `supervisorctl`；program 名是否 `web-test` |
| 探活失败 | `tail` 应用日志；JDK8 路径；`APP_PORT` 与 ufw |

---

## 8. 与「方案五 remote + systemd」的关系

| 项 | 方案五 `without-docker/remote` | 本方案 `02-supervisor` |
|---|---|---|
| 进程管理 | systemd `web-test.service` | Supervisor `program:web-test` |
| 部署重启 | `systemctl restart` | `supervisorctl restart` |
| 适用 | 已统一用 systemd 的环境 | 需 Supervisor 集中管多应用、或运维习惯 supervisord |

二者 **上传 jar 的思路相同**，仅目标机守护方式不同；不要混用同一台机的两套 unit（除非 program/服务名与端口完全隔离）。

---

## 9. 优缺点与边界

**优点**

- 流程清晰：GitLab 通知、Jenkins 构建分发、Supervisor 管运行态  
- 多应用可共用一个 supervisord，启停与日志入口统一  
- 仍可不引入 Docker，适合教学与传统机房  

**缺点**

- 无镜像级环境复现；依赖目标机 JDK/系统库  
- Jenkins 与应用机 SSH/sudo 权限需认真收紧  
- 多机扩容、灰度需自行约定目录与 program 命名  

**何时到方案三**：需要「构建环境与运行环境一致、一键拉起多服务」时，再上 Docker Compose。

---

## 10. 验收清单

- [ ] GitLab Push → Jenkins 自动构建成功  
- [ ] Jenkins 将 jar 上传到 `/opt/web-test/web-test.jar`  
- [ ] 部署阶段自动执行 `supervisorctl status web-test`，日志中为 RUNNING（失败则 Job 失败）  
- [ ] 杀掉应用 Java 进程后，数秒内被 Supervisor 拉起  
- [ ] 探活 `/hello` 成功（Pipeline 内已做）  
- [ ] 能说清：GitLab / Jenkins / Supervisor **各自管什么**  

---

## 11. 相关文档

- [方案一：独立服务器部署（结构深挖）](./01-jenkins-gitlab-standalone.md)  
- [方案三：Docker 部署](./03-jenkins-gitlab-docker.md)  
- [方案四：Docker + Kubernetes](./04-jenkins-gitlab-docker-k8s.md)  
- [方案五：当前项目内 Jenkins 配置](./05-jenkins-project-local.md)  
- 应用机脚本：[`deploy/02-supervisor/`](../deploy/02-supervisor/)  
