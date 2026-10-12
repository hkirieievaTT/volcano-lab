#!/usr/bin/env bash
# Usage: ./pods.sh <queue> <count>
# Keeps <count> standalone 1-CPU pods in <queue>. Standalone pods each get their own
# PodGroup (minMember 1); reclaim only acts for PodGroups below minMember, so a
# Deployment (one PodGroup for all replicas) stops reclaiming after its first pod runs.
set -euo pipefail
q=$1; want=$2
have=$(kubectl get pods -l queue="$q" --no-headers 2>/dev/null | wc -l | tr -d ' ')

if (( want > have )); then
  for _ in $(seq $((want - have))); do
    cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  generateName: ${q}-pod-
  labels: {queue: ${q}}
  annotations:
    scheduling.volcano.sh/queue-name: ${q}
    volcano.sh/preemptable: "true"
spec:
  schedulerName: volcano
  terminationGracePeriodSeconds: 0
  containers:
  - name: busy
    image: busybox
    command: ["sleep", "infinity"]
    resources:
      requests: {cpu: "1", memory: "64Mi"}
      limits:   {cpu: "1", memory: "64Mi"}
EOF
  done | kubectl create -f - >/dev/null
elif (( want < have )); then
  # Remove Pending pods first, then the newest Running ones.
  kubectl get pods -l queue="$q" --sort-by=.metadata.creationTimestamp \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers \
    | awk '{print ($2=="Pending" ? 0 : 1), NR, $1}' | sort -k1,1n -k2,2nr \
    | head -n $((have - want)) | awk '{print $3}' \
    | xargs kubectl delete pod --wait=false >/dev/null
fi
echo "$q: $want pods requested (had $have)"
