# 方案五配置与脚本索引

各方案独立目录，说明见 `docs/`。

| 目录 | 对应方案 | 入口 |
|---|---|---|
| [01-standalone](./01-standalone/) | 独立服务器 | `install-gitlab.sh`；Jenkins 复用 [05 without-docker](./05-project-local/without-docker/)（`install-jenkins.sh` 为包装脚本） |
| [02-supervisor](./02-supervisor/) | Supervisor | `install.sh` / `ctl.sh` |
| [03-docker](./03-docker/) | Docker Compose | `compose.sh up` |
| [04-k8s](./04-k8s/) | Kubernetes | `check-cluster.sh` → `install-jenkins.sh` |
| [05-project-local](./05-project-local/) | 本仓库 CI（web-test） | **有 Docker** `with-docker/up.sh` / **无 Docker** `without-docker/install-*.sh` |

根目录流水线：

- [`Jenkinsfile`](../Jenkinsfile) — 无 Docker（宿主机 JDK8 + Maven）
- [`Jenkinsfile.docker`](../Jenkinsfile.docker) — 有 Docker（Maven 容器 + 应用镜像）
