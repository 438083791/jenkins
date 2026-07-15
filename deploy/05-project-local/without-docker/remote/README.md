# 无 Docker：SSH 部署 web-test 到另一台机器

## 角色说明（重要）

| 角色 | 变量 | 作用 | 默认（本仓库演示） |
|---|---|---|---|
| 运行用户 | `APP_USER` / `APP_RUN_USER` | systemd `User=` 跑 jar | `deploy` |
| 部署用户 | `DEPLOY_USER` | Jenkins SSH / scp / sudo restart | `deploy` |

演示可以把两者都设为 `deploy`。生产建议分离，例如：

```bash
sudo APP_USER=webapp DEPLOY_USER=deploy bash prepare-target.sh
```

不要把旧的 `webtest` 组残留和新的 `deploy` 混用：目录属主、systemd `User=`、Jenkins 参数、SSH 凭据 Username、sudoers 首列必须一致。

## 流程

```text
Jenkins → mvn package → 本机冒烟
  → scp jar（先到 ~deploy/.web-test-deploy）
  → 安装到 /opt/web-test → sudo systemctl restart web-test
  → 远程 curl /hello
```

## 1. 目标机准备（只做一次）

```bash
sudo bash prepare-target.sh
# 或分离用户：
# sudo APP_USER=webapp DEPLOY_USER=deploy bash prepare-target.sh
```

然后为 **`deploy`**（或你设的 `DEPLOY_USER`）配置 SSH 密钥（在目标机执行一次即可）：

```bash
sudo bash setup-deploy-ssh-key.sh
# 用户名不是 deploy 时：
# sudo DEPLOY_USER=你的用户 bash setup-deploy-ssh-key.sh
```

脚本会：生成无口令密钥 → 写入 `~/.ssh/authorized_keys` → **打印私钥**（复制到 Jenkins 凭据，Username 与 `DEPLOY_USER` 一致）。

从本机或 Jenkins 机验证（私钥先落到文件，例如 `/tmp/deploy_key`）：

```bash
chmod 600 /tmp/deploy_key
# accept-new：首次自动写入 known_hosts（避免 Host key verification failed）
ssh -i /tmp/deploy_key -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  deploy@192.168.122.129 'echo ssh_ok'
```

校验：

```bash
id deploy
ls -ld /opt/web-test
systemctl cat web-test | grep -E 'User=|Group='
sudo -n -u deploy systemctl status web-test   # 或 ssh 上去：sudo -n systemctl status web-test
touch /opt/web-test/.w && rm /opt/web-test/.w && echo write_ok
```

放行端口（按实际 APP_PORT，默认 8088）：

```bash
sudo ufw allow 8088/tcp
```

若机器上还留着旧的 `webtest` 用户/组且已不用，可清理（确认无进程后再删）：

```bash
# 可选
sudo systemctl stop web-test || true
# sudo userdel webtest   # 仅当目录已改属主后再删
```

## 2. Jenkins 侧

1. `openssh-client`；流水线用 `withCredentials(sshUserPrivateKey)`，**不必**装 SSH Agent 插件  
2. Credentials → **SSH Username with private key**  
   - ID：`web-test-deploy-ssh`  
   - **Username：`deploy`**  
   - **Private Key**：粘贴目标机上的 `/home/deploy/.ssh/id_ed25519`（或 `id_rsa`）全文  
3. Job 参数：`DEPLOY_USER=deploy`，`APP_RUN_USER=deploy`（与 systemd `User=` 一致）

## 3. 构建参数

| 参数 | 说明 | 示例 |
|---|---|---|
| `DEPLOY_TO_REMOTE` | 是否部署 | `true` |
| `DEPLOY_HOST` | 目标机 | `192.168.122.129` |
| `DEPLOY_USER` | SSH 用户 | `deploy` |
| `APP_RUN_USER` | systemd 运行用户 | `deploy` |
| `DEPLOY_PATH` | 远程目录 | `/opt/web-test` |
| `APP_HTTP_PORT` | 应用端口 | `8088` |
| `SSH_CREDENTIALS_ID` | 凭据 ID | `web-test-deploy-ssh` |

## 4. 本目录文件

| 文件 | 作用 |
|---|---|
| `prepare-target.sh` | 目标机初始化 |
| `setup-deploy-ssh-key.sh` | 为目标 SSH 用户生成密钥并写入 authorized_keys |
| `web-test.service` | systemd 单元（`User=`/`Group=` 由 prepare 写成 APP_USER） |
| `deploy-via-ssh.sh` | Jenkins 调用的部署脚本 |
| `sudoers-web-test.example` | 免密 sudo 模板（首列 DEPLOY_USER） |

## 5. 排错

```bash
sudo systemctl status web-test
sudo journalctl -u web-test -n 80 --no-pager
curl -v http://127.0.0.1:8088/hello
ssh -i /path/to/key deploy@目标机 'id; sudo -n systemctl status web-test'
```
