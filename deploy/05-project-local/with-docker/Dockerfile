FROM docker:28-cli AS docker-cli

FROM jenkins/jenkins:2.568.1-lts-jdk21

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd -f docker \
  && usermod -aG docker jenkins
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

USER jenkins

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs
COPY casc/ /usr/share/jenkins/ref/casc_configs/
