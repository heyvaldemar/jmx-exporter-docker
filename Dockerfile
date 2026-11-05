# syntax=docker/dockerfile:1.7

# ──────────────────────────────────────────────────────────────────────────────
# heyvaldemar/jmx-exporter: Prometheus's JMX exporter, the sidecar Bitnami's
# Kafka, Tomcat, SonarQube, Dremio and JanusGraph charts run beside a Java
# server to turn its MBeans into metrics. Rebuilt every week, signed, and laid
# out like bitnami/jmx-exporter, so those charts run it unchanged: they start
# `java -jar jmx_prometheus_standalone.jar <port> <config>` in the working
# directory /opt/bitnami/jmx-exporter as user 1001, and give no way to change
# that command.
#
# The upstream project publishes jars, not an image.
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: the two jars, built from source. jmx_exporter is cloned at its
# release tag and refused unless the tag names the commit pinned here. Maven
# then checks every artifact it resolves, plugins included, against the
# SHA-512 recorded in maven/checksums-*.sha512, and stops on one that is
# missing or different: the role go.sum plays for a Go build. The project's
# own modules are on that list too, which works because the build is given
# the tag's commit time as its timestamp: the same commit, the same Maven and
# the same JDK give the same bytes. The two jars the image ships are the
# exception by upstream's design: each build relocates their libraries under
# a random package prefix, so an agent never clashes with the application it
# is loaded into.
#
# Maven and the JDK come from one image pinned by digest, so the build does
# not change under a weekly rebuild; Dependabot moves the digest by pull
# request, and the recorded checksums decide whether it merges. Bytecode is
# the same on every architecture, so this stage runs once, on the build
# platform. scripts/record-checksums.sh records the checksums again after a
# version bump (MAVEN_CHECKSUMS=record).
# ──────────────────────────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM maven:3.9.16-eclipse-temurin-21@sha256:99e61abcff91a9b1333463bd8451fb18495d6eba9250ac66a338b518f8278320 AS build

ARG JMX_EXPORTER=1.7.0:dc8a5741dc449e7a8a98bc153d702c456cf7b5f7
ARG MAVEN_CHECKSUMS=verify

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY maven/ /maven/

WORKDIR /src

RUN set -euo pipefail; \
    tag="${JMX_EXPORTER%%:*}"; sha="${JMX_EXPORTER#*:}"; \
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/prometheus/jmx_exporter.git jmx; \
    [ "$(git -C jmx rev-parse HEAD)" = "$sha" ] || { echo "prometheus/jmx_exporter ${tag} is not commit ${sha}" >&2; exit 1; }; \
    case "$MAVEN_CHECKSUMS" in \
      verify) checksums=(-Daether.artifactResolver.postProcessor.trustedChecksums.failIfMissing=true -Daether.trustedChecksumsSource.summaryFile.basedir=/maven) ;; \
      record) checksums=(-Daether.artifactResolver.postProcessor.trustedChecksums.record=true -Daether.trustedChecksumsSource.summaryFile.basedir=/out/checksums) ;; \
      *) echo "MAVEN_CHECKSUMS is verify or record, not '${MAVEN_CHECKSUMS}'" >&2; exit 1 ;; \
    esac; \
    mvn -f jmx/pom.xml -B -ntp -DskipTests -Dmaven.javadoc.skip=true -Dmaven.repo.local=/tmp/m2 \
      -Dproject.build.outputTimestamp="$(date -u -d "@$(git -C jmx log -1 --format=%ct)" +%Y-%m-%dT%H:%M:%SZ)" \
      -Daether.artifactResolver.postProcessor.trustedChecksums=true \
      -Daether.artifactResolver.postProcessor.trustedChecksums.checksumAlgorithms=SHA-512 \
      -Daether.trustedChecksumsSource.summaryFile=true \
      "${checksums[@]}" \
      -pl jmx_prometheus_standalone,jmx_prometheus_javaagent -am package; \
    mkdir -p /out/licenses; \
    cp "jmx/jmx_prometheus_standalone/target/jmx_prometheus_standalone-${tag}.jar" /out/jmx_prometheus_standalone.jar; \
    cp "jmx/jmx_prometheus_javaagent/target/jmx_prometheus_javaagent-${tag}.jar" /out/jmx_prometheus_javaagent.jar; \
    cp -r jmx/examples /out/examples; \
    cp jmx/LICENSE "/out/licenses/jmx-exporter-${tag}.txt"; \
    cp jmx/NOTICE "/out/licenses/jmx-exporter-${tag}-NOTICE.txt"; \
    if [ "$MAVEN_CHECKSUMS" = verify ]; then \
      checked="every Maven artifact checked against $(cat /maven/checksums-*.sha512 | grep -c .) recorded SHA-512 checksums"; \
    else \
      checked="Maven artifacts recorded, NOT checked"; \
    fi; \
    printf 'jmx_exporter %s %s\nbuilt with %s on %s\n%s\n' "$tag" "$sha" \
      "$(mvn -v | sed -n '1s/ (.*//p')" "$(java -version 2>&1 | sed -n '2p')" "$checked" > /out/build.txt; \
    cat /out/build.txt

# What scripts/record-checksums.sh exports: the checksums a record build wrote.
FROM scratch AS checksums
COPY --from=build /out/checksums/ /

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2: the image. Debian 13 and Debian's OpenJDK 21 runtime, so a Java
# fix reaches this image the week Debian publishes it, the same way every
# other package's does, and Trivy can see which Java it is.
# ──────────────────────────────────────────────────────────────────────────────
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS final

ARG TARGETARCH
ARG JMX_EXPORTER=1.7.0:dc8a5741dc449e7a8a98bc153d702c456cf7b5f7
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Every package is brought to the newest version the suite's security archive
# has at build time, the base's own included: the weekly rebuild is how a fix
# Debian has published reaches this image, and scripts/cve-gate.sh refuses to
# publish one that still carries a fixed critical or high finding. The man
# directory exists only because the JRE's install script links its manual
# pages there and stops if it cannot; slim images ship none.
#
# JAVA, WHERE BITNAMI'S WAS. bitnami/jmx-exporter carried its own Java under
# /opt/bitnami/java, first on PATH. Here that path is a link to Debian's, so
# the PATH is the same and a script that calls /opt/bitnami/java/bin/java by
# its full path still finds it.
# hadolint ignore=DL3008
RUN mkdir -p /usr/share/man/man1 \
 && apt-get update \
 && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends ca-certificates openjdk-21-jre-headless procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/bitnami \
 && ln -s "/usr/lib/jvm/java-21-openjdk-${TARGETARCH}" /opt/bitnami/java \
 && java -version

# Owned by root and readable by everyone: the exporter's own user can run the
# jars and cannot replace them.
COPY --from=build /out/jmx_prometheus_standalone.jar /out/jmx_prometheus_javaagent.jar /opt/bitnami/jmx-exporter/
COPY --from=build /out/examples/ /opt/bitnami/jmx-exporter/examples/
COPY --from=build /out/licenses/ /opt/bitnami/jmx-exporter/licenses/
COPY --from=build /out/build.txt /opt/bitnami/jmx-exporter/build.txt

ENV HOME=/ \
    PATH=/opt/bitnami/java/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    OS_ARCH=${TARGETARCH} \
    OS_FLAVOUR=debian-13 \
    OS_NAME=linux \
    APP_VERSION=${JMX_EXPORTER%%:*} \
    BITNAMI_APP_NAME=jmx-exporter

LABEL org.opencontainers.image.title="jmx-exporter" \
      org.opencontainers.image.description="Prometheus's JMX exporter on Debian 13, built from source, rebuilt weekly, signed; a drop-in for bitnami/jmx-exporter." \
      org.opencontainers.image.authors="Vladimir Mikhalev <v@valdemar.ai>" \
      org.opencontainers.image.vendor="heyvaldemar" \
      org.opencontainers.image.source="https://github.com/heyvaldemar/jmx-exporter-docker" \
      org.opencontainers.image.documentation="https://github.com/heyvaldemar/jmx-exporter-docker#readme" \
      org.opencontainers.image.url="https://hub.docker.com/r/heyvaldemar/jmx-exporter" \
      org.opencontainers.image.licenses="MIT AND Apache-2.0" \
      org.opencontainers.image.version="${JMX_EXPORTER%%:*}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# What an image built FROM this one inherits for its RUN lines, as
# bitnami/jmx-exporter set it: a failing command, an unset variable or a
# failing pipe stops the build.
SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]

WORKDIR /opt/bitnami/jmx-exporter
EXPOSE 5556
USER 1001
ENTRYPOINT ["java", "-jar", "jmx_prometheus_standalone.jar"]
CMD ["5556", "examples/standalone_sample_config.yml"]
