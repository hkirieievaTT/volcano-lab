#!/usr/bin/env bash
# Snapshot of pod counts and queue status. Loop with: while true; do clear; ./status.sh; sleep 2; done
ctx=$(kubectl config current-context 2>/dev/null)
if [ "$ctx" != kind-volcano-lab ]; then
  echo "kubectl context is '${ctx:-none}', not kind-volcano-lab. Run: export KUBECONFIG=\$HOME/.kube/volcano-lab.yaml" >&2
  exit 1
fi
for q in q1 q2; do
  printf '%s pods: %s\n' "$q" "$(kubectl get pods -l queue=$q --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | xargs)"
done
echo
kubectl get queue q1 q2 -o custom-columns=NAME:.metadata.name,WEIGHT:.spec.weight,PRIO:.spec.priority,RECLAIMABLE:.spec.reclaimable,ALLOC:.status.allocated.cpu
