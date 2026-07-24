# 方案二：GitLab → Jenkins 打包上传 → Supervisor 管应用

> 详细说明见 [`docs/02-jenkins-gitlab-supervisor.md`](../../docs/02-jenkins-gitlab-supervisor.md)。  
> **Supervisor 托管的是业务应用，不是 Jenkins。**

## 流程

```text
git push → GitLab Webhook → Jenkins（mvn package + scp）
  → 应用机 /opt/web-test/web-test.jar
  → supervisorctl restart web-test
  → 探活 /hello
  → supervisorctl status web-test（Pipeline 自动执行并校验 RUNNING）
```

## 文件

| 文件 | 作用 |
|---|---|
| `install.sh` | 应用机初始化：JDK8、Supervisor、目录、conf、sudoers |
| `start-app.sh` | Supervisor `command`：启动 jar |
| `web-test.conf` | Supervisor program 模板 |
| `ctl.sh` | `supervisorctl` 封装 |
| `deploy-via-ssh.sh` | Jenkins 调用：上传 jar + 重启 program |
| `setup-deploy-ssh-key.sh` | 为部署用户生成 SSH 密钥 |
| `sudoers-web-test.example` | 免密 `supervisorctl` / 安装 jar |
| `Jenkinsfile.example` | Pipeline 示例 |
| `env.example` | 环境变量参考 |

## 应用机（一次）

```bash
sudo bash install.sh
sudo bash setup-deploy-ssh-key.sh
```

## Jenkins

1. 导入 SSH 私钥凭据 `web-test-deploy-ssh`  
2. Job 使用 `Jenkinsfile.example`（或独立仓拷贝后改路径）  
3. GitLab Webhook 指向该 Job  

## 运维

```bash
bash ctl.sh status
bash ctl.sh restart
bash ctl.sh logs
```
