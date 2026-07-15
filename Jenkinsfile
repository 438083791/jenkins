#!groovy
/**
 * 方案五 · 无 Docker：构建 web-test，并可 SSH 部署到另一台机器
 *
 * 前置：
 * 1. Jenkins 安装插件 ssh-agent；凭据 ID 默认 web-test-deploy-ssh
 * 2. 目标机执行：deploy/05-project-local/without-docker/remote/prepare-target.sh
 * 3. 构建参数 DEPLOY_TO_REMOTE=true 并填写 DEPLOY_HOST
 *
 * 详见：deploy/05-project-local/without-docker/remote/README.md
 */
pipeline {
  agent any
  options {
    timestamps()
    disableConcurrentBuilds()
  }
  tools {
    jdk 'jdk8'
    maven 'maven3'
  }
  parameters {
    booleanParam(name: 'DEPLOY_TO_REMOTE', defaultValue: false, description: '是否 SSH 部署到远程机')
    string(name: 'DEPLOY_HOST', defaultValue: '192.168.122.129', description: '目标机 IP / 主机名')
    string(name: 'DEPLOY_USER', defaultValue: 'user', description: 'SSH 用户（目标机已有用户即可，如 user；需能写 /opt/web-test 且可 sudo restart）')
    string(name: 'DEPLOY_SSH_PORT', defaultValue: '22', description: 'SSH 端口')
    string(name: 'DEPLOY_PATH', defaultValue: '/opt/web-test', description: '远程安装目录')
    string(name: 'APP_HTTP_PORT', defaultValue: '8088', description: '应用 HTTP 端口')
    string(name: 'SSH_CREDENTIALS_ID', defaultValue: 'web-test-deploy-ssh', description: 'Jenkins SSH 私钥凭据 ID')
  }
  environment {
    APP_DIR = 'web-test'
  }
  stages {
    stage('Prepare') {
      steps {
        sh '''
          echo "JAVA_HOME=$JAVA_HOME"
          java -version
          mvn -version || true
          command -v ssh
          command -v scp
          test -f "${APP_DIR}/pom.xml"
        '''
      }
    }
    stage('Test & Package') {
      steps {
        dir("${APP_DIR}") {
          sh '''
            if command -v mvn >/dev/null 2>&1; then
              mvn -B clean package
            elif [ -x ./mvnw ]; then
              ./mvnw -B clean package
            else
              echo "mvn/mvnw not found" >&2
              exit 1
            fi
          '''
        }
      }
      post {
        always {
          junit allowEmptyResults: true, testResults: "${APP_DIR}/target/surefire-reports/*.xml"
          archiveArtifacts artifacts: "${APP_DIR}/target/web-test-*.jar", fingerprint: true, allowEmptyArchive: true
        }
      }
    }
    stage('Smoke jar (local)') {
      steps {
        dir("${APP_DIR}") {
          sh '''
            JAR=$(ls target/web-test-*.jar | grep -v original | head -n1)
            echo "jar=$JAR"
            java -jar "$JAR" --server.port=18080 > /tmp/web-test-ci.log 2>&1 &
            PID=$!
            trap "kill $PID 2>/dev/null || true" EXIT
            for i in $(seq 1 30); do
              if curl -fsS http://127.0.0.1:18080/hello | grep -q hello; then
                echo smoke ok
                exit 0
              fi
              sleep 2
            done
            echo smoke failed >&2
            cat /tmp/web-test-ci.log || true
            exit 1
          '''
        }
      }
    }
    stage('Deploy remote (SSH)') {
      when {
        expression { return params.DEPLOY_TO_REMOTE }
      }
      steps {
        script {
          if (!params.DEPLOY_HOST?.trim()) {
            error 'DEPLOY_TO_REMOTE=true 时必须填写 DEPLOY_HOST'
          }
        }
        dir("${APP_DIR}") {
          sh '''
            JAR=$(ls target/web-test-*.jar | grep -v original | head -n1)
            cp -f "$JAR" /tmp/web-test-deploy.jar
            ls -lh /tmp/web-test-deploy.jar
          '''
        }
        sshagent(credentials: [params.SSH_CREDENTIALS_ID]) {
          sh """
            set -euo pipefail
            export DEPLOY_HOST='${params.DEPLOY_HOST}'
            export DEPLOY_USER='${params.DEPLOY_USER}'
            export DEPLOY_PORT='${params.DEPLOY_SSH_PORT}'
            export DEPLOY_PATH='${params.DEPLOY_PATH}'
            export APP_HTTP_PORT='${params.APP_HTTP_PORT}'
            export JAR_FILE=/tmp/web-test-deploy.jar
            bash deploy/05-project-local/without-docker/remote/deploy-via-ssh.sh
          """
        }
      }
    }
  }
  post {
    always {
      sh 'rm -f /tmp/web-test-deploy.jar || true'
    }
  }
}
