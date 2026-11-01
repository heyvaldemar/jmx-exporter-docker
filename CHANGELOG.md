# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The images are tagged by jmx_exporter release; these versions describe the
image and the pipeline that builds it.

## [Unreleased]

### Added

- **heyvaldemar/jmx-exporter: Prometheus's JMX exporter 1.7.0 on Debian 13 and Debian's OpenJDK 21, rebuilt every week.** Tags `1.7.0`, `1.7`, `1` and `latest`; `linux/amd64` and `linux/arm64`. `bitnami/jmx-exporter` has published only `latest` since August 2025, built on Photon OS, and its versioned tags stopped at `1.4.0-debian-12-r0`.
- **A drop-in for bitnami/jmx-exporter, checked on every build** against `bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0`: user `1001`, the working directory `/opt/bitnami/jmx-exporter` with both jars and every example configuration, the same entrypoint, command, exposed port, `PATH`, `HOME` and build `SHELL`, Java at `/opt/bitnami/java`, every executable on its `PATH` or a reason in `tests/drop-in-absent.tsv`, and both images run with the charts' command line and securityContext against the same Java process, giving the same metric names.
- **Bitnami's own Kafka chart on kind**: its JMX exporter sidecar runs this image and reports the messages written to a topic before anything is published.
- **jmx_exporter built from source** at the commit its release tag names, with every Maven artifact the build resolves checked against a recorded SHA-512 (`maven/`).
- **No fixable critical or high finding**: `scripts/cve-gate.sh` refuses an image that carries one, in Debian's packages or in the libraries inside the jars.
- **A contract with the published image**: nothing a chart used under a tag disappears from it without a line in `tests/contract-removed.tsv`.
- **Every digest signed** with cosign, keyless, and every tag's signature verified after signing; SBOM, SLSA provenance and a GitHub build attestation; Trivy on the published image; CVE counts against the images it replaces after every publish.
- **Every test shown the breaks it exists for**: sixteen planted violations in `tests/plants.tsv`, run in CI before anything is published.

[Unreleased]: https://github.com/heyvaldemar/jmx-exporter-docker/commits/main
