# Volcano Lab

A local playground for the [Volcano](https://volcano.sh) batch scheduler: a 2-node
[kind](https://kind.sigs.k8s.io) cluster with Volcano 1.15.3 and two queues, `q1` and `q2`, for trying out queue
weights, reclaim and gang scheduling on a laptop. Nothing here touches a shared cluster.

## Prerequisites

- macOS or Linux with [OrbStack](https://orbstack.dev) or Docker Desktop running
- `kind`, `kubectl`, `helm`

```bash
brew install --cask orbstack     # or Docker Desktop
brew install kind kubectl helm
git clone https://github.com/hkirieievaTT/volcano-lab.git
cd volcano-lab
```

## Files

| File | What it is |
|---|---|
| `kind-config.yaml` | Cluster layout: 1 control-plane + 1 worker node |
| `volcano-values.yaml` | Helm values: Volcano's default scheduler config plus the `reclaim` action |
| `queues.yaml` | Queues `q1` (weight 1, priority 1, reclaimable) and `q2` (weight 2, priority 2, not reclaimable) |
| `pods.sh <queue> <count>` | Keeps exactly `<count>` standalone 1-CPU pods in a queue (adds or removes; Pending pods go first) |
| `status.sh` | Pod counts per queue, plus each queue's weight, priority, reclaimable flag and allocated CPU |
| `gang-job.yaml` | Volcano Job `gang-test` in `q1`: 4 pods of 1 CPU that must start together (`minAvailable: 4`) |
| `q1-deploy.yaml`, `q2-deploy.yaml` | The same workloads as Deployments (one PodGroup for all replicas) |
| `setup.sh` | Runs setup steps 1-3 and 5 in one go; safe to re-run (e.g. after a reboot) |
| `reset.sh` | Deletes all lab workloads and restores the queues; `--delete-cluster` removes the cluster |

## Setup

### 1. Create the cluster

```bash
kind create cluster --name volcano-lab --config kind-config.yaml --kubeconfig ~/.kube/volcano-lab.yaml
export KUBECONFIG=~/.kube/volcano-lab.yaml
kubectl get nodes
```

The lab gets its own kubeconfig file, so `~/.kube/config` (and any production context in it) is never changed.
Repeat the `export` in every new terminal; `pods.sh` and `status.sh` refuse to run unless the current context is
`kind-volcano-lab`.

### 2. Let both nodes run workloads

kind taints the control-plane node so ordinary pods avoid it. Removing the taint gives the lab both nodes' CPUs:

```bash
kubectl taint nodes volcano-lab-control-plane node-role.kubernetes.io/control-plane-
```

### 3. Install Volcano

```bash
helm repo add volcano-sh https://volcano-sh.github.io/helm-charts
helm repo update
helm install volcano volcano-sh/volcano --version 1.15.3 \
  -n volcano-system --create-namespace -f volcano-values.yaml --wait
```

`volcano-values.yaml` keeps the default scheduler config and adds the `reclaim` action, which lets a queue take
back CPUs that another, reclaimable queue has borrowed.

### 4. Look around

```bash
kubectl get pods -n volcano-system      # scheduler, controllers, admission webhook
kubectl get crd | grep volcano          # Queue, PodGroup, Job, ...
kubectl get cm volcano-scheduler-configmap -n volcano-system -o jsonpath='{.data.volcano-scheduler\.conf}'
kubectl describe nodes | grep -A8 -E "^Allocatable|^Allocated resources"
```

The last command shows each node's allocatable and already-requested CPU. The free CPU on both nodes together,
rounded down, is **N**: the number of 1-CPU lab pods the cluster can run at once. The tests below use it.

### 5. Create the queues

```bash
kubectl apply -f queues.yaml
kubectl get queue
```

Besides `q1` and `q2` you will see Volcano's built-in `root` and `default` queues.

## How to test it

Keep a live view open in a second terminal (with the same `export KUBECONFIG=...`):

```bash
while true; do clear; ./status.sh; sleep 2; done
```

and, optionally, the scheduler's decisions in a third:

```bash
kubectl logs -n volcano-system deploy/volcano-scheduler -f | grep -iE "reclaim|evict|overused"
```

**Basic scheduling.** One pod in `q1`; Volcano schedules it and creates a PodGroup for it automatically:

```bash
./pods.sh q1 1
kubectl get pods -l queue=q1 -o wide
kubectl get pg
./pods.sh q1 0
```

**Borrowing and reclaim.** `q1` alone can use the whole cluster. When `q2` then asks for everything too, Volcano
evicts `q1` pods (it is reclaimable) until the split roughly follows the weights 1:2:

```bash
./pods.sh q1 <N>
./pods.sh q2 <N>
kubectl get events --sort-by=.lastTimestamp | grep -i evict
```

**Non-reclaimable queue.** The other way round, `q2` keeps everything it took, because `reclaimable: false`;
the new `q1` pods stay Pending:

```bash
./reset.sh
./pods.sh q2 <N>          # wait until all are Running
./pods.sh q1 <N>
kubectl get pg
```

**Gang scheduling.** With 3 CPUs free, none of the 4 gang pods start; free a 4th CPU and all 4 start together:

```bash
./reset.sh
./pods.sh q2 <N-3>
kubectl apply -f gang-job.yaml
kubectl get vcjob
kubectl get pods -l volcano.sh/job-name=gang-test
./pods.sh q2 <N-4>
```

**Queue changes.** Edit a queue and watch `status.sh`; `kubectl apply -f queues.yaml` puts it back:

```bash
kubectl patch queue q1 --type merge -p '{"spec":{"weight":2}}'
```

**Deployments instead of standalone pods** (`q1-deploy.yaml`, `q2-deploy.yaml`): all replicas share one PodGroup,
so reclaim behaves differently from the `pods.sh` pods, which each get their own:

```bash
kubectl apply -f q1-deploy.yaml -f q2-deploy.yaml
kubectl scale deploy/q1-work --replicas=<N>
kubectl scale deploy/q2-work --replicas=<N>
kubectl get pg
```

## Reset and cleanup

```bash
./reset.sh                    # delete all lab workloads, restore q1/q2 from queues.yaml; cluster stays
./reset.sh --delete-cluster   # delete the kind cluster and ~/.kube/volcano-lab.yaml
```
