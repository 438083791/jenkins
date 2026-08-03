# 部署脚本索引

说明文档见 `docs/`。

## 三目录职责表（01 / 02 / 05）

| 目录 | 职责 | 用什么装 | 不要用它装 |
|---|---|---|---|
| [`01-standalone`](./01-standalone/) | GitLab 独立机；防火墙等辅助 | **`install-gitlab.sh`** | Jenkins（已改走 05） |
| [`02-supervisor`](./02-supervisor/) | 应用机：Supervisor 管业务进程、上传部署 | **`install.sh`**（+ `deploy-via-ssh.sh`） | GitLab / Jenkins |
| [`05-project-local`](./05-project-local/) | 宿主机 Jenkins（及本仓 CI / 可选 Docker Jenkins） | **`without-docker/install-prereqs.sh` + `install-jenkins.sh`** | GitLab；应用机 Supervisor |

约定：

1. **装 GitLab** → 只用 `01-standalone/install-gitlab.sh`  
2. **装 Jenkins** → 只用 `05-project-local/without-docker/`（`install-prereqs.sh` → `install-jenkins.sh`）  
3. **装 Supervisor / 应用机** → 只用 `02-supervisor/install.sh`  

---

## 各方案入口（含 03 / 04）

| 目录 | 对应方案 | 入口 |
|---|---|---|
| [01-standalone](./01-standalone/) | 独立服务器 | `install-gitlab.sh`；Jenkins 见上表 → 05 |
| [02-supervisor](./02-supervisor/) | GitLab→Jenkins 打包上传→Supervisor 管应用 | 应用机 `install.sh`；Jenkins 用 `deploy-via-ssh.sh` |
| [03-docker](./03-docker/) | Docker Compose：GitLab+Jenkins(JDK21)→构建→Docker 部署 | `compose.sh up`；流水线 `Jenkinsfile.example` |
| [04-k8s](./04-k8s/) | Kubernetes | `install-k8s.sh master` + 两台 `worker`（一主两从）→ `check-cluster.sh` → `install-jenkins.sh` |
| [05-project-local](./05-project-local/) | 本仓库 CI（web-test） | **有 Docker** `with-docker/up.sh` / **无 Docker** `without-docker/install-*.sh` |

根目录流水线：

- [`Jenkinsfile`](../Jenkinsfile) — 无 Docker（宿主机 JDK8 + Maven）
- [`Jenkinsfile.docker`](../Jenkinsfile.docker) — 有 Docker（Maven 容器 + 应用镜像）
