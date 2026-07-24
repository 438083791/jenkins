# 方案五配置索引：面向本仓库 `web-test`（Java 8 + Maven + Spring Boot）

| 子目录 | 环境 | 入口 |
|---|---|---|
| [with-docker](./with-docker/) | 有 Docker | `bash up.sh`，Job 选 `Jenkinsfile.docker` |
| [without-docker](./without-docker/) | 无 Docker | `install-prereqs.sh` → `install-jenkins.sh`，Job 选根目录 `Jenkinsfile` |

说明文档：[`docs/05-jenkins-project-local.md`](../../docs/05-jenkins-project-local.md)  

三目录职责（GitLab / Supervisor / Jenkins）：见 [`deploy/README.md`](../README.md)。
