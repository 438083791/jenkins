# 同时安装 JDK 21（Jenkins）与 JDK 8（web-test）说明

> **重要**：现行 Jenkins LTS / weekly 的 Controller **最低要求 Java 21**（也支持 25）。Java 17 **不能再用来启动**新下载的 `jenkins.war`。  
> 示例应用 [`web-test`](../web-test/) 仍需要 **JDK 8**。二者装在同一台虚拟机上即可。

> 旧标题曾写「JDK 17」；现已改为 **默认 = JDK 21**。若仍看到 Java 17 报错，请按本文升级。

当前环境以 **Ubuntu（含 25.x）虚拟机** 为主。

---

## 1. 版本分工

| 用途 | 推荐 JDK | 说明 |
|---|---|---|
| 运行 Jenkins Controller | **21**（或 25） | `jenkins.war` 启动必备 |
| 编译 / 测试 `web-test` | **8** | `java.version=1.8` |
| 系统默认 `java` | **21** | 避免误用 8/17 启动 Jenkins |

原则：**默认 JDK = 21**；构建 `web-test` 时再显式切到 JDK 8。

---

## 2. Ubuntu：安装 JDK 21 + JDK 8

```bash
sudo apt-get update
sudo apt-get install -y openjdk-21-jdk openjdk-8-jdk
```

若 OpenJDK 8 装不上，见下文 Temurin；**Jenkins 务必先有 21**。

```bash
update-java-alternatives -l
ls -l /usr/lib/jvm/
```

| 版本 | 典型路径（amd64） |
|---|---|
| JDK 8 | `/usr/lib/jvm/java-8-openjdk-amd64` |
| JDK 21 | `/usr/lib/jvm/java-21-openjdk-amd64` |

### 2.1 设 JDK 21 为系统默认

```bash
sudo bash deploy/05-project-local/without-docker/set-default-jdk21.sh
# 或：
sudo update-java-alternatives --set java-1.21.0-openjdk-amd64
```

验收：

```bash
java -version
# 应类似：openjdk version "21.x.x"
```

---

## 3. 你当前报错的含义

```text
Running with Java 17 ... older than the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```

说明 war 是新版本 Jenkins，**必须换用 JDK 21 再启动**。

虚拟机快速修复：

```bash
sudo apt-get update
sudo apt-get install -y openjdk-21-jdk
update-java-alternatives -l
sudo update-java-alternatives --set java-1.21.0-openjdk-amd64
# 名称以 -l 列表第一列为准

java -version   # 必须是 21.x

# 改掉写死 17 的配置
sudo sed -i 's|java-17-openjdk-amd64|java-21-openjdk-amd64|g' \
  /etc/systemd/system/jenkins-local.service \
  /opt/ci/jenkins/start-jenkins.sh

# 或直接改 start 脚本让它用 PATH 里的 java（已是 21）
sudo tee /opt/ci/jenkins/start-jenkins.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export JENKINS_HOME="${JENKINS_HOME:-/opt/ci/jenkins/home}"
WAR="${JENKINS_WAR:-/opt/ci/jenkins/jenkins.war}"
HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
JAVA_BIN="/usr/lib/jvm/java-21-openjdk-amd64/bin/java"
test -x "$JAVA_BIN"
test -f "$WAR"
mkdir -p "$JENKINS_HOME"
cd "$JENKINS_HOME"
exec "$JAVA_BIN" -Xms256m -Xmx1024m -jar "$WAR" --httpPort="$HTTP_PORT" --httpListenAddress=0.0.0.0
EOF
sudo chmod 755 /opt/ci/jenkins/start-jenkins.sh
sudo chown jenkins:jenkins /opt/ci/jenkins/start-jenkins.sh

sudo systemctl daemon-reload
sudo systemctl restart jenkins-local
sleep 20
systemctl status jenkins-local --no-pager
sudo cat /opt/ci/jenkins/home/secrets/initialAdminPassword
```

---

## 4. 无 OpenJDK 8 时（Temurin）

```bash
sudo apt-get install -y wget apt-transport-https gnupg
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | sudo gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/adoptium.list
sudo apt-get update
sudo apt-get install -y temurin-8-jdk temurin-21-jdk
```

---

## 5. 构建 web-test 时切到 JDK 8

```bash
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
java -version   # 1.8.0_x
cd web-test && mvn -B clean package
```

Jenkins Pipeline 用 `tools { jdk 'jdk8' }`；**Controller 进程保持 21**。

---

## 6. 本仓库脚本

| 脚本 | 作用 |
|---|---|
| `without-docker/install-prereqs.sh` | 装 JDK8 + JDK21，默认 21 |
| `without-docker/set-default-jdk21.sh` | 只设默认 21 |
| `without-docker/start-jenkins.sh` | 优先 Java 21，低于 21 拒绝启动 |

---

## 7. 验收清单

- [ ] `java -version` 为 **21.x**  
- [ ] JDK 8 路径可用  
- [ ] `jenkins-local` 为 `active (running)`  
- [ ] 能读取 `initialAdminPassword`  

---

## 8. 相关文档

- [方案五：有 Docker / 无 Docker](./05-jenkins-project-local.md)  
- [方案一：独立服务器](./01-jenkins-gitlab-standalone.md)  
