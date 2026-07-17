# web-test · 独立 GitLab 仓的 Jenkins 流水线

本目录可单独作为 Git 仓库推送到 GitLab（根目录含 `pom.xml`）。

| 文件 | 适用环境 | Jenkins Script Path |
|---|---|---|
| [`Jenkinsfile`](./Jenkinsfile) | 无 Docker（宿主机 JDK8 + Maven） | `Jenkinsfile` |
| [`Jenkinsfile.docker`](./Jenkinsfile.docker) | 有 Docker（Maven 容器 + 镜像构建） | `Jenkinsfile.docker` |

与教学仓根目录流水线的区别：这里 `APP_DIR = '.'`（应用在仓库根），不再假定子目录 `web-test/`。

## Job 配置示例

1. New Item → Pipeline  
2. Definition: **Pipeline script from SCM**  
3. Git → 你的独立 GitLab 仓库 URL + 凭据  
4. Branch：`*/main`（或实际分支）  
5. Script Path：按上表二选一  

可选远程部署（仅 `Jenkinsfile`）：构建参数勾选 `DEPLOY_TO_REMOTE`，并配置凭据 `web-test-deploy-ssh`；脚本见 [`ci/deploy-via-ssh.sh`](./ci/deploy-via-ssh.sh)。
