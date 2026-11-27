#!/usr/bin/env bash
# Experiment for issue #91 ("Failed mount with mountMode=mountpod", sidecar
# mode works): is the symptom explained by the mount pod running on the host
# network (hfMount.hostNetwork=true) while the Hub is reachable only from the
# pod network?
#
# Needs a cluster from `setup-cluster.sh sidecar` (webhook deployed, so both
# modes are available). Phases:
#   A  baseline: mountpod and sidecar both mount a public repo
#   B  drop host-netns egress to :443 on the kind node (pod traffic is
#      forwarded, not locally generated, so it is unaffected)
#   C  mountpod: expect FailedMount "FUSE mount did not appear ..."
#   D  sidecar: expect success under the same block
#   E  hfMount.hostNetwork=false: expect mountpod to succeed under the block

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

NODE=${NODE:-$CLUSTER_NAME-control-plane}
REPO_ID=${REPO_ID:-openai-community/gpt2}

section() { printf '\n########## %s ##########\n' "$*"; }

# apply_pod NAME MODE  (MODE: mountpod|sidecar)
apply_pod() {
  local name=$1 mode=$2 mode_attr=""
  [[ $mode == mountpod ]] && mode_attr="mountMode: mountpod"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  containers:
  - name: test
    image: $BUSYBOX_IMAGE
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "ls /model && cat /model/config.json"]
    volumeMounts:
    - name: model
      mountPath: /model
      readOnly: true
  volumes:
  - name: model
    csi:
      driver: hf.csi.huggingface.co
      readOnly: true
      volumeAttributes:
        $mode_attr
        sourceType: repo
        sourceId: $REPO_ID
  restartPolicy: Never
YAML
}

failed_mount_events() {
  kubectl get events \
    --field-selector "involvedObject.name=$1,reason=FailedMount" \
    -o jsonpath='{range .items[*]}first={.firstTimestamp} last={.lastTimestamp} count={.count}{"\n"}  {.message}{"\n"}{end}'
}

failed_mount_count() {
  kubectl get events \
    --field-selector "involvedObject.name=$1,reason=FailedMount" \
    -o jsonpath='{range .items[*]}{.count}{"\n"}{end}' | awk '{s+=$1} END {print s+0}'
}

dump_mount_pods() {
  kubectl get pods -l hf.csi.huggingface.co/app=hf-mount -o wide || true
  local mp
  for mp in $(kubectl get pods -l hf.csi.huggingface.co/app=hf-mount -o name 2>/dev/null); do
    echo "--- $mp: hostNetwork=$(kubectl get "$mp" -o jsonpath='{.spec.hostNetwork}') phase=$(kubectl get "$mp" -o jsonpath='{.status.phase}') restarts=$(kubectl get "$mp" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
    kubectl logs "$mp" --timestamps --tail=60 2>/dev/null || true
    kubectl logs "$mp" --previous --timestamps --tail=60 2>/dev/null || true
  done
}

wait_mount_pods_gone() {
  local i
  for i in $(seq 1 60); do
    [[ -z $(list_mount_pods) ]] && return 0
    sleep 2
  done
  log "mount pods still present: $(list_mount_pods)"
}

probe_network() {
  echo "host netns (kind node) -> huggingface.co:443:"
  if docker exec "$NODE" timeout 8 bash -c 'exec 3<>/dev/tcp/huggingface.co/443' 2>&1; then
    echo "  reachable"
  else
    echo "  NOT reachable"
  fi
  echo "pod netns -> huggingface.co:443:"
  kubectl delete pod nettest --ignore-not-found --wait=true >/dev/null
  kubectl run nettest --image="$BUSYBOX_IMAGE" --image-pull-policy=IfNotPresent --restart=Never \
    --command -- sh -c 'nc -w 8 huggingface.co 443 </dev/null && echo reachable || echo NOT-reachable' >/dev/null
  kubectl wait pod/nettest --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null 2>&1 || true
  echo "  $(kubectl logs nettest 2>/dev/null || echo unknown)"
  kubectl delete pod nettest --ignore-not-found --wait=false >/dev/null
}

RESULT_C=unknown RESULT_D=unknown RESULT_E=unknown

section "A. baseline (no block)"
probe_network
apply_pod base-mountpod mountpod
apply_pod base-sidecar sidecar
wait_pod_succeeded base-mountpod 180s
wait_pod_succeeded base-sidecar 180s
ok "baseline: both modes mount $REPO_ID"
kubectl delete pod base-mountpod base-sidecar --wait=true
wait_mount_pods_gone

section "B. block host-netns egress to tcp/443 on $NODE"
docker exec "$NODE" sh -c '
  set -e
  iptables -N ISSUE91
  iptables -A ISSUE91 -d 10.0.0.0/8 -j RETURN
  iptables -A ISSUE91 -d 172.16.0.0/12 -j RETURN
  iptables -A ISSUE91 -d 192.168.0.0/16 -j RETURN
  iptables -A ISSUE91 -d 127.0.0.0/8 -j RETURN
  iptables -A ISSUE91 -p tcp --dport 443 -j DROP
  iptables -I OUTPUT -j ISSUE91
  ip6tables -I OUTPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
  iptables -S ISSUE91
'
probe_network

section "C. mountMode=mountpod under the block (hfMount.hostNetwork=true)"
apply_pod repro-mountpod mountpod
log "waiting for 2 FailedMount events (up to 420s)"
for _ in $(seq 1 84); do
  phase=$(kubectl get pod repro-mountpod -o jsonpath='{.status.phase}')
  [[ $phase == Succeeded ]] && break
  [[ $(failed_mount_count repro-mountpod) -ge 2 ]] && break
  sleep 5
done
echo "pod phase: $(kubectl get pod repro-mountpod -o jsonpath='{.status.phase}')"
echo "=== FailedMount events (full, untruncated) ==="
failed_mount_events repro-mountpod
echo "=== kubectl describe (Events) ==="
kubectl describe pod repro-mountpod | sed -n '/^Events:/,$p'
echo "=== mount pods ==="
dump_mount_pods
echo "=== driver log (mount path) ==="
kubectl logs -l app=hf-csi-node -c hf-csi-plugin --tail=400 \
  | grep -E 'mount pod|Mount pod|FUSE mount|did not|keeping it|cleaning up|Creating mount pod' | tail -40 || true
if failed_mount_events repro-mountpod | grep -q 'FUSE mount did not appear'; then
  RESULT_C="reproduced: $(failed_mount_events repro-mountpod | grep -o 'FUSE mount did not appear.*' | head -1)"
else
  RESULT_C="NOT reproduced (phase=$(kubectl get pod repro-mountpod -o jsonpath='{.status.phase}'))"
fi
kubectl delete pod repro-mountpod --wait=true --timeout=120s || true
wait_mount_pods_gone

section "D. sidecar mode under the same block"
apply_pod repro-sidecar sidecar
if wait_pod_succeeded repro-sidecar 180s; then
  RESULT_D="mounted OK"
  kubectl logs repro-sidecar -c test | grep model_type || true
else
  RESULT_D="FAILED"
  kubectl describe pod repro-sidecar | sed -n '/^Events:/,$p'
  kubectl logs repro-sidecar --all-containers --tail=60 || true
fi
kubectl delete pod repro-sidecar --wait=true --timeout=120s || true

section "E. mountpod with hfMount.hostNetwork=false, block still in place"
helm upgrade hf-csi "$REPO_ROOT/deploy/helm/hf-csi-driver/" --namespace "$NAMESPACE" \
  --reuse-values --set hfMount.hostNetwork=false
kubectl rollout status daemonset hf-csi-hf-csi-driver-node --namespace "$NAMESPACE" --timeout=180s
apply_pod fix-mountpod mountpod
if wait_pod_succeeded fix-mountpod 240s; then
  RESULT_E="mounted OK"
else
  RESULT_E="FAILED"
  kubectl describe pod fix-mountpod | sed -n '/^Events:/,$p'
fi
dump_mount_pods

section "SUMMARY"
echo "C mountpod, host network blocked : $RESULT_C"
echo "D sidecar,  host network blocked : $RESULT_D"
echo "E mountpod, hostNetwork=false    : $RESULT_E"
{
  echo "### Issue 91 experiment"
  echo "| phase | result |"
  echo "|---|---|"
  echo "| C mountpod, host netns egress blocked | $RESULT_C |"
  echo "| D sidecar, same block | $RESULT_D |"
  echo "| E mountpod, hfMount.hostNetwork=false, same block | $RESULT_E |"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

[[ $RESULT_C == reproduced* && $RESULT_D == "mounted OK" && $RESULT_E == "mounted OK" ]] \
  || fail "hypothesis not confirmed (see summary)"
ok "hypothesis confirmed"
