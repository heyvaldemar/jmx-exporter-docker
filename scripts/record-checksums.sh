#!/usr/bin/env bash
# Record the SHA-512 of every Maven artifact the build resolves, again.
#
#   scripts/record-checksums.sh
#
# For a pull request that moves the jmx_exporter pin or the Maven image: the
# build stage runs in record mode (MAVEN_CHECKSUMS=record) and its checksums
# replace maven/checksums-*.sha512. Read the diff before committing it: every
# new or changed line is an artifact the build will trust from then on, and a
# changed checksum for a version that did not change is the one thing this
# file exists to catch.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
docker buildx build --target checksums --build-arg MAVEN_CHECKSUMS=record --output "type=local,dest=${out}" "$ROOT"
ls "$out"/checksums-*.sha512 >/dev/null
rm -f "$ROOT"/maven/checksums-*.sha512
for f in "$out"/checksums-*.sha512; do
  sort -k2 "$f" > "$ROOT/maven/$(basename "$f")"
done
wc -l "$ROOT"/maven/checksums-*.sha512
git -C "$ROOT" diff --stat -- maven/ || true
