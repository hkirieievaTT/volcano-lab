#!/usr/bin/env bash
# Usage: ./reset.sh                    remove all lab workloads and put q1/q2 back to queues.yaml (cluster stays)
#        ./reset.sh --delete-cluster   delete the whole kind cluster and ~/.kube/volcano-lab.yaml
# Only ever talks to the kind cluster "volcano-lab".
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/bin:$PATH"

CLUSTER=volcano-lab
CONTEXT=kind-$CLUSTER
LAB_KUBECONFIG="$HOME/.kube/volcano-lab.yaml"
export KUBECONFIG="$LAB_KUBECONFIG"
kc() { kubectl --kubeconfig "$LAB_KUBECONFIG" --context "$CONTEXT" "$@"; }

case "${1:-}" in
  "") ;;
  --delete-cluster)
    kind delete cluster --name "$CLUSTER" --kubeconfig "$LAB_KUBECONFIG"
    rm -f "$LAB_KUBECONFIG"
    echo "Cluster $CLUSTER and $LAB_KUBECONFIG deleted. Recreate with ./setup.sh"
    exit 0
    ;;
  -h | --help) sed -n '2,4s/^# //p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (see ./reset.sh --help)" >&2; exit 2 ;;
esac

[ -s "$LAB_KUBECONFIG" ] || { echo "ERROR: $LAB_KUBECONFIG not found - run ./setup.sh" >&2; exit 1; }

echo "==> Deleting lab workloads in namespace default"
kc delete vcjob gang-test --ignore-not-found
kc delete deploy q1-work q2-work --ignore-not-found
kc delete pod -l 'queue in (q1,q2)' --ignore-not-found --wait=false

echo "==> Restoring q1/q2 from queues.yaml"
kc apply -f queues.yaml

echo "==> Waiting for the pods to go away"
kc wait --for=delete pod -l 'queue in (q1,q2)' --timeout=120s 2>/dev/null || true
./status.sh
