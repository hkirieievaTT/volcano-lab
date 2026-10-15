#!/usr/bin/env bash
# Usage: ./setup.sh
# Brings up the local Volcano lab in one command: kind cluster "volcano-lab" (2 nodes, both take workloads),
# Volcano 1.15.3 with the lab's scheduler config, and the queues q1/q2. Safe to re-run: every step skips what
# already exists. It never deletes anything and never upgrades an existing Volcano release.
#
# The cluster gets its own kubeconfig (~/.kube/volcano-lab.yaml); ~/.kube/config and your shell's KUBECONFIG are
# never read or written, so a production context cannot be hit by accident.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/bin:$PATH"

CLUSTER=volcano-lab
CONTEXT=kind-$CLUSTER
LAB_KUBECONFIG="$HOME/.kube/volcano-lab.yaml"
VOLCANO_VERSION=1.15.3
VOLCANO_NS=volcano-system
HELM_REPO=volcano-sh
HELM_REPO_URL=https://volcano-sh.github.io/helm-charts

export KUBECONFIG="$LAB_KUBECONFIG"
# These would override the API server or credentials helm uses, regardless of --kubeconfig.
unset HELM_KUBEAPISERVER HELM_KUBECONTEXT HELM_KUBETOKEN HELM_KUBEASUSER HELM_KUBEASGROUPS \
  HELM_KUBECAFILE HELM_KUBEINSECURE_SKIP_TLS_VERIFY HELM_KUBETLS_SERVER_NAME

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
kc() { kubectl --kubeconfig "$LAB_KUBECONFIG" --context "$CONTEXT" "$@"; }
hc() { helm --kubeconfig "$LAB_KUBECONFIG" --kube-context "$CONTEXT" "$@"; }

step "Prerequisites"
for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null || die "'$tool' not found on PATH (\$HOME/bin is searched first) - see README.md"
  info "$tool: $(command -v "$tool")"
done
docker info >/dev/null 2>&1 || die "docker is installed but the daemon does not answer - start OrbStack or Docker Desktop"

step "kind cluster \"$CLUSTER\""
if kind get clusters 2>/dev/null | grep -Fx "$CLUSTER" >/dev/null; then
  info "exists - reusing it"
  docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format '{{.Names}} {{.State}}' |
    while read -r name state; do
      if [ "$state" != running ]; then
        info "node container $name is $state - starting it"
        docker start "$name" >/dev/null
      fi
    done
else
  info "creating it from kind-config.yaml (takes about a minute)"
  mkdir -p "$(dirname "$LAB_KUBECONFIG")"
  kind create cluster --name "$CLUSTER" --config kind-config.yaml --kubeconfig "$LAB_KUBECONFIG"
fi
# Rewritten every run: the API server port changes when the node containers restart.
mkdir -p "$(dirname "$LAB_KUBECONFIG")"
(umask 077 && kind get kubeconfig --name "$CLUSTER" >"$LAB_KUBECONFIG")
server="$(kubectl --kubeconfig "$LAB_KUBECONFIG" config view -o jsonpath='{.clusters[0].cluster.server}')"
[[ $server =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]] ||
  die "$LAB_KUBECONFIG points at '$server', which is not a local kind API server - refusing to continue"
info "kubeconfig $LAB_KUBECONFIG -> $server"
kc wait --for=condition=Ready nodes --all --timeout=180s | sed 's/^/    /'

step "Control-plane taint (both nodes take workloads)"
taint=node-role.kubernetes.io/control-plane
for node in $(kc get nodes -o name); do
  if kc get "$node" -o jsonpath='{.spec.taints[*].key}' | tr ' ' '\n' | grep -Fx "$taint" >/dev/null; then
    kc taint "$node" "$taint-" | sed 's/^/    /'
  else
    info "${node#node/}: no taint"
  fi
done

step "Volcano $VOLCANO_VERSION"
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -Fx "$HELM_REPO" >/dev/null; then
  helm repo add "$HELM_REPO" "$HELM_REPO_URL" | sed 's/^/    /'
fi
if hc status volcano -n "$VOLCANO_NS" >/dev/null 2>&1; then
  chart="$(hc list -n "$VOLCANO_NS" --filter '^volcano$' -o json | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
  info "release already installed ($chart) - left as is"
  [ "$chart" = "volcano-$VOLCANO_VERSION" ] || info "WARNING: expected volcano-$VOLCANO_VERSION"
else
  info "installing (helm install --wait, up to 5 minutes)"
  helm repo update "$HELM_REPO" | sed 's/^/    /'
  hc install volcano "$HELM_REPO/volcano" --version "$VOLCANO_VERSION" \
    -n "$VOLCANO_NS" --create-namespace -f volcano-values.yaml --wait --timeout 5m | sed 's/^/    /'
fi
kc -n "$VOLCANO_NS" wait --for=condition=Available deployment --all --timeout=180s | sed 's/^/    /'

step "Queues q1 and q2 (queues.yaml)"
# The admission webhook can refuse connections for a few seconds after its Deployment turns Available.
for attempt in $(seq 1 12); do
  if out="$(kc apply -f queues.yaml 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/    /'
    break
  fi
  if [ "$attempt" -eq 12 ] || ! grep -qE 'failed calling webhook|connection refused|no endpoints' <<<"$out"; then
    die "kubectl apply -f queues.yaml failed: $out"
  fi
  info "admission webhook not ready yet ($attempt/12) - retrying in 5s"
  sleep 5
done

cat <<EOF

Done. Point your terminal at the lab (every new terminal):

  export PATH=\$HOME/bin:\$PATH
  export KUBECONFIG=\$HOME/.kube/volcano-lab.yaml
EOF
