#!/usr/bin/env bash
# Contract test: does a new build keep every promise the published image made?
#
#   scripts/contract-test.sh <new-image> <published-image>
#
# The drop-in test asks whether this image still matches bitnami/jmx-exporter.
# This asks the question a chart cares about next: is anything it used
# yesterday gone today? A base image update that drops a binary, or a new
# jmx_exporter release that renames a jar, passes a build and breaks every
# Kafka pod's sidecar on its next restart. So the published image is the
# baseline, and the new build must keep:
#
#   - every executable on PATH (a removal must be listed, with its reason, in
#     tests/contract-removed.tsv, which the changelog then has to explain);
#   - every file in /opt/bitnami/jmx-exporter: both jars and every example
#     configuration;
#   - the user, working directory, entrypoint, command, build SHELL, exposed
#     port, PATH and HOME;
#   - the jmx_exporter major version the tag promises, a Java at least as new,
#     and the same Debian release.
#
# With nothing published under the tag yet, there is no contract to keep and
# the test says so.
set -euo pipefail

NEW="${1:?usage: contract-test.sh <new-image> <published-image>}"
BASE="${2:?usage: contract-test.sh <new-image> <published-image>}"
REMOVED_FILE="$(dirname "$0")/../tests/contract-removed.tsv"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "OK: $*"; }

if ! docker pull -q "$BASE" >/dev/null 2>&1; then
  echo "nothing is published as $BASE yet: no contract to keep"
  exit 0
fi
echo "new:       $NEW"
echo "published: $BASE ($(docker image inspect -f '{{index .RepoDigests 0}}' "$BASE" 2>/dev/null || echo local))"

executables() {
  docker run --rm --entrypoint sh "$1" -c '
    IFS=:
    for d in $PATH; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] && [ -x "$f" ] && echo "${f##*/}"
      done
    done' | sort -u
}
files() { docker run --rm --entrypoint sh "$1" -c 'cd /opt/bitnami/jmx-exporter && find . -type f ! -name build.txt ! -path "./licenses/*" | sort'; }
allowed="$(grep -vE '^\s*(#|$)' "$REMOVED_FILE" 2>/dev/null | awk '{print $1}' | sort -u || true)"
missing="$(comm -23 <(executables "$BASE") <(executables "$NEW"))"
unexplained="$(comm -23 <(printf '%s\n' "$missing" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d'))"
if [ -n "$unexplained" ]; then
  bad "executables the published image has and this build does not: $(echo "$unexplained" | tr '\n' ' ')(list each in tests/contract-removed.tsv with its reason if the removal is meant)"
else
  ok "every executable on the published image's PATH is still there ($(executables "$NEW" | grep -c .) on PATH)"
fi
gone="$(comm -23 <(files "$BASE") <(files "$NEW") | tr '\n' ' ')"
if [ -n "$gone" ]; then bad "files the published image has in /opt/bitnami/jmx-exporter and this build does not: $gone"; else ok "every jar and example configuration is still in /opt/bitnami/jmx-exporter"; fi

for field in User WorkingDir Entrypoint Cmd Shell ExposedPorts; do
  a="$(docker image inspect -f "{{json .Config.$field}}" "$BASE")"
  b="$(docker image inspect -f "{{json .Config.$field}}" "$NEW")"
  if [ "$a" = "$b" ]; then ok "$field unchanged ($b)"; else bad "$field changed: published $a, this build $b"; fi
done
envvar() { docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p"; }
for var in PATH HOME; do
  a="$(envvar "$BASE" "$var")"; b="$(envvar "$NEW" "$var")"
  if [ "$a" = "$b" ]; then ok "$var unchanged (${b:-unset})"; else bad "$var changed: published '${a}', this build '${b}'"; fi
done

a="$(envvar "$BASE" APP_VERSION)"; b="$(envvar "$NEW" APP_VERSION)"
if [ "${a%%.*}" = "${b%%.*}" ]; then ok "jmx_exporter stays on ${b%%.*}.x (${a} published, ${b} built)"; else bad "jmx_exporter ${b} is not the ${a%%.*}.x line the published ${a} promised"; fi
java_major() { docker run --rm --entrypoint java "$1" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.specification\.version = //p'; }
a="$(java_major "$BASE")"; b="$(java_major "$NEW")"
if [ -n "$b" ] && [ "${b:-0}" -ge "${a:-0}" ]; then ok "Java ${b}, published Java ${a}"; else bad "Java ${b:-none} is older than the published Java ${a}"; fi
debian() { docker run --rm --entrypoint cat "$1" /etc/debian_version | cut -d. -f1; }
a="$(debian "$BASE")"; b="$(debian "$NEW")"
if [ "$a" = "$b" ]; then ok "the build stays on Debian $b"; else bad "the build is Debian $b, the published image Debian $a"; fi

if [ "$fail" -ne 0 ]; then echo "The contract is broken; nothing is published." >&2; exit 1; fi
echo "The contract holds."
