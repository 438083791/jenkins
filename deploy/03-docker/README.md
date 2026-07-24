# 方案三：GitLab + Jenkins（JDK21）Compose，Webhook → 构建 → Docker 部署

> 详细说明见 [`docs/03-jenkins-gitlab-docker.md`](../../docs/03-jenkins-gitlab-docker.md)。

## 标准流程

```text
Compose 安装 GitLab + Jenkins（JDK21）
  → 配置 GitLab Webhook + Jenkins Pipeline（GitLab 仓库路径）
  → 用户 git push
  → GitLab 通知 Jenkins
  → Jenkins：mvn package → docker build → docker run 部署
```

## 快速启动

```bash
cd deploy/03-docker
cp .env.example .env
bash compose.sh up
bash compose.sh passwords
```

- Jenkins：`http://localhost:8080`（镜像 `jenkins/jenkins:*-lts-jdk21`，与方案五一致）  
- GitLab：`http://localhost`（或 `.env` 中端口 / hostname）  
- 应用部署后探活：`http://localhost:8088/hello`  

## 文件

| 文件 | 作用 |
|---|---|
| `compose.sh` | up/down/日志/密码；探测 `DOCKER_GID` |
| `docker-compose.yml` | GitLab + Jenkins；挂载 `docker.sock` |
| `jenkins/Dockerfile` | JDK21 Jenkins + docker CLI + 插件 |
| `Jenkinsfile.example` | 打包 → 镜像 → 冒烟 → 常驻部署 |

## Job 提示

1. Pipeline from SCM → Script Path：`deploy/03-docker/Jenkinsfile.example`  
2. GitLab Webhook（容器互通）：`http://jenkins:8080/project/<job>`  
3. SCM URL（容器互通）：`http://gitlab/<group>/<project>.git`  
