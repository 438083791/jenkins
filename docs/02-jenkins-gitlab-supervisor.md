# 方案二：Jenkins + GitLab + Supervisor 部署

> **目标**：在保留「可观察进程模型」的前提下，引入 [Supervisor](http://supervisord.org/) 统一托管 Jenkins（及可选辅助进程），实现异常退出自动拉起、统一日志与启停规范；GitLab 仍可用 Omnibus 自管，或将部分 sidecar（如 webhook 转发、备份脚本）交由 Supervisor。

---

## 1. 方案概述

| 项 | 说明 |
|---|---|
| 适用场景 | 学习进程守护；中小规模、暂未上 Docker 的机房/虚机环境 |
| 相对方案一 | 增加进程监督层，强化「自愈 + 日志汇聚 + 统一运维入口」 |
| 典型拓扑 | 服务器 A：GitLab（Omnibus）；服务器 B：Jenkins（由 Supervisor 拉起） |
| 可选增强 | 同机再用 Supervisor 管 `nginx` 反代、备份脚本、简单 Agent |
| **配置目录** | [`deploy/02-supervisor/`](../deploy/02-supervisor/) |

**定位澄清**：GitLab Omnibus 自带 runit，一般 **不必** 再用 Supervisor 包一层 GitLab；本方案重点把 **Jenkins 及周边自研进程** 纳入 Supervisor。

---

## 2. 架构图

```text
┌──────────────────────┐                      ┌─────────────────────────────────┐
│  服务器 A：GitLab    │      Webhook/API     │  服务器 B                        │
│  (Omnibus + runit)   │ ───────────────────► │  Supervisor (supervisord)        │
│                      │                      │    ├─ program: jenkins          │
│  Git 仓库 / Token    │ ◄──── clone/ssh ──── │    ├─ program: nginx (可选)     │
└──────────────────────┘                      │    └─ program: backup (可选)    │
                                              │           │                     │
                                              │           ▼                     │
                                              │     JENKINS_HOME / 日志目录      │
                                              └─────────────────────────────────┘
```

---

## 3. 为什么加 Supervisor？

| 能力 | systemd  alone | + Supervisor |
|---|---|---|
| 崩溃自动重启 | 可以 | 可以，配置更细（次数、间隔、backoff） |
| 多自研程序统一管理 | 每个写一个 unit | 一个 conf 目录集中管理 |
| 日志 | journald | 可指定 stdout/stderr 文件，易按任务切割 |
| 非 root 用户启停 | 需 polkit / sudo | `supervisorctl` 权限模型清晰 |
| 学习成本 | 偏低 | 进程管理通用技能（许多历史 Python/Java 服务仍在用） |

与方案一对比：方案一用 `systemctl` 管官方 `jenkins` 包；本方案改为 **Supervisor 直接 `java -jar jenkins.war`**（或包装脚本），便于看清 JVM 启动参数与工作目录。

---

## 4. 环境准备

| 组件 | 建议 |
|---|---|
| OS | Ubuntu 22.04 LTS |
| Python / Supervisor | `supervisor` 包（或 pip 安装 supervisord ≥ 4.x） |
| JDK | OpenJDK 17 |
| Jenkins | 官方 `jenkins.war`（LTS） |
| GitLab | 同方案一，Omnibus CE |

目录规划（服务器 B）：

```text
/opt/ci/
├── jenkins/
│   ├── jenkins.war
│   ├── start-jenkins.sh
│   └── home/                 # JENKINS_HOME
├── logs/
│   ├── jenkins.out.log
│   └── jenkins.err.log
└── supervisor/
    └── jenkins.conf          # 可 symlink 到 /etc/supervisor/conf.d/
```

---

## 5. GitLab 侧（复用方案一）

部署步骤与目录含义见 [方案一](./01-jenkins-gitlab-standalone.md) 第 4 节。本方案不改 GitLab 进程模型，仅保证：

1. Webhook 能打到 Jenkins（经 Nginx 反代或直连 Supervisor 暴露端口）  
2. Token / Deploy Key 已为 Jenkins 准备好  

若需将 **自定义 webhook 转发脚本**、**定时 `gitlab-backup` 包装脚本** 纳入 Supervisor，见第 8 节示例。

---

## 6. Jenkins + Supervisor 部署步骤

### 6.1 安装依赖

```bash
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk git curl supervisor
sudo id -u jenkins >/dev/null 2>&1 || sudo useradd -r -m -d /opt/ci/jenkins/home -s /bin/bash jenkins
sudo mkdir -p /opt/ci/jenkins /opt/ci/logs
sudo chown -R jenkins:jenkins /opt/ci
```

### 6.2 下载 Jenkins WAR

```bash
sudo -u jenkins curl -L -o /opt/ci/jenkins/jenkins.war \
  https://get.jenkins.io/war-stable/latest/jenkins.war
```

### 6.3 启动脚本

`/opt/ci/jenkins/start-jenkins.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
export JENKINS_HOME=/opt/ci/jenkins/home
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
exec "${JAVA_HOME}/bin/java" \
  -Xms512m -Xmx1024m \
  -Dhudson.lifecycle=hudson.lifecycle.ExitLifecycle \
  -jar /opt/ci/jenkins/jenkins.war \
  --httpPort=8080 \
  --httpListenAddress=0.0.0.0
```

```bash
sudo chmod +x /opt/ci/jenkins/start-jenkins.sh
sudo chown jenkins:jenkins /opt/ci/jenkins/start-jenkins.sh
```

> `ExitLifecycle`：方便通过退出码让 Supervisor 判定并重启；生产可按团队规范调整。

### 6.4 Supervisor 程序配置

`/etc/supervisor/conf.d/jenkins.conf`：

```ini
[program:jenkins]
command=/opt/ci/jenkins/start-jenkins.sh
directory=/opt/ci/jenkins/home
user=jenkins
autostart=true
autorestart=true
startsecs=10
startretries=3
stopwaitsecs=60
stopsignal=TERM
redirect_stderr=false
stdout_logfile=/opt/ci/logs/jenkins.out.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=10
stderr_logfile=/opt/ci/logs/jenkins.err.log
stderr_logfile_maxbytes=50MB
stderr_logfile_backups=10
environment=JENKINS_HOME="/opt/ci/jenkins/home",LANG="en_US.UTF-8"
```

加载并启动：

```bash
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl status jenkins
sudo supervisorctl tail -f jenkins
```

浏览器访问 `http://<jenkins-host>:8080`，初始密码仍在：

```text
$JENKINS_HOME/secrets/initialAdminPassword
```

即 `/opt/ci/jenkins/home/secrets/initialAdminPassword`。

---

## 7. 常用运维命令

```bash
# 状态 / 启停 / 重启
sudo supervisorctl status
sudo supervisorctl stop jenkins
sudo supervisorctl start jenkins
sudo supervisorctl restart jenkins

# 看日志
sudo supervisorctl tail -f jenkins stdout
sudo supervisorctl tail -f jenkins stderr

# 配置变更后
sudo supervisorctl reread && sudo supervisorctl update
```

与方案一对照学习：

| 操作 | 方案一（systemd 包） | 本方案（Supervisor） |
|---|---|---|
| 改端口 / 堆内存 | `/etc/default/jenkins` | `start-jenkins.sh` + conf `environment` |
| 看主目录 | `/var/lib/jenkins` | `/opt/ci/jenkins/home` |
| 查进程 | `systemctl status jenkins` | `supervisorctl status` + `ps` |

`JENKINS_HOME` 内部结构不变，目录含义仍按方案一第 5.2 节理解。

---

## 8. 可选：同机辅助进程

### 8.1 Nginx 反代（HTTPS 终结）

```ini
[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=10
stdout_logfile=/opt/ci/logs/nginx.out.log
stderr_logfile=/opt/ci/logs/nginx.err.log
```

### 8.2 GitLab 备份包装（跑在 GitLab 机）

```ini
[program:gitlab-backup-loop]
command=/usr/local/bin/gitlab-backup-loop.sh
autostart=true
autorestart=true
user=root
stdout_logfile=/var/log/gitlab-backup-loop.out.log
stderr_logfile=/var/log/gitlab-backup-loop.err.log
```

脚本内可用 `sleep` 循环或交给 `cron`；若任务纯定时，更推荐 **cron + 一次性命令**，Supervisor 适合「常驻进程」。

### 8.3 轻量 Agent

在 Agent 机用 Supervisor 拉起 JNLP / Inbound Agent：

```ini
[program:jenkins-agent]
command=java -jar /opt/ci/agent/agent.jar -url http://jenkins:8080 -secret <SECRET> -name agent-1 -workDir /opt/ci/agent/work
user=jenkins
autostart=true
autorestart=true
stdout_logfile=/opt/ci/logs/agent.out.log
stderr_logfile=/opt/ci/logs/agent.err.log
```

---

## 9. GitLab ↔ Jenkins 联调

联调步骤与 Webhook / Pipeline 示例与 [方案一第 6 节](./01-jenkins-gitlab-standalone.md) 相同。注意：

1. 若 Jenkins 只监听内网，GitLab Webhook URL 填内网可达地址  
2. 若走 Nginx HTTPS，Webhook 使用 `https://ci.example.com/project/<job>`  
3. 防火墙放行 Supervisor 对外服务端口（或仅放行 Nginx 的 443）

---

## 10. 升级与备份建议

**Jenkins 升级**

1. `supervisorctl stop jenkins`  
2. 备份整个 `/opt/ci/jenkins/home`  
3. 替换 `jenkins.war`  
4. `supervisorctl start jenkins`  
5. 观察日志与插件兼容性  

**备份清单**

- `/opt/ci/jenkins/home`（配置、Job、插件、密钥）  
- `/etc/supervisor/conf.d/*.conf`  
- GitLab：`gitlab-backup create` + `/etc/gitlab/gitlab.rb`  

---

## 11. 优缺点与边界

**优点**

- 比纯 systemd 包安装更易自定义 JVM 与目录布局  
- 统一管理多辅助进程，适合「半自动化」机房  
- 仍可完整观察 `JENKINS_HOME`，学习价值不丢失  

**缺点**

- 未解决依赖隔离与「镜像级」复现问题  
- Supervisor 不管容器网络 / 存储编排  
- GitLab Omnibus 与 Supervisor 两套进程世界观并存，需文档说清边界  

**何时升级到方案三**：出现「多环境一致交付」「一键拉起」「工具链污染」痛点时。

---

## 12. 验收清单

- [ ] `supervisorctl status jenkins` 为 RUNNING  
- [ ] 杀掉 `java ... jenkins.war` 进程后，约数秒内被自动拉起  
- [ ] 日志写入 `/opt/ci/logs/`，可 `tail`  
- [ ] GitLab Push 能触发 Jenkins 构建  
- [ ] 能说清：Omnibus(runit) vs Supervisor 各自管什么  
- [ ] 完成一次 `jenkins.war` 替换升级演练  

---

## 13. 相关文档

- [方案一：独立服务器部署（结构深挖）](./01-jenkins-gitlab-standalone.md)  
- [方案三：Docker 部署](./03-jenkins-gitlab-docker.md)  
- [方案四：Docker + Kubernetes](./04-jenkins-gitlab-docker-k8s.md)  
- [方案五：当前项目内 Jenkins 配置](./05-jenkins-project-local.md)  
