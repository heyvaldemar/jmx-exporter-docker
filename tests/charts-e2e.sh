#!/usr/bin/env bash
# Does Bitnami's own Kafka chart run its JMX exporter on this image?
#
#   tests/charts-e2e.sh <image>
#
# The image is loaded into a fresh kind cluster and named as the chart's
# metrics.jmx.image, as a user would after bitnami/jmx-exporter stopped
# moving. The chart starts the exporter as a sidecar of each Kafka node, with
# its own command line (`java ... -jar jmx_prometheus_standalone.jar 5556
# /etc/jmx-kafka/jmx-kafka-prometheus.yml`), its own rules, and its own
# securityContext: user 1001, a read-only root filesystem, no capabilities.
#
# The release must become Ready with the sidecar running this image and never
# restarted, and the exporter must report what Kafka is doing: one active
# controller, and the three messages this script writes to a topic of its
# own, read from Kafka's MBeans after they were sent. The chart is pinned
# (kafka 32.4.3, the last version Bitnami published, in August 2025); Kafka
# itself is that chart's own image, frozen with it as bitnamilegacy/kafka.
#
# Any image can be named, bitnamilegacy/jmx-exporter:1.4.0-debian-12-r0
# included: that is how this test is checked against the image it replaces.
set -euo pipefail
IMAGE="${1:?usage: charts-e2e.sh <image>}"
CLUSTER="${CLUSTER:-jmx-exporter-e2e}"
KIND_NODE="${KIND_NODE:-}"
KAFKA_CHART="${KAFKA_CHART:-32.4.3}"
KAFKA_IMAGE="${KAFKA_IMAGE:-bitnamilegacy/kafka:4.0.0-debian-12-r10}"
MESSAGES=3
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "OK: $*"; }

repo="${IMAGE%:*}"; tag="${IMAGE##*:}"
[ "$repo" != "$IMAGE" ] || { echo "name the image with a tag, for example jmx-exporter:1.7.0" >&2; exit 2; }

pf=""
cleanup() {
  [ -z "$pf" ] || kill "$pf" 2>/dev/null || true
  [ -n "${KEEP_CLUSTER:-}" ] || kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
}
# Keep the script's own exit status: the trap must not turn a failure into 0.
on_exit() { local rc=$?; cleanup; exit "$rc"; }
trap on_exit EXIT
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
node=()
[ -z "$KIND_NODE" ] || node=(--image "$KIND_NODE")
kind create cluster --name "$CLUSTER" ${node[@]+"${node[@]}"} --wait 120s >/dev/null
kind load docker-image "$IMAGE" --name "$CLUSTER" >/dev/null
export KUBECONFIG
KUBECONFIG="$(mktemp)"
kind get kubeconfig --name "$CLUSTER" >"$KUBECONFIG"

# One combined controller and broker. PLAINTEXT listeners only so the script
# can write to a topic without credentials; nothing about the exporter's
# side of the chart is changed. Bitnami's charts refuse an image from outside
# their catalogue unless told it is meant (global.security.allowInsecureImages);
# that is the switch a user flips too.
if helm install kafka oci://registry-1.docker.io/bitnamicharts/kafka --version "$KAFKA_CHART" \
  --set global.security.allowInsecureImages=true \
  --set image.registry=docker.io \
  --set "image.repository=${KAFKA_IMAGE%:*}" \
  --set "image.tag=${KAFKA_IMAGE##*:}" \
  --set controller.replicaCount=1 \
  --set listeners.client.protocol=PLAINTEXT \
  --set listeners.controller.protocol=PLAINTEXT \
  --set listeners.interbroker.protocol=PLAINTEXT \
  --set metrics.jmx.enabled=true \
  --set metrics.jmx.image.registry=docker.io \
  --set "metrics.jmx.image.repository=${repo}" \
  --set "metrics.jmx.image.tag=${tag}" \
  --set metrics.jmx.image.pullPolicy=Never \
  --wait --timeout 8m >/dev/null; then ok "kafka became Ready"; else bad "kafka did not become Ready"; fi

pod=kafka-controller-0
image="$(kubectl get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='jmx-exporter')].image}")"
ready="$(kubectl get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='jmx-exporter')].ready}")"
restarts="$(kubectl get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='jmx-exporter')].restartCount}")"
case "$image" in *"${repo}:${tag}") ok "$pod/jmx-exporter runs this image" ;; *) bad "$pod/jmx-exporter runs '$image', not this image" ;; esac
if [ "$ready" = true ] && [ "$restarts" = 0 ]; then ok "$pod/jmx-exporter is ready and never restarted"; else bad "$pod/jmx-exporter ready '$ready', restarts '$restarts'"; kubectl logs "$pod" -c jmx-exporter --tail 40 >&2 || true; fi
args="$(kubectl get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='jmx-exporter')].args}")"
case "$args" in *jmx_prometheus_standalone.jar*) ok "started with the chart's own command line" ;; *) bad "the chart's command line is not the one run: $args" ;; esac

# Something for the exporter to see: a topic, and messages written to it.
# The Kafka container's environment opens remote JMX on 5555 for any Kafka
# JVM it starts, the broker's own included; the command-line tools must not
# try to take that port too.
kafka() { kubectl exec -i "$pod" -c kafka -- env -u JMX_PORT -u KAFKA_JMX_OPTS "$@"; }
if kafka kafka-topics.sh --bootstrap-server localhost:9092 --create --topic e2e --partitions 1 --replication-factor 1 >/dev/null \
  && seq 1 "$MESSAGES" | kafka kafka-console-producer.sh --bootstrap-server localhost:9092 --topic e2e >/dev/null 2>&1; then
  ok "wrote $MESSAGES messages to topic e2e"
else
  bad "could not write to Kafka"
fi

port=$((20000 + RANDOM % 20000))
kubectl port-forward "pod/$pod" "$port:5556" >/dev/null 2>&1 &
pf=$!
metrics=""
seen=""
for _ in $(seq 1 45); do
  metrics="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/metrics" 2>/dev/null || true)"
  seen="$(awk '/^kafka_server_brokertopicmetrics_messagesinpersec_count\{/ && /topic="e2e"/ { print $NF; exit }' <<<"$metrics")"
  [ -n "$seen" ] && awk -v v="$seen" -v n="$MESSAGES" 'BEGIN { exit !(v + 0 >= n) }' && break
  sleep 2
done
if [ -n "$metrics" ]; then ok "the exporter answers on the chart's metrics port"; else bad "nothing on the chart's metrics port 5556"; fi
if [ -n "$seen" ] && awk -v v="$seen" -v n="$MESSAGES" 'BEGIN { exit !(v + 0 >= n) }'; then
  ok "it reports the $MESSAGES messages written to e2e (kafka_server_brokertopicmetrics_messagesinpersec_count ${seen})"
else
  bad "it does not report the messages written to e2e (got '${seen}')"
fi
active="$(awk '$1 == "kafka_controller_kafkacontroller_activecontrollercount_value" { print $2; exit }' <<<"$metrics")"
if [ "$active" = 1.0 ]; then ok "it reports one active controller"; else bad "active controller count '${active}'"; fi
scrape_error="$(awk '$1 == "jmx_scrape_error" { print $2; exit }' <<<"$metrics")"
if [ "$scrape_error" = 0.0 ]; then ok "jmx_scrape_error is 0 ($(grep -c '^kafka_' <<<"$metrics" || true) kafka samples)"; else bad "jmx_scrape_error '${scrape_error}'"; fi

[ "$fail" -eq 0 ] || { echo "Bitnami's kafka chart does not run its JMX exporter on ${IMAGE}." >&2; exit 1; }
echo "Bitnami's kafka chart runs its JMX exporter on ${IMAGE}, and the exporter reports what Kafka does."
