# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The images are tagged by jmx_exporter release; these versions describe the
image and the pipeline that builds it.

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.2] - 2026-11-15

### Added

- **Every tag a run pushes is read back from Docker Hub after signing.** For each one the run resolves the digest the tag names now, and requires that digest's cosign signature (`sha256-<digest>.sig`, HTTP 200) and a `cosign verify` that passes: for the digest this run pushed, as this run's exact workflow identity and commit; for a digest another run has moved the tag to since, as this repository's publish workflow on any ref. A missing signature fails the job. A digest this run built is then signed again; a digest it did not build never is. It also runs after a push refused half way: the build reports no digest then, so the tags it had already moved are reported and fail the job, but are not signed. What it found goes to the run summary (`scripts/verify-published.sh`).
- **The signing steps are shown each failure they exist for, before anything is published.** Signing, attesting and reading back are one action, `.github/actions/sign-attest-verify`, the same as in heyvaldemar/aws-kubectl-docker 2.3.1. The build job runs it after its push, and a new `signing` job runs it six times on throwaway images in a registry on the runner, signed with keys made there. The cases: nothing planted; the real attestation step failing (the job has no OIDC token, so the step fails before it contacts anything; the image is signed before the failure, and the job still fails); signing failing; signing skipped without an error, where the read-back alone fails the job and signs the digest; a tag another run moved to an image signed by a stranger's key (the job fails, and that image is left as it is); and a push that stopped half way (the job fails, nothing is signed). Nothing reaches Docker Hub, GitHub's attestation store or Sigstore's public log. The build waits for it, and so does the required check.

### Changed

- **`SECURITY.md` and the image's `org.opencontainers.image.authors` label give the public contact address**, and `SECURITY.md` links GitHub's form for a private vulnerability report directly. The label reaches the published images with the next weekly rebuild; nothing else in them changes.

### Fixed

- **Signing no longer depends on the build attestation.** The cosign steps came after `actions/attest-build-provenance` and ran only if it succeeded: the order in which heyvaldemar/aws-kubectl-docker shipped an unsigned image on 2 November 2026, when Rekor, Sigstore's transparency log, answered its attestation 502 and three of its tags named that image for 37 hours. No run here hit it. The pushed digest is now signed first, then attested; a failed attestation still fails the job, after the signature exists. It is signed once, not once per tag (the signature belongs to the digest either way), and a failed attempt is tried again twice. The step that verified every tag's signature came after signing with the same condition, so it would have been skipped too; the read-back below replaces it.
- **The daily pin check no longer reports an index pushed again over the same builds as drift.** `freshness.yml` compared each pinned base digest with the digest its tag names now and failed on any difference, so a publisher pushing the index again over the very same images (a platform added, an attestation rewritten) turned it red for an image that had not changed. It now also compares the builds this image is made from under both digests: linux/amd64 alone when every stage from that base is built on the runner (`--platform=$BUILDPLATFORM` or `${BUILDPLATFORM}`), linux/amd64 and linux/arm64 when any stage is built for each published platform, as the fleet's triage judges a re-pushed base. The same builds pass with a notice naming both digests; a new build, or one that cannot be read, still fails.

## [1.0.1] - 2026-11-05

### Changed

- **Debian's 2026-11-04 `debian:trixie-slim` repush is the base.** The pin moves from `sha256:f6b08b09…` to `sha256:a72b4433…`. jmx_exporter 1.7.0, the Maven build image and the recorded checksums stay as they were.

## [1.0.0] - 2026-11-02

### Added

- **heyvaldemar/jmx-exporter: Prometheus's JMX exporter 1.7.0 on Debian 13 and Debian's OpenJDK 21, rebuilt every week.** Tags `1.7.0`, `1.7`, `1` and `latest`; `linux/amd64` and `linux/arm64`. `bitnami/jmx-exporter` has published only `latest` since August 2025, built on Photon OS, and its versioned tags stopped at `1.4.0-debian-12-r0`.
- **A drop-in for bitnami/jmx-exporter, checked on every build** against `bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0`: user `1001`, the working directory `/opt/bitnami/jmx-exporter` with both jars and every example configuration, the same entrypoint, command, exposed port, `PATH`, `HOME` and build `SHELL`, Java at `/opt/bitnami/java`, every executable on its `PATH` or a reason in `tests/drop-in-absent.tsv`, and both images run with the charts' command line and securityContext against the same Java process, giving the same metric names.
- **Bitnami's own Kafka chart on kind**: its JMX exporter sidecar runs this image and reports the messages written to a topic before anything is published.
- **jmx_exporter built from source** at the commit its release tag names, with every Maven artifact the build resolves checked against a recorded SHA-512 (`maven/`).
- **No fixable critical or high finding**: `scripts/cve-gate.sh` refuses an image that carries one, in Debian's packages or in the libraries inside the jars.
- **A contract with the published image**: nothing a chart used under a tag disappears from it without a line in `tests/contract-removed.tsv`.
- **Every digest signed** with cosign, keyless, and every tag's signature verified after signing; SBOM, SLSA provenance and a GitHub build attestation; Trivy on the published image; CVE counts against the images it replaces after every publish.
- **Every test shown the breaks it exists for**: sixteen planted violations in `tests/plants.tsv`, run in CI before anything is published.

[Unreleased]: https://github.com/heyvaldemar/jmx-exporter-docker/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/heyvaldemar/jmx-exporter-docker/releases/tag/v1.0.2
[1.0.1]: https://github.com/heyvaldemar/jmx-exporter-docker/releases/tag/v1.0.1
[1.0.0]: https://github.com/heyvaldemar/jmx-exporter-docker/releases/tag/v1.0.0
