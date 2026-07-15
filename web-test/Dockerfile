# web-test Spring Boot 运行镜像（配合方案五 with-docker）
# 构建上下文为本目录，需先 mvn package 生成 jar
FROM eclipse-temurin:8-jre-jammy

WORKDIR /app
# Spring Boot 2.2 / artifactId=web-test
COPY target/web-test-0.0.1-SNAPSHOT.jar /app/app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
