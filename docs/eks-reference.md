# QuickCart on EKS — The Whole Flow, at a Glance

The EKS + Argo CD version of QuickCart in one place: how Kubernetes works, how Argo CD works, how a change reaches customers, and how to run it.

Companion documents:

- [quickcart-reference.md](quickcart-reference.md) — the ECS version and everything both share (network, database, Terraform, Jenkins basics).
- [eks-argocd-guide.md](eks-argocd-guide.md) — what changed in the code, detailed setup, troubleshooting.

**Contents**

1. [The whole picture](#1-the-whole-picture)
2. [The one idea: desired state and reconciliation](#2-the-one-idea-desired-state-and-reconciliation)
3. [Kubernetes in detail](#3-kubernetes-in-detail)
4. [What EKS adds to Kubernetes](#4-what-eks-adds-to-kubernetes)
5. [The controllers we install](#5-the-controllers-we-install)
6. [Helm](#6-helm)
7. [Argo CD in detail](#7-argo-cd-in-detail)
8. [The three repositories](#8-the-three-repositories)
9. [Journeys: first build, a release, a request](#9-journeys-first-build-a-release-a-request)
10. [CI and CD on EKS](#10-ci-and-cd-on-eks)
11. [ECS vs EKS, side by side](#11-ecs-vs-eks-side-by-side)
12. [Security model](#12-security-model)
13. [Conventions](#13-conventions)
14. [How to run it](#14-how-to-run-it)
15. [Cheat sheet](#15-cheat-sheet)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. The whole picture

```
 YOU ──push/PR──► quickcart-final ──webhook──► JENKINS  (Jenkinsfile.eks)
                                                 │ CI: test · build image · Terraform checks
                                                 │ CD: push image to ECR ─────────────────────────┐
                                                 │     commit "Deploy <tag> to dev" ──┐            │
                                                 ▼                                    ▼            ▼
                                            (done)                         quickcart-gitops       ECR
                                                                                 ▲                  ▲
 ┌──────────────────────────── AWS · dev ────────────────────────────────────── │ ──────────────── │ ──┐
 │ EKS control plane (run by AWS): API server · etcd · scheduler · controllers   │ pull Git         │   │
 │                                                                               │                  │   │
 │ Nodes (managed node group, private app subnets)                               │                  │   │
 │  ├─ argocd            Argo CD ────────────────────────────────────────────────┘                  │   │
 │  │                       renders charts/orders + envs/dev/values.yaml, applies it                │   │
 │  ├─ kube-system       vpc-cni · kube-proxy · coredns · metrics-server · pod-identity-agent       │   │
 │  │                    AWS Load Balancer Controller ──► creates the ALB                           │   │
 │  ├─ external-dns      ExternalDNS ──► writes orders.dev.<zone> in Route 53                       │   │
 │  ├─ external-secrets  External Secrets ──► Secret "orders-db" from Secrets Manager              │   │
 │  └─ orders            Deployment ─► pods (image pulled from ECR) ────────────────────────────────┘   │
 │                       Service · Ingress · HPA · PDB · ExternalSecret                                 │
 │                                                                                                      │
 │ Shared with ECS: VPC (public / app / data), NAT, RDS MySQL, ACM certificate, DB alarms → SNS         │
 └──────────────────────────────────────────────────────────────────────────────────────────────────────┘

 REQUEST: browser → Route 53 → ALB (HTTPS) → pod IP :8080 → MySQL
```

### Inside EKS only

Everything that makes up the cluster, where it physically runs, and who talks to whom. (Jenkins and Git are outside; Argo CD is their only link in.)

```
┌──────────────────────── AWS-MANAGED (AWS's account — you never see these machines) ────────────────────────┐
│  EKS CONTROL PLANE  qc-dev-use1-eks        (≈ $0.10/hour, spread over 3 zones, patched by AWS)              │
│                                                                                                             │
│   kube-apiserver ◄──────── every request in the cluster goes through here ─────────────────┐               │
│        │                                                                                    │               │
│   etcd  (desired state: all applied YAML; Secrets encrypted with your KMS key)              │               │
│   kube-scheduler  (picks a node for each new pod)                                           │               │
│   controller-manager  (built-in loops: Deployment → ReplicaSet → Pods, …)                   │               │
│                                                                                             │               │
│   endpoints:  public  ◄── only eks_public_access_cidrs (your laptop: kubectl, terraform)    │               │
│               private ◄── network interfaces placed in your app subnets (nodes, pods) ──────┘               │
└──────────────────────────────────────────────────┬──────────────────────────────────────────────────────────┘
                                                   │ private endpoint
┌───────────────────────────────────────────── YOUR VPC ─────────────────────────────────────────────────────┐
│                                                                                                             │
│  PUBLIC SUBNETS (a, b)                                                                                      │
│    ALB  k8s-orders-…  ◄── created by the AWS Load Balancer Controller from the Ingress                       │
│     │ 443 (ACM cert) · 80 → 443 · health check /health · targets = pod IPs                                  │
│    NAT gateway ──► internet (ECR, AWS APIs, GitHub for Argo CD)                                             │
│     │                                                                                                       │
│  APP SUBNETS (private)                                                                                      │
│  ┌─────────────── NODE 1 · EC2 · zone a ───────────────┐   ┌─────────────── NODE 2 · EC2 · zone b ───────┐  │
│  │ on every node (DaemonSets / system):                 │   │ same system pieces                           │  │
│  │   kubelet       runs and checks this node's pods     │   │                                              │  │
│  │   containerd    pulls images, runs containers        │   │                                              │  │
│  │   kube-proxy    Service IP → pod IP routing          │   │                                              │  │
│  │   aws-node      VPC CNI: real VPC IP for every pod   │   │                                              │  │
│  │   pod-identity  hands pods their IAM credentials     │   │                                              │  │
│  │                                                      │   │                                              │  │
│  │ pods (spread by the scheduler):                      │   │                                              │  │
│  │   orders/orders-…   app :8080      ◄─── ALB ─────────┼───┼─► orders/orders-…   app :8080                │  │
│  │   argocd/application-controller, repo-server, …      │   │   argocd/server, redis                       │  │
│  │   kube-system/aws-load-balancer-controller           │   │   kube-system/coredns, metrics-server        │  │
│  │   external-dns/external-dns                          │   │   external-secrets/external-secrets          │  │
│  └──────────────────────────────────────────────────────┘   └──────────────────────────────────────────────┘  │
│            │ pods → MySQL :3306 (cluster security group allowed)                                              │
│  DATA SUBNETS (no route out)                                                                                │
│    RDS MySQL qc-dev-use1-db                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

AWS services the cluster calls (each with its own Pod Identity role, no keys):
  ECR             ◄── node role (pull images)
  ELB API         ◄── aws-load-balancer-controller (create/update the ALB)
  Route 53        ◄── external-dns (one zone only)
  Secrets Manager ◄── external-secrets (one secret only)
  CloudWatch Logs ◄── control plane (api, audit, authenticator logs)
```

**Who talks to whom, numbered:**

```
 1  you ──kubectl/terraform──► API server (public endpoint, your IP only)
 2  Argo CD ──git clone──► quickcart-gitops (via NAT)          → renders the Helm chart
 3  Argo CD ──apply──► API server (private endpoint)           → Deployment, Service, Ingress, HPA, …
 4  controller-manager: Deployment → ReplicaSet → pod objects
 5  scheduler: assigns each pod to a node
 6  kubelet on that node: containerd pulls the image from ECR (node role, via NAT/S3 endpoint), starts it
 7  aws-node gives the pod a VPC IP; readinessProbe → Ready
 8  LB controller sees the Ingress → creates the ALB, registers Ready pod IPs
 9  ExternalDNS sees the Ingress host → Route 53 record → the ALB
10  External Secrets sees the ExternalSecret → reads Secrets Manager → Secret orders-db → pod env
11  metrics-server → HPA: adds/removes pods on CPU
12  customer → Route 53 → ALB → pod IP → RDS
```

**Who decides vs who executes:**

| Role | Component | Decides / does |
|---|---|---|
| Source of truth | Git (`quickcart-gitops`) | *What* should run |
| CD (deploys) | **Argo CD** | Makes the cluster match Git |
| Orchestrator | **Kubernetes** (API server, scheduler, controllers, kubelet) | *How* it runs: places pods, rolls updates, restarts failures |
| Platform | **EKS** | Runs Kubernetes for you: control plane, node lifecycle, add-ons, IAM integration |
| AWS bridges | LB controller, ExternalDNS, External Secrets | Turn Kubernetes objects into ALB, DNS, Secrets |
| Machines | EC2 nodes (managed node group) | CPU and memory for every pod |

Who owns what:

| Layer | Owner | Lives in |
|---|---|---|
| VPC, RDS, EKS cluster, nodes, IAM, controllers, Argo CD | **Terraform** | `quickcart-final/infra` |
| The app's Kubernetes objects | **Argo CD** | `quickcart-gitops` |
| Which image version runs | **Git** (Jenkins writes it) | `quickcart-gitops/envs/<env>/values.yaml` |
| The image itself | **ECR** (Jenkins pushes it) | `quickcart/orders:<tag>` |
| ALB, DNS record, DB Secret | **Controllers**, from Kubernetes objects | AWS / the cluster |

---

## 2. The one idea: desired state and reconciliation

Everything in Kubernetes — and Argo CD on top of it — works the same way:

```
   you declare WHAT you want  ──►  a controller compares it with WHAT IS  ──►  fixes the difference
                                         ▲                                            │
                                         └──────────── forever, in a loop ────────────┘
```

| Controller | Wants (desired state) | Watches (actual state) | Fixes by |
|---|---|---|---|
| Deployment controller | "3 pods of image v5" | running pods | starting / stopping pods |
| HPA | "average CPU 60%" | pod CPU | changing the replica count |
| AWS Load Balancer Controller | the Ingress | the ALB in AWS | creating / updating the ALB |
| ExternalDNS | the Ingress host | Route 53 records | writing the record |
| External Secrets | the ExternalSecret | the Kubernetes Secret | copying from Secrets Manager |
| **Argo CD** | **the Git repository** | **the cluster** | **applying Git to the cluster** |

You never say "do this step". You say "this is how it should be", and controllers keep making it so. That's why manual changes get undone and why a crashed pod comes back by itself.

---

## 3. Kubernetes in detail

### The cluster

```
CONTROL PLANE (on EKS: run by AWS, you never see the machines)
  kube-apiserver         the front door — every kubectl call, every controller talks to it
  etcd                   the database of desired state (all the YAML you applied)
  kube-scheduler         picks a node for each new pod
  controller-manager     the built-in controllers (Deployments, ReplicaSets, …)

NODES (on EKS: EC2 instances in your managed node group)
  kubelet                starts and watches the pod's containers on this node
  container runtime      pulls the image, runs the container (containerd)
  kube-proxy             routes Service traffic to pods
  aws-node (vpc-cni)     gives each pod a real VPC IP address
```

### Objects used in this project

| Object | What it is | Here |
|---|---|---|
| **Namespace** | A folder for objects; names are unique per namespace | `orders`, `argocd`, `kube-system`, `external-dns`, `external-secrets` |
| **Pod** | One or more containers that run together, with one IP. The smallest unit. Disposable. | one `app` container |
| **Deployment** | "Keep N pods of this template running; replace them gradually when the template changes" | `orders` |
| **ReplicaSet** | Created by the Deployment, one per version of the template; does the actual counting | one per release |
| **Service** | A stable name and virtual IP in front of whichever pods match its selector | `orders` → port 80 → pods :8080 |
| **Ingress** | HTTP routing rules from outside into Services — turned into an ALB by a controller | `orders` (host, TLS, health check) |
| **HorizontalPodAutoscaler** | Changes the Deployment's replica count to hit a CPU target | 2–4 pods at 60% CPU |
| **PodDisruptionBudget** | "Never voluntarily take down more than this" — protects during node upgrades | `minAvailable: 1` |
| **Secret / ConfigMap** | Key–value data for pods; Secret for sensitive values | `orders-db` (username, password) |
| **ServiceAccount** | An identity for pods; mapped to an IAM role with Pod Identity | one per controller |
| **CustomResourceDefinition (CRD)** | Adds new object types to Kubernetes | `Application` (Argo CD), `ExternalSecret`, `SecretStore` |

### Labels and selectors — how objects find each other

Nothing is linked by name alone. Objects find each other by **labels**:

```yaml
# deployment.yaml — pods are created with this label
template:
  metadata:
    labels: { app.kubernetes.io/name: orders }

# service.yaml — the Service sends traffic to any pod with this label
selector: { app.kubernetes.io/name: orders }
```

A new pod with the label joins the Service automatically; a deleted one leaves.

### What happens when the image tag changes (rolling update)

```
Deployment template changes (image :v5 → :v6)
→ Deployment creates a NEW ReplicaSet (v6) with 0 pods
→ maxSurge: 1        → v6 ReplicaSet scales to 1 → scheduler picks a node → kubelet pulls :v6 from ECR
→ readinessProbe passes (GET /health = 200)  → pod becomes "Ready" → Service + ALB start sending it traffic
→ maxUnavailable: 0  → only now is one v5 pod removed:
     preStop: sleep 10 (ALB stops sending new requests) → SIGTERM → gunicorn finishes in-flight requests
→ repeat until v6 has all pods and v5 has 0
→ the old ReplicaSet is kept (revisionHistoryLimit: 5) — rollback material
If v6 never becomes ready within progressDeadlineSeconds (300 s): rollout marked failed, v5 keeps serving.
```

### Probes

| Probe | Question | On failure | Here |
|---|---|---|---|
| **readiness** | "Can it receive traffic now?" | Removed from Service/ALB, not restarted | `GET /health` every 10 s |
| **liveness** | "Is it stuck?" | Container restarted | `GET /health` every 20 s after 15 s |

`/health` never touches the database: a slow database must not make every pod look dead.

### Two layers of scaling

| Layer | Here | What it does |
|---|---|---|
| Pods | **HPA** + metrics-server | 2 → 4 pods when CPU > 60% |
| Nodes | Node group min/max (fixed) | Nothing adds nodes automatically yet — Karpenter would |

### Resources

`requests` = what the scheduler reserves on a node (100m CPU = 0.1 CPU, 128Mi). `limits` = the ceiling (256Mi; above it the container is killed and restarted). HPA percentages are relative to the request.

---

## 4. What EKS adds to Kubernetes

| EKS piece | What it gives you | Where |
|---|---|---|
| **Managed control plane** | AWS runs API server and etcd across 3 zones, patches and backs them up. ~$73/month. | `aws_eks_cluster` |
| **Managed node group** | EC2 nodes AWS creates, joins and upgrades one at a time | `aws_eks_node_group` |
| **VPC CNI** | Every pod gets a real VPC IP → the ALB can target pods directly (`target-type: ip`), security groups apply | add-on `vpc-cni` |
| **Access entries** | Maps an IAM user/role to Kubernetes permissions (the creator is admin) | `access_config`, `aws_eks_access_entry` |
| **Pod Identity** | An IAM role for a ServiceAccount — pods get AWS permissions without keys | `eks-pod-identity-agent`, `aws_eks_pod_identity_association` |
| **Secrets encryption** | Kubernetes Secrets in etcd encrypted again with your KMS key | `encryption_config` |
| **Control plane logs** | API, audit, authenticator logs in CloudWatch | `enabled_cluster_log_types` |
| **Managed add-ons** | AWS-maintained versions of core components | `aws_eks_addon` |

Two kinds of identity, never mixed up:

```
IAM  ── "who are you in AWS?"        → access entry → Kubernetes RBAC ── "what may you do in the cluster?"
Pod  ── ServiceAccount               → Pod Identity → IAM role       ── "what may this pod do in AWS?"
```

---

## 5. The controllers we install

| Controller | Watches | Does in AWS | IAM permission (Pod Identity) |
|---|---|---|---|
| **AWS Load Balancer Controller** | `Ingress` (class `alb`) | Creates the ALB, listeners (80→443 redirect, 443 with the ACM cert), target group with pod IPs, security group rules | Official policy (`policies/aws-load-balancer-controller.json`) |
| **ExternalDNS** | `Ingress` hosts | Writes `orders.dev.<zone>` → ALB in Route 53, plus a TXT ownership record; deletes it when the Ingress goes (`policy: sync`) | Change records in **one** zone |
| **External Secrets** | `ExternalSecret` | Reads the RDS secret in Secrets Manager, writes Kubernetes Secret `orders-db`, refreshes hourly | Read **one** secret |
| **metrics-server** | Pods | Collects CPU/memory for the HPA | none |
| **Argo CD** | `Application` + Git | Applies the app (next sections) | none — works only inside the cluster |

On ECS, Terraform did the first three jobs directly. On EKS, Terraform installs the controllers and Kubernetes objects drive them.

---

## 6. Helm

Helm is a **template engine + package format** for Kubernetes YAML.

```
chart (templates with {{ .Values.x }})  +  values (YAML)  ──helm template──►  plain Kubernetes YAML
```

| Term | Here |
|---|---|
| Chart | `quickcart-gitops/charts/orders` (and the controllers' public charts) |
| Templates | `templates/deployment.yaml`, `service.yaml`, … |
| Values | `values.yaml` (defaults) + `envs/<env>/values.yaml` + Terraform's `valuesObject` |
| Release | An installed chart. Terraform installs controller charts with `helm_release`. |

**Values precedence for the app (later wins):**

```
charts/orders/values.yaml        defaults
envs/dev/values.yaml             image.tag (Jenkins), per-env overrides (people)
Application valuesObject          image.repository, host, certificateArn, database.*, aws.region,
                                  autoscaling min/max (Terraform)
```

Argo CD runs the Helm rendering itself (`helm template`), then applies the result. There is no "Helm release" for the app in the cluster — Argo CD tracks it.

The chart refuses to render with missing essentials (`fail` in `deployment.yaml` and `ingress.yaml`), so a misconfigured Application shows an error instead of deploying something broken.

---

## 7. Argo CD in detail

### Components (namespace `argocd`)

| Component | Job |
|---|---|
| **application-controller** | The reconciler: compares live cluster state with rendered Git state, syncs, computes health |
| **repo-server** | Clones Git repositories and renders manifests (runs Helm) |
| **server** | API and web UI (reached with `kubectl port-forward`) |
| **redis** | Cache |
| **applicationset-controller** | Generates many Applications from templates (not used yet) |

Dex (SSO) and notifications are switched off to save resources.

### The Application — Argo CD's unit of work

Created by Terraform (`helm_release.argocd_apps` in `modules/eks/addons.tf`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: orders
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]   # delete the app's objects when this is deleted
spec:
  project: default
  source:                                                  # WHERE the desired state is
    repoURL: https://github.com/abir032/quickcart-gitops.git
    targetRevision: main
    path: charts/orders
    helm:
      valueFiles: [../../envs/dev/values.yaml]
      valuesObject: { image: {repository: …}, host: …, certificateArn: …, database: {…} }
  destination:                                             # WHERE to apply it
    server: https://kubernetes.default.svc                 # this same cluster
    namespace: orders
  syncPolicy:
    automated: { prune: true, selfHeal: true }             # HOW
    syncOptions: [CreateNamespace=true]
```

### Statuses

| Sync status | Meaning |
|---|---|
| **Synced** | The cluster matches Git |
| **OutOfSync** | Git and the cluster differ (new commit, or a manual change) |
| Unknown | Argo CD can't read Git or render the chart (credentials, chart error) |

| Health status | Meaning |
|---|---|
| **Healthy** | All objects are fine (Deployment fully rolled out, Ingress has an address) |
| **Progressing** | Rolling out / waiting for the ALB |
| **Degraded** | Something failed (rollout past its deadline, pods crashing) |
| Missing | Object should exist but doesn't yet |

A release normally goes: Synced+Healthy → **OutOfSync** → sync → **Progressing** → Synced+Healthy.

### Sync policy options

| Option | Effect | Here |
|---|---|---|
| `automated` | Sync as soon as Git changes (no button) | on |
| `prune` | Delete objects that were removed from Git | on |
| `selfHeal` | Undo manual changes made in the cluster | on |
| `CreateNamespace=true` | Create `orders` if missing | on |
| Manual sync | Only sync when someone clicks / runs `argocd app sync` | off (could be used for prod as an approval) |

### How Argo CD notices a change

- **Polling** every ~3 minutes (default). Used here.
- **Git webhook** → Argo CD server: near-instant. Needs the Argo CD server reachable from GitHub (not exposed here).
- **Manual refresh** in the UI or `kubectl -n argocd annotate application orders argocd.argoproj.io/refresh=normal`.

### Self-heal in practice

```
kubectl -n orders set image deploy/orders app=…:v1     # someone "hotfixes" by hand
→ live ≠ Git → OutOfSync → selfHeal → Argo CD re-applies Git → back to the Git tag
```

The only lasting way to change production is a commit. That gives you review, history and rollback for free.

### Rollback

| Method | GitOps-friendly? |
|---|---|
| `git revert <deploy-commit>` in `quickcart-gitops`, or `scripts/gitops-bump.sh <env> <older-tag>` | ✔ the right way |
| Argo CD UI "History and rollback" | Only with auto-sync off — otherwise Git wins again |
| `kubectl rollout undo` | ✘ undone by self-heal |

### Deleting

Deleting the Application (Terraform destroy) → the **finalizer** makes Argo CD delete everything it deployed first → the Ingress goes → the controller deletes the ALB → ExternalDNS deletes the record. `time_sleep.app_cleanup` gives that 150 s before the controllers themselves are removed.

### Where it can grow

- **App of apps / ApplicationSet**: Argo CD manages its own Applications from Git (and the controllers too), instead of Terraform creating them.
- **Argo Rollouts**: canary and blue/green steps with automatic analysis.
- **Image Updater**: watches ECR and writes new tags to Git itself.
- **Projects** (`AppProject`): limit which repos and namespaces a team's apps may use.

---

## 8. The three repositories

| Repo | Contents | Written by | Read by |
|---|---|---|---|
| `quickcart-final` | App code, Terraform, `Jenkinsfile.eks`, scripts | You | Jenkins |
| `quickcart-jenkins-lib` | `smokeTest` | You | Jenkins |
| `quickcart-gitops` | Helm chart, `envs/*/values.yaml` | Jenkins (tags), you (rest) | **Argo CD** |

Why the GitOps repo is separate: Jenkins's tag commits don't retrigger the app pipeline; Argo CD needs read access to one small repo only; release history is clean.

---

## 9. Journeys: first build, a release, a request

### First build (`terraform apply` on dev)

```
VPC, NAT, subnets ─► RDS (+ secret) ─► ACM certificate
                 ─► EKS cluster (~10 min) ─► node group ─► core add-ons
                 ─► Pod Identity roles ─► Helm: LB controller, ExternalDNS, External Secrets, Argo CD
                 ─► Helm: argocd-apps → Application "orders"
Then, inside the cluster (after you add the repo secret):
  Argo CD clones quickcart-gitops → renders the chart → applies to namespace orders
  External Secrets creates Secret orders-db
  Deployment starts 2 pods (pull :v2 from ECR) → Ready
  LB controller builds the ALB → ExternalDNS writes orders.dev.<zone>
  Application: Synced, Healthy
```

### A release (merge to main)

```
Jenkins: test → build :<commit> → push to ECR → commit envs/dev tag = <commit>
Argo CD (≤3 min): OutOfSync → render → apply Deployment with :<commit>
Kubernetes: rolling update (section 3) → Synced, Healthy
Jenkins: smokeTest sees /health version = <commit> → approve → same for prod
```

### A request

```
https://orders.dev.<zone>/orders
→ Route 53 alias (written by ExternalDNS) → ALB (built by the LB controller)
→ HTTPS terminated with the ACM cert → target group of pod IPs (only Ready pods)
→ pod :8080 → gunicorn → Flask → MySQL (DB_USER/DB_PASSWORD from Secret orders-db)
```

---

## 10. CI and CD on EKS

| # | Stage | Kind | Notes |
|---|---|---|---|
| 1 | Prepare | CI | `IMAGE_TAG` = short commit |
| 2 | Test the app | CI | flake8, pytest |
| 3 | Build the image | CI | |
| 4 | Check the Terraform | CI | Includes the EKS module and its tests |
| 5 | Push the image | CD (main) | ECR — image must exist **before** Git points at it |
| 6 | Release to dev | CD | `gitops-bump.sh dev <tag>` |
| 7 | Wait for Argo CD in dev | CD | smoke test, up to ~10 min |
| 8 | Approve production | CD | a person |
| 9 | Release to production | CD | bump prod, smoke test |

PRs and branches run 1–4. Jenkins never talks to the cluster. Terraform for EKS is applied by hand from a laptop.

**Jenkins does CI; Argo CD does CD.** Argo CD can't test or build — it only makes the cluster match Git. Any CI tool works in Jenkins's place (GitHub Actions is the usual partner).

---

## 11. ECS vs EKS, side by side

| | ECS (`compute_platform = "ecs"`) | EKS (`"eks"`) |
|---|---|---|
| Release mechanism | Terraform `-var` image tag (push) | Commit to Git, Argo CD syncs (pull) |
| Pipeline | `Jenkinsfile` | `Jenkinsfile.eks` |
| Jenkins needs prod access | yes | no |
| App definition | Terraform (`ecs-service`) | Helm chart (`quickcart-gitops`) |
| Load balancer | Terraform | AWS Load Balancer Controller |
| DNS record | Terraform | ExternalDNS |
| DB password | ECS secrets injection | External Secrets → Secret |
| Scaling pods / tasks | App Auto Scaling | HPA |
| Scaling servers | Fargate (none) | Node group (manual min/max) |
| Canary | ✔ two services + ALB weights | not yet (Argo Rollouts) |
| ALB alarms | ✔ | not yet |
| Rollback | `release.sh` old tag | `git revert` |
| Drift (manual changes) | stays until next apply | undone automatically |
| Dev cost/day | ≈ $3.70 | ≈ $9.30 |

---

## 12. Security model

| Concern | How it's handled |
|---|---|
| Cluster API exposure | Public endpoint limited to `eks_public_access_cidrs` (your IP); never `0.0.0.0/0` (validated) |
| Who is admin | The identity that created the cluster + `eks_admin_principal_arns` (access entries) |
| AWS permissions for pods | Pod Identity: one role per controller, scoped (one zone, one secret) |
| Node permissions | Join cluster, pod networking, **read** ECR — nothing else |
| Secrets at rest | RDS secret in Secrets Manager; Kubernetes Secrets encrypted with KMS |
| Secrets in Git / state | None. Argo CD's repo token is created with `kubectl`, not Terraform |
| Pods | Non-root (uid 1001), read-only root filesystem, no privilege escalation, all capabilities dropped, seccomp default |
| CI blast radius | Jenkins can push images and write the GitOps repo — it can't touch the cluster |
| Argo CD token | Read-only on the GitOps repo |
| Network | Pods in private subnets; DB allows only the cluster SG and ops SG |

Lab shortcuts: API public to your IP (production: private endpoint + VPN), no NetworkPolicies, single node group.

---

## 13. Conventions

### Kubernetes YAML / Helm

- One object type per template file, named after it (`service.yaml`, `hpa.yaml`).
- Standard labels `app.kubernetes.io/name|part-of|version` from one helper (`_helpers.tpl`); selectors use only the stable `name` label (selectors can't change later).
- No `replicas` when an HPA owns the count.
- Always set probes, resource requests, a memory limit, a security context, and a PDB.
- Annotations configure controllers (`alb.ingress.kubernetes.io/*`), not code.
- `fail` early on missing required values.
- Comments say *why* (e.g. why `maxUnavailable: 0`).

### GitOps

- Git is the only way to change what runs. No `kubectl edit` in shared environments.
- One file per environment for release settings; the tag line has a marker comment so tools can change it safely.
- Separate owners per value source (defaults / env file / Terraform).
- Image pushed before the tag is committed.
- Every deploy commit says what and from what: `Deploy a1b2c3d to dev (was 9f8e7d6)`.

### Terraform for EKS

- Platform (cluster + controllers) in Terraform; apps in Git.
- Pin chart versions (`chart_versions`) and the Kubernetes version.
- Explicit ordering around destroy (finalizer + `time_sleep`) because controllers create AWS resources Terraform doesn't know about.

---

## 14. How to run it

Prerequisites: `aws`, `terraform`, `docker`, `kubectl`; this branch merged to `main`.

```
Phase A — EKS + Argo CD by hand
  A1  check identity and tools; note your IP
  A2  terraform apply infra/shared                    (ECR, CloudTrail, budget)
  A3  build + push quickcart/orders:v2                (ECR is empty after a fresh shared)
  A4  dev tfvars: compute_platform = "eks", eks_public_access_cidrs, gitops_repo_url
  A5  terraform apply infra/envs/dev/us-east-1        (~20–25 min)
  A6  aws eks update-kubeconfig …; kubectl get nodes
  A7  kubectl create secret … (Argo CD read-only repo token) + label
  A8  watch: Application Synced/Healthy; curl /health → v2
  A9  push :v3, change envs/dev tag, commit → watch Argo CD roll it out

Phase B — add Jenkins
  B1  terraform apply infra/jenkins; redo the UI setup
  B2  github-token: + quickcart-gitops Contents read/write
  B3  Multibranch job quickcart-eks, Script Path Jenkinsfile.eks; webhook
  B4  change → PR → merge → watch dev update itself; Abort at prod approval

Teardown: dev → jenkins → shared
```

Exact commands: [eks-argocd-guide.md §7](eks-argocd-guide.md#7-setting-it-up).

---

## 15. Cheat sheet

```bash
# connect
$(terraform -chdir=infra/envs/dev/us-east-1 output -raw kubeconfig_command)

# what's running
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n orders get deploy,rs,pods,svc,ingress,hpa,pdb
kubectl -n orders get pods -L app.kubernetes.io/version      # which version each pod runs

# details and logs
kubectl -n orders describe pod <pod>                          # events: pulls, probes, scheduling
kubectl -n orders logs deploy/orders --tail=50
kubectl -n orders rollout status deploy/orders
kubectl -n orders rollout history deploy/orders
kubectl get events -n orders --sort-by=.lastTimestamp

# Argo CD
kubectl -n argocd get applications
kubectl -n argocd describe application orders                 # conditions, sync result
kubectl -n argocd annotate application orders argocd.argoproj.io/refresh=normal --overwrite   # check Git now
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8443:443

# controllers
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
kubectl -n external-dns logs deploy/external-dns --tail=50
kubectl -n orders get externalsecret,secretstore

# release / roll back (from quickcart-final)
GITHUB_TOKEN=<token> GITOPS_REPO=abir032/quickcart-gitops scripts/gitops-bump.sh dev <tag>

# render the chart locally (what Argo CD will apply)
helm template orders ../quickcart-gitops/charts/orders -f ../quickcart-gitops/envs/dev/values.yaml -f <infra-values.yaml>
```

---

## 16. Troubleshooting

| Symptom | Where to look | Usual cause |
|---|---|---|
| Application `Unknown` | `describe application orders` | Argo CD can't read the repo (A7 secret) or the chart fails to render |
| `OutOfSync` that never syncs | Application conditions | Render error, or a resource Argo CD can't apply |
| Pods `Pending` | `describe pod` → Events | Not enough node capacity (raise `eks_node_scaling`) |
| `ImagePullBackOff` | `describe pod` | Tag not in ECR |
| `CreateContainerConfigError` | `describe pod`, `get externalsecret` | Secret `orders-db` not created yet / ESO permission |
| `CrashLoopBackOff` | `logs` | App error, DB unreachable |
| Pods running, not Ready | `describe pod` (readiness) | `/health` failing |
| Ingress has no ADDRESS | LB controller logs | Subnet tags, certificate ARN, IAM |
| DNS name doesn't resolve | ExternalDNS logs | Zone permission, host outside the zone |
| `kubectl` times out | — | Your IP changed; update `eks_public_access_cidrs` |
| Jenkins fails at "Wait for Argo CD" | Application + rollout status | Sync didn't happen or rollout stuck |
| `destroy` stuck on the VPC | `aws elbv2 describe-load-balancers` | Leftover `k8s-*` ALB or security group — delete, re-run |
