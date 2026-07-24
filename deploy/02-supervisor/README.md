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
| `install.sh` | 应用机初始化：JDK8、Supervisor、目录、conf、sudoers、Web UI |
| `start-app.sh` | Supervisor `command`：启动 jar |
| `web-test.conf` | Supervisor program 模板 |
| `inet-http-server.conf` | Supervisor Web UI（默认 `9001`） |
| `ctl.sh` | `supervisorctl` 封装 |
| `deploy-via-ssh.sh` | Jenkins 调用：上传 jar + 重启 program |
| `setup-deploy-ssh-key.sh` | 为部署用户生成 SSH 密钥 |
| `sudoers-web-test.example` | 免密 `supervisorctl` / 安装 jar |
| `Jenkinsfile.example` | Pipeline 示例 |
| `env.example` | 环境变量参考 |

## 应用机（一次 / 可重复执行）

```bash
sudo bash install.sh
sudo bash setup-deploy-ssh-key.sh
```

已装过的机器要启用 UI，再执行一次 `install.sh` 即可（或只更新 UI 配置后 `systemctl restart supervisor`）。

### Supervisor Web UI

| 项 | 默认 |
|---|---|
| 地址 | `http://<应用机>:9001/` |
| 用户 / 密码 | `admin` / `admin` |
| 关闭 UI | `sudo ENABLE_SUPERVISOR_UI=0 bash install.sh` |
| 改端口/密码 | `sudo SUPERVISOR_HTTP_PORT=9001 SUPERVISOR_HTTP_PASSWORD='强密码' bash install.sh` |

```bash
sudo ufw allow 9001/tcp
```

## Jenkins

1. 导入 SSH 私钥凭据 `web-test-deploy-ssh`  
2. Job 使用 `Jenkinsfile.example`（或独立仓拷贝后改路径）  
3. GitLab Webhook 指向该 Job  

## 运维

```bash
bash ctl.sh status
bash ctl.sh restart
bash ctl.sh logs          # 实时跟踪
bash ctl.sh last 2000000  # supervisorctl：最近约 2MB（注意是字节）
bash ctl.sh file 2000     # 推荐：直接读文件最后 2000 行，最全
```

### 日志看不全时

| 方式 | 说明 |
|---|---|
| Web UI 页面 | 内置只拉一小段，**没法靠配置大幅加长**，只适合扫一眼 |
| `supervisorctl tail -N` | `N` 是**字节**不是行，例：`supervisorctl tail -500000 web-test` |
| 直接读文件（推荐） | `tail -n 2000 /opt/app-logs/web-test.out.log` |
| 保留更久 | 调大 `stdout_logfile_maxbytes` / `stdout_logfile_backups`（`web-test.conf`），再 `install.sh` 或 `reread && update` |

当前模板默认：单文件约 **200MB** × **20** 个备份。
