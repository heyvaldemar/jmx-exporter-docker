# jmx-exporter Docker Image

[![Publish Docker Image](https://github.com/heyvaldemar/jmx-exporter-docker/actions/workflows/publish.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/jmx-exporter-docker/actions/workflows/publish.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/heyvaldemar/jmx-exporter.svg)](https://hub.docker.com/r/heyvaldemar/jmx-exporter)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/jmx-exporter-docker/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/jmx-exporter-docker)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Prometheus's [JMX exporter](https://github.com/prometheus/jmx_exporter), the sidecar Bitnami's Kafka, Tomcat, SonarQube, Dremio and JanusGraph charts run beside a Java server to turn its MBeans into metrics. Built from source, rebuilt every week, signed, and laid out like `bitnami/jmx-exporter`, so those charts run it unchanged.

`bitnami/jmx-exporter` has published one tag since August 2025: `latest`, built on VMware Photon OS 5.0 with Bitnami's FIPS security settings in `JAVA_TOOL_OPTIONS`. The versioned Debian tags stopped at `1.4.0-debian-12-r0` on 2025-08-27 and live on, unmaintained, as `bitnamilegacy/jmx-exporter`, pulled 2.2 million times by 2026-11-01. Bitnami's last published Kafka chart, 32.4.3, still names that tag. The upstream project publishes jars, not an image, and none of the five charts lets you change the command it runs, so an image laid out like Bitnami's is the way off the frozen one short of a forked chart.

```bash
# which commit, Maven and JDK built it, and how many checksums the build checked
docker run --rm --entrypoint cat heyvaldemar/jmx-exporter:1 build.txt

# the exporter, reading a JVM that has remote JMX open on 9010
printf 'hostPort: host.docker.internal:9010\nrules:\n  - pattern: ".*"\n' > jmx.yml
docker run --rm -p 5556:5556 -v "$PWD/jmx.yml:/etc/jmx/jmx.yml:ro" heyvaldemar/jmx-exporter:1 5556 /etc/jmx/jmx.yml
```

In Bitnami's Kafka chart:

```yaml
global:
  security:
    allowInsecureImages: true   # Bitnami's charts refuse images from outside their catalogue without it
metrics:
  jmx:
    enabled: true
    image:
      registry: docker.io
      repository: heyvaldemar/jmx-exporter
      tag: "1.7.0"
```

The other charts take the same `metrics.jmx.image` block.

## Tags

| Tag | What it is | Moves |
|---|---|---|
| `1.7.0` | jmx_exporter 1.7.0 | every week and on every change here, with Debian's security updates; never to another jmx_exporter release |
| `1.7` | the newest 1.7.x | as `1.7.0`, and to the next patch release |
| `1` | the newest 1.x | as `1.7`, and to the next minor release |
| `latest` | the newest release | as `1` |

Every tag moves, so a pinned tag keeps receiving security fixes. For an image that never changes, pin its digest:

```bash
docker buildx imagetools inspect heyvaldemar/jmx-exporter:1.7.0 --format '{{.Manifest.Digest}}'
```

Images are `linux/amd64` and `linux/arm64`, on Debian 13 with Debian's OpenJDK 21 runtime.

## A drop-in for bitnami/jmx-exporter

The charts start the exporter with one command line, `java -XX:MaxRAMPercentage=100 -XshowSettings:vm -jar jmx_prometheus_standalone.jar <port> <config>`, as user 1001 with a read-only root filesystem and every capability dropped. This image keeps what that depends on:

- the user `1001`, and the working directory `/opt/bitnami/jmx-exporter` with `jmx_prometheus_standalone.jar`, `jmx_prometheus_javaagent.jar` and every example configuration Bitnami's image had;
- the entrypoint `java -jar jmx_prometheus_standalone.jar`, the command `5556 examples/standalone_sample_config.yml`, and port 5556 exposed;
- `HOME=/`, and `PATH` with `/opt/bitnami/java/bin` first, where Java is, as it was there;
- the build `SHELL` an image built `FROM` it inherits: bash with `errexit`, `nounset` and `pipefail`.

What is different, on purpose:

- **Java 21 from Debian**, where Bitnami's image carried its own build of Java 17. Debian's package is what lets a Java fix reach this image the week Debian ships it, and what lets Trivy see which Java it is.
- **jmx_exporter 1.7.0**, where the frozen image has 1.4.0.
- **Root owns the jars.** The user the exporter runs as can run them and cannot replace them; in Bitnami's image that user owned them.

**It is checked, not claimed.** Two tests run on every build, and nothing is published unless both pass:

- `tests/drop-in-test.sh` compares the image with the last versioned Bitnami one, `bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0`: the same user, working directory, entrypoint, command, exposed port, build `SHELL`, `HOME` and `PATH`; the same files in the working directory; every executable on its `PATH` on this one's, or a reason in [`tests/drop-in-absent.tsv`](tests/drop-in-absent.tsv) (none of them a tool the charts call: they call `java`). Then both images run with the charts' command line and securityContext against the same Java process, and this one must give every metric name Bitnami's gives; both images' java agents run inside a JVM, and this one must give every `jvm_` metric Bitnami's agent gives.
- `tests/charts-e2e.sh` installs Bitnami's own Kafka chart, 32.4.3, on a fresh kind cluster with this image as its JMX exporter and the chart's own Kafka image. The release must become Ready with the sidecar running this image and never restarted, and the exporter must report one active controller and the three messages the test writes to a topic, read from Kafka's MBeans after they were sent. The same test passes on `bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0`, which is how the test itself was checked.

## CVE counts

The `Publish Docker Image` workflow counts after every publish, on the images it has just published, and keeps the table as a run artifact. The first published images' counts go here with v1.0.0.

## Nothing you used yesterday disappears today

Before anything is published, each build is compared with the image already published under its major tag (`scripts/contract-test.sh`): every executable on its `PATH`, every jar and example configuration, its user, working directory, entrypoint, command, exposed port, build `SHELL`, `HOME` and `PATH`, the jmx_exporter major version, a Java at least as new, and the same Debian release. A removal has to be named in `tests/contract-removed.tsv` and in the changelog.

Each test is shown the breaks it exists for (`tests/plants.tsv`, sixteen of them, run in CI before anything is published): the image running as root, its user able to replace the jars, the working directory moved, the entrypoint naming the jar by its old name, the java agent or the example configurations left out, Java gone from `/opt/bitnami/java` or no longer first on `PATH`, `HOME` moved, the build `SHELL` lost, the port no longer declared, jmx_exporter built from another commit, a Maven artifact with different bytes or no recorded checksum, the build recording checksums instead of checking them, and a jar with a fixed high finding in the image.

## Supply chain

- **jmx_exporter is built from source**, cloned at its release tag and refused unless the tag names the commit pinned in the `Dockerfile`.
- **Every Maven artifact the build resolves**, plugins included, is checked against the SHA-512 recorded in [`maven/`](maven), 783 of them, and the build stops on one that is missing or different. The project's own modules are on that list too: the build is given the tag's commit time as its timestamp, and the same commit, Maven and JDK give the same bytes. The two jars the image ships are the exception by upstream's design: every build relocates their libraries under a random package prefix, so an agent never clashes with the application it is loaded into. `/opt/bitnami/jmx-exporter/build.txt` says which commit, which Maven and which JDK built them, and how many checksums were checked.
- The Maven image (Maven 3.9.16 with Eclipse Temurin 21) and Debian 13 slim, each pinned by digest; Dependabot moves the digests by pull request, gated by the full build and tests. `scripts/record-checksums.sh` records the checksums again when the pin or the Maven image moves, and its diff is read before it is committed.
- Every package brought to the newest version Debian's security archive has at build time, the base's own included.
- jmx_exporter's licence and NOTICE are in `/opt/bitnami/jmx-exporter/licenses`. The `Dockerfile` and the scripts here are MIT; jmx_exporter is Apache-2.0; OpenJDK is Debian's package, GPL-2.0 with the Classpath Exception.
- Every published digest is signed with cosign, keyless, by this repository's workflow, and every tag's signature is verified in the same run; SBOM (SPDX) and SLSA provenance are attached, and build provenance is attested in [GitHub Attestations](https://github.com/heyvaldemar/jmx-exporter-docker/attestations).
- Trivy scans every published image, Debian's packages and the libraries inside the jars, and reports critical and high fixable findings to the Security tab.
- Every GitHub Action is pinned to a commit SHA, except the SLSA generator `release-assets.yml` calls by tag (`@v2.1.0`), because it verifies its own reference at run time and refuses a SHA.

```bash
cosign verify heyvaldemar/jmx-exporter:1.7.0 \
  --certificate-identity-regexp "https://github.com/heyvaldemar/jmx-exporter-docker/.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

## Build it yourself

```bash
docker build -t jmx-exporter:1.7.0 .
./tests/drop-in-test.sh jmx-exporter:1.7.0
./scripts/cve-gate.sh jmx-exporter:1.7.0
./tests/charts-e2e.sh jmx-exporter:1.7.0      # needs kind and helm
```

## Bugs, changes and vulnerabilities

Report a bug or ask for a change in [issues](https://github.com/heyvaldemar/jmx-exporter-docker/issues). Pull requests are welcome: every test above runs on them before anything can merge. Report a vulnerability privately, as [SECURITY.md](SECURITY.md) describes.

## Related

[heyvaldemar/os-shell](https://hub.docker.com/r/heyvaldemar/os-shell) and [heyvaldemar/kubectl](https://hub.docker.com/r/heyvaldemar/kubectl) do the same for `bitnami/os-shell` and `bitnami/kubectl`, the other two helper images Bitnami's charts pull: rebuilt weekly, signed, and checked against the last versioned Bitnami image.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
