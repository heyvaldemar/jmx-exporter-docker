#!/usr/bin/env bash
# Is this image a drop-in for bitnami/jmx-exporter?
#
#   tests/drop-in-test.sh <image> [<bitnami-image>]
#
# Bitnami's charts give this image one command line and no way to change it:
#
#   java -XX:MaxRAMPercentage=100 -XshowSettings:vm -jar jmx_prometheus_standalone.jar <port> <config>
#
# run in its working directory as user 1001, group 1001, with a read-only root
# filesystem and every capability dropped. So the image has to keep how
# bitnami/jmx-exporter ran: the user, working directory, entrypoint, command,
# PATH and HOME, java on that PATH, both jars under the names the charts and
# users call them by, and the example configurations beside them. The last
# versioned Bitnami image (bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0,
# August 2025) is the reference. Every executable on its PATH must be on this
# image's PATH, unless tests/drop-in-absent.tsv names it with the reason.
#
# Then both images are run the way the charts run them, against the same Java
# process, and must give the same answer: the standalone exporter reading
# that process's MBeans over remote JMX, and the java agent inside a JVM.
set -euo pipefail
IMAGE="${1:?usage: drop-in-test.sh <image> [<bitnami-image>]}"
REF="${2:-bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0}"
TESTS="$(cd "$(dirname "$0")" && pwd)"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "OK: $*"; }

# Compare on one architecture, the host's when the reference has it.
platform="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$IMAGE")"
docker pull -q --platform "$platform" "$REF" >/dev/null
ref_inspect() { docker image inspect --platform "$platform" "$@" 2>/dev/null || docker image inspect "$@"; }
ref_run() { docker run --rm --platform "$platform" "$@"; }

for field in User WorkingDir Entrypoint Cmd Shell ExposedPorts; do
  a="$(ref_inspect -f "{{json .Config.$field}}" "$REF")"
  b="$(docker image inspect -f "{{json .Config.$field}}" "$IMAGE")"
  if [ "$a" = "$b" ]; then ok "$field as bitnami/jmx-exporter ($b)"; else bad "$field: bitnami/jmx-exporter $a, this image $b"; fi
done
for var in HOME PATH OS_NAME BITNAMI_APP_NAME; do
  a="$(ref_inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$REF" | sed -n "s/^${var}=//p")"
  b="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" | sed -n "s/^${var}=//p")"
  if [ "$a" = "$b" ]; then ok "$var as bitnami/jmx-exporter ($b)"; else bad "$var: bitnami/jmx-exporter '$a', this image '$b'"; fi
done

# The files in the working directory: both jars, and every example
# configuration Bitnami's image had, under the same names.
files() { docker run --rm --platform "$2" --entrypoint sh "$1" -c 'cd /opt/bitnami/jmx-exporter && for f in *.jar examples/*; do [ -f "$f" ] && echo "$f"; done' | sort; }
missing="$(comm -23 <(files "$REF" "$platform") <(files "$IMAGE" "$platform") | tr '\n' ' ')"
if [ -z "$missing" ]; then ok "both jars and every example configuration are in /opt/bitnami/jmx-exporter"; else bad "in bitnami/jmx-exporter's working directory and not here: $missing"; fi

# Not Bitnami's way, and on purpose: root owns the jars, so the user the
# exporter runs as, 1001 or an arbitrary one in group 0 (OpenShift), can run
# them and cannot replace them.
for u in 1001:0 1001:1001 1000650000:0; do
  if docker run --rm --user "$u" --entrypoint sh "$IMAGE" -c 'cd /opt/bitnami/jmx-exporter && [ ! -w . ] && for f in *.jar examples/*; do [ ! -w "$f" ] || exit 1; done'; then
    ok "user $u can read the jars and cannot replace them"
  else
    bad "user $u can write to /opt/bitnami/jmx-exporter"
  fi
done

executables() {
  docker run --rm --platform "$2" --entrypoint sh "$1" -c '
    IFS=:
    for d in $PATH; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do [ -f "$f" ] && [ -x "$f" ] && echo "${f##*/}"; done
    done' | sort -u
}
unexplained=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  matched=false
  while IFS=$'\t' read -r pattern _; do
    case "$pattern" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    if [[ "$name" == $pattern ]]; then matched=true; break; fi
  done <"$TESTS/drop-in-absent.tsv"
  $matched || unexplained="$unexplained $name"
done < <(comm -23 <(executables "$REF" "$platform") <(executables "$IMAGE" "$platform"))
if [ -z "$unexplained" ]; then
  ok "every executable on bitnami/jmx-exporter's PATH is here, or named in tests/drop-in-absent.tsv with its reason"
else
  bad "on bitnami/jmx-exporter's PATH and not here, with no reason given:$unexplained"
fi

# Calls a script makes into the image, on both.
for c in "java -version" "/opt/bitnami/java/bin/java -version" "java -XX:MaxRAMPercentage=100 -XshowSettings:vm -version" "keytool -help" "bash -c true"; do
  if ref_run --entrypoint sh "$REF" -c "$c" >/dev/null 2>&1; then
    if docker run --rm --entrypoint sh "$IMAGE" -c "$c" >/dev/null 2>&1; then ok "'$c' runs on both"; else bad "'$c' runs on bitnami/jmx-exporter and not here"; fi
  else
    bad "'$c' does not run on bitnami/jmx-exporter either; the test is wrong"
  fi
done

# ── Both images, run the way the charts run them ─────────────────────────────
# One Java process with remote JMX open is the target: this image's own JVM,
# running the exporter against itself. Then each image's exporter reads it
# with the charts' exact command line and security settings, and the java
# agent runs inside each image's JVM. Every metric name bitnami/jmx-exporter
# gives must come from this image too.
work="$(mktemp -d)"
net="jmx-drop-in-$$"
cleanup() {
  docker rm -f "$net-target" "$net-ref" "$net-new" "$net-ref-agent" "$net-new-agent" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
on_exit() { local rc=$?; cleanup; exit "$rc"; }
trap on_exit EXIT
docker network create "$net" >/dev/null
chmod 0755 "$work"
cat >"$work/target.yml" <<'YML'
hostPort: 127.0.0.1:9010
rules:
  - pattern: ".*"
YML
cat >"$work/scrape.yml" <<YML
hostPort: ${net}-target:9010
lowercaseOutputName: true
rules:
  - pattern: java.lang<type=(.+), name=(.+)><>(\\w+)
    name: java_lang_\$1_\$3_\$2
  - pattern: java.lang<type=(.+)><>(\\w+)
    name: java_lang_\$1_\$2
YML
cat >"$work/agent.yml" <<'YML'
rules:
  - pattern: ".*"
YML
cat >"$work/all.policy" <<'POLICY'
grant {
  permission java.security.AllPermission;
};
POLICY
chmod 0644 "$work"/*.yml "$work/all.policy"

docker run -d --name "$net-target" --network "$net" -v "$work:/etc/jmx:ro" --entrypoint java "$IMAGE" \
  -Dcom.sun.management.jmxremote.port=9010 -Dcom.sun.management.jmxremote.rmi.port=9010 \
  -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false \
  -Djava.rmi.server.hostname="$net-target" \
  -jar jmx_prometheus_standalone.jar 5556 /etc/jmx/target.yml >/dev/null

# The charts' securityContext: user 1001, group 1001, no new privileges, every
# capability dropped, a read-only root filesystem, and their command line.
charts_run() {
  local name="$1" image="$2"; shift 2
  docker run -d --name "$name" --network "$net" --platform "$platform" \
    --user 1001:1001 --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$work:/etc/jmx:ro" -p 127.0.0.1::5556 \
    --entrypoint java "$image" -XX:MaxRAMPercentage=100 -XshowSettings:vm "$@" >/dev/null
}
charts_run "$net-ref" "$REF" -jar jmx_prometheus_standalone.jar 5556 /etc/jmx/scrape.yml
charts_run "$net-new" "$IMAGE" -jar jmx_prometheus_standalone.jar 5556 /etc/jmx/scrape.yml
# The java agent, as a user copies it out of the image into an application's
# JVM. The application is the RMI registry, the one long-running Java program
# both images' runtimes carry, started with the modules a plain classpath
# application gets (ALL-DEFAULT, the HTTP server the agent serves its metrics
# with among them). The registry installs a security manager of its own;
# all.policy lets it allow everything, as an application without one does.
agent_run() {
  local name="$1" image="$2"
  docker run -d --name "$name" --network "$net" --platform "$platform" \
    --user 1001:1001 --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$work:/etc/jmx:ro" -p 127.0.0.1::5557 \
    --entrypoint java "$image" --add-modules=ALL-DEFAULT \
    -Djava.security.manager=allow -Djava.security.policy==/etc/jmx/all.policy \
    -javaagent:/opt/bitnami/jmx-exporter/jmx_prometheus_javaagent.jar=5557:/etc/jmx/agent.yml \
    -m java.rmi/sun.rmi.registry.RegistryImpl >/dev/null
}
agent_run "$net-ref-agent" "$REF"
agent_run "$net-new-agent" "$IMAGE"

# The metrics a container serves on a port, once it serves them; empty after
# 90 seconds of nothing.
scrape() {
  local name="$1" port="$2" hostport body _
  hostport="$(docker port "$name" "$port/tcp" | head -1)"
  for _ in $(seq 1 45); do
    if body="$(curl -fsS --max-time 5 "http://${hostport}/metrics" 2>/dev/null)" && [ -n "$body" ]; then
      printf '%s\n' "$body"; return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || break
    sleep 2
  done
  docker logs "$name" >&2 2>&1 | tail -20 >&2 || true
  return 1
}
names() { awk '!/^#/ && NF { sub(/[{ ].*/, "", $1); print $1 }' | sort -u; }
value() { awk -v m="$1" '$1 == m { print $2; exit }'; }

for side in ref new; do
  if out="$(scrape "$net-$side" 5556)"; then
    printf '%s\n' "$out" >"$work/$side.prom"
  else
    bad "the $side exporter, run as the charts run it, served no metrics"; : >"$work/$side.prom"
  fi
  if out="$(scrape "$net-$side-agent" 5557)"; then
    printf '%s\n' "$out" >"$work/$side-agent.prom"
  else
    bad "the $side java agent served no metrics"; : >"$work/$side-agent.prom"
  fi
done

for side in ref new; do
  e="$(value jmx_scrape_error <"$work/$side.prom")"
  n="$(grep -c '^java_lang_' "$work/$side.prom" || true)"
  if [ "$e" = 0.0 ] && [ "$n" -gt 0 ]; then ok "$side: read the target's MBeans over remote JMX ($n java_lang samples, jmx_scrape_error 0)"; else bad "$side: jmx_scrape_error '$e', $n java_lang samples"; fi
done
lost="$(comm -23 <(names <"$work/ref.prom") <(names <"$work/new.prom") | tr '\n' ' ')"
if [ ! -s "$work/ref.prom" ]; then bad "bitnami/jmx-exporter's exporter gave nothing to compare with"
elif [ -z "$lost" ]; then ok "every metric name bitnami/jmx-exporter's exporter gives for the same target, this one gives ($(names <"$work/new.prom" | grep -c .) names)"; else bad "metric names bitnami/jmx-exporter's exporter gives and this one does not: $lost"; fi
for side in ref new; do
  n="$(grep -c '^jvm_memory_used_bytes{' "$work/$side-agent.prom" || true)"
  if [ "$n" -gt 0 ]; then ok "$side: the java agent reports its JVM ($n jvm_memory_used_bytes samples)"; else bad "$side: the java agent reports no jvm_memory_used_bytes"; fi
done
lost="$(comm -23 <(names <"$work/ref-agent.prom" | grep '^jvm_' || true) <(names <"$work/new-agent.prom" | grep '^jvm_' || true) | tr '\n' ' ')"
if [ ! -s "$work/ref-agent.prom" ]; then bad "bitnami/jmx-exporter's agent gave nothing to compare with"
elif [ -z "$lost" ]; then ok "every jvm_ metric name bitnami/jmx-exporter's agent gives, this one gives"; else bad "jvm_ metric names bitnami/jmx-exporter's agent gives and this one does not: $lost"; fi

# How it was built: from the pinned commit, with every Maven artifact checked.
built="$(docker run --rm --entrypoint cat "$IMAGE" /opt/bitnami/jmx-exporter/build.txt 2>/dev/null || true)"
case "$built" in
  *"every Maven artifact checked against "*) ok "built with every Maven artifact checked ($(printf '%s\n' "$built" | sed -n 's/.*checked against \([0-9]*\).*/\1/p') recorded checksums)" ;;
  *) bad "the image does not say its Maven artifacts were checked: '${built}'" ;;
esac

[ "$fail" -eq 0 ] || { echo "Not a drop-in for bitnami/jmx-exporter." >&2; exit 1; }
echo "A drop-in for bitnami/jmx-exporter."
