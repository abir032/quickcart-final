# EKS + Argo CD — The Second Way to Run QuickCart

The same app and the same AWS foundation, run a second way: **Kubernetes on EKS**, released by **Argo CD** using **GitOps**. One setting picks the platform:

```hcl
# infra/envs/<env>/us-east-1/terraform.tfvars
compute_platform = "ecs"   # ECS on Fargate, released by Terraform  (Jenkinsfile)
compute_platform = "eks"   # EKS, released by Argo CD from Git     (Jenkinsfile.eks)
```

Read [quickcart-reference.md](quickcart-reference.md) first — this guide only covers what's different. For a one-page overview with Kubernetes and Argo CD explained, see [eks-reference.md](eks-reference.md).

**Contents**

1. [The big idea: push vs pull](#1-the-big-idea-push-vs-pull)
2. [The architecture](#2-the-architecture)
3. [What changed in the code](#3-what-changed-in-the-code)
4. [ECS → Kubernetes, object by object](#4-ecs--kubernetes-object-by-object)
5. [The GitOps repository](#5-the-gitops-repository)
6. [CI and CD on EKS, step by step](#6-ci-and-cd-on-eks-step-by-step)
7. [Setting it up](#7-setting-it-up)
8. [Day to day: release, watch, roll back](#8-day-to-day-release-watch-roll-back)
9. [Tearing it down](#9-tearing-it-down)
10. [Cost](#10-cost)
11. [Troubleshooting](#11-troubleshooting)
12. [What's not here yet](#12-whats-not-here-yet)

---

## 1. The big idea: push vs pull

| | ECS pipeline (`Jenkinsfile`) | EKS pipeline (`Jenkinsfile.eks`) |
|---|---|---|
| Who changes what's running | **Jenkins**, by running `terraform apply` | **Argo CD**, running *inside* the cluster |
| How a release is requested | `release.sh` passes `-var stable_image_tag=<commit>` | Jenkins **commits** the new tag to the GitOps repo |
| Model | **Push**: CI reaches into production | **Pull**: the cluster pulls its desired state from Git |
| Jenkins needs production access | Yes (AdministratorAccess) | **No** — only ECR push and Git write |
| What's running = | whatever the last apply did | **whatever Git says**, always |
| Someone changes something by hand | stays changed until next apply | **Argo CD undoes it** (self-heal) |
| Audit trail of releases | Jenkins build history | **Git history**: every release is a commit |
| Rollback | redeploy an old tag with Terraform | **`git revert`** the release commit |

**GitOps in one sentence:** Git holds the desired state; a controller in the cluster keeps comparing the cluster with Git and fixes any difference.

```
            ┌───────────── reconciliation loop (every ~3 min, forever) ─────────────┐
            ▼                                                                        │
  read desired state from Git  →  read live state from cluster  →  differ?  ──yes──► apply the difference
  (quickcart-gitops)              (Deployments, Ingress, …)          │no
                                                                     └─► nothing to do
```

---

## 2. The architecture

```
  YOU ──push / PR──► GitHub: quickcart-final ──webhook──► JENKINS (Jenkinsfile.eks)
                                                             │ CI: test, build, Terraform checks
                                                             │ CD: push image to ECR
                                                             │     commit "Deploy <tag> to dev"
                                                             ▼
                                                   GitHub: quickcart-gitops
                                                             ▲ watches (pull)
 ┌──────────────────────────── AWS, one environment ─────────┼─────────────────────────────────────┐
 │  EKS cluster qc-dev-use1-eks (control plane run by AWS)   │                                     │
 │   nodes: managed node group, private app subnets          │                                     │
 │   ├─ argocd            Argo CD ───────────────────────────┘  renders charts/orders, applies it   │
 │   ├─ kube-system       AWS Load Balancer Controller → builds the ALB from the Ingress            │
 │   ├─ external-dns      ExternalDNS → writes orders.dev.<zone> in Route 53                        │
 │   ├─ external-secrets  External Secrets → copies the RDS secret into a Kubernetes Secret         │
 │   └─ orders            Deployment (pods) · Service · Ingress · HPA · PDB · ExternalSecret        │
 │                                                                                                  │
 │  Same as ECS: VPC (public/app/data), NAT, RDS MySQL + Secrets Manager, ACM cert, alarms → SNS    │
 └──────────────────────────────────────────────────────────────────────────────────────────────────┘

 REQUEST: browser → Route 53 (ExternalDNS) → ALB (made by the controller, HTTPS with the ACM cert)
          → pod IP (target-type ip) → app :8080 → MySQL
```

**Who builds what**

| Layer | Built by | Changes how often |
|---|---|---|
| VPC, RDS, EKS cluster, nodes, IAM, controllers, Argo CD | **Terraform** (`infra/`) | rarely |
| The app: Deployment, Service, Ingress, HPA | **Argo CD**, from `quickcart-gitops` | every release |
| ALB, target group, listeners | **AWS Load Balancer Controller**, from the Ingress | when the Ingress changes |
| DNS record `orders.dev.<zone>` | **ExternalDNS**, from the Ingress host | when the host changes |
| Kubernetes Secret `orders-db` | **External Secrets**, from Secrets Manager | hourly refresh |

---

## 3. What changed in the code

### The switch — `infra/modules/platform`

```hcl
locals {
  is_ecs = var.compute_platform == "ecs"
  is_eks = var.compute_platform == "eks"
}

module "compute" { count = local.is_ecs ? 1 : 0 ... }   # ECS cluster + Terraform-made ALB
module "orders"  { for_each = { for k, v in local.ecs_services : k => v if local.is_ecs } ... }
module "eks"     { count = local.is_eks ? 1 : 0 ... }   # EKS + controllers + Argo CD
```

| Piece | ECS | EKS | Why |
|---|---|---|---|
| `network`, `certificate`, `database`, `ops_access` | ✔ | ✔ | Same foundation |
| `security_groups`, `compute`, `orders`, execution role, ops-sql task, Route 53 record | ✔ | – | ECS-only; on EKS controllers do this |
| `eks` | – | ✔ | New module |
| Database allowed from | app SG | **cluster SG** (pods use the node security group) | `local.db_clients` |
| `monitoring` ALB/service alarms | ✔ | – | Terraform doesn't own the EKS ALB (`enable_service_alarms`) |
| `monitoring` database alarms | ✔ | ✔ | |

Validations stop bad combinations at plan time: `eks` needs `enable_nat`, a `gitops_repo_url` and `eks_public_access_cidrs`; the API may never be open to `0.0.0.0/0`.

### The new module — `infra/modules/eks`

| File | Creates |
|---|---|
| `main.tf` | Cluster IAM role · KMS key (encrypts Kubernetes Secrets) · control-plane log group · **EKS cluster** (API restricted to your IP, access entries) · node IAM role · **managed node group** · core add-ons (vpc-cni, kube-proxy, coredns, pod-identity-agent, metrics-server) |
| `identities.tf` | One IAM role per controller, bound to its ServiceAccount with **EKS Pod Identity**: LB controller, ExternalDNS (one zone only), External Secrets (one secret only) |
| `addons.tf` | Helm releases: AWS Load Balancer Controller, ExternalDNS, External Secrets, **Argo CD**, and the **Argo CD Application** for the app |
| `policies/aws-load-balancer-controller.json` | The controller's official IAM policy (v3.5.0) |

### The root stacks — `infra/envs/*/us-east-1`

- `compute_platform` and the EKS variables, passed to `platform`.
- A **Helm provider** that signs in to the cluster with `aws eks get-token` (unused on ECS).
- Outputs `compute_platform`, `eks_cluster_name`, `kubeconfig_command`.

### CI/CD — `quickcart-final`

| File | Purpose |
|---|---|
| `Jenkinsfile.eks` | The EKS pipeline |
| `scripts/gitops-bump.sh` | Changes `image.tag` in `envs/<env>/values.yaml` of the GitOps repo, commits, pushes (also the rollback tool) |

### Tests — `infra/modules/platform/tests/platform.tftest.hcl`

Six new runs: ECS is the default; EKS replaces every ECS piece; EKS keeps only the two database alarms; EKS requires the GitOps repo and API CIDRs; EKS requires NAT; the API can't be opened to the internet. All 20 runs pass.

---

## 4. ECS → Kubernetes, object by object

| Job | ECS (Terraform) | Kubernetes (GitOps chart) |
|---|---|---|
| What to run | Task definition | `Deployment` pod template |
| Keep N running | ECS service | `Deployment` + ReplicaSet |
| One copy | Task | Pod |
| Rolling update | `minimum_healthy_percent = 100` | `maxUnavailable: 0`, `maxSurge: 1` |
| Auto-rollback | Circuit breaker | `progressDeadlineSeconds` marks it failed; rollback = revert in Git |
| Scaling copies | Application Auto Scaling (CPU 60%) | `HorizontalPodAutoscaler` (CPU 60%) + metrics-server |
| Scaling servers | Not needed (Fargate) | Node group min/max (add Karpenter or Cluster Autoscaler to automate) |
| Health → traffic | ALB health check | `readinessProbe` (+ ALB health check) |
| Health → restart | ECS replaces failing tasks | `livenessProbe` |
| Load balancer | `modules/compute` (Terraform) | `Ingress` + AWS Load Balancer Controller |
| DNS record | `aws_route53_record.site` (Terraform) | ExternalDNS, from the Ingress host |
| DB password | ECS `secrets` from Secrets Manager | `ExternalSecret` → Secret → `secretKeyRef` |
| AWS permissions for the app/controllers | Task / execution role | Pod Identity role per ServiceAccount |
| Graceful stop | `deregistration_delay`, gunicorn timeout | `preStop sleep 10` + target group deregistration delay |
| Keep a copy during maintenance | — | `PodDisruptionBudget` |
| Pod hardening | Non-root image | Plus read-only root filesystem, no privilege escalation, all capabilities dropped |

---

## 5. The GitOps repository

`abir032/quickcart-gitops` (local folder `../quickcart-gitops`):

```
charts/orders/          the Helm chart (templates: deployment, service, ingress, hpa, pdb, externalsecret)
envs/dev/values.yaml    image.tag for dev       — Jenkins updates it on every merge
envs/prod/values.yaml   image.tag for prod      — Jenkins updates it after approval
```

**Three sources of values, each owning different keys:**

| Source | Owns | Changed by |
|---|---|---|
| `charts/orders/values.yaml` | Defaults (resources, probes' targets, CPU target) | People, by PR |
| `envs/<env>/values.yaml` | **`image.tag`**, per-env overrides | **Jenkins** (tag), people (the rest) |
| Argo CD Application (`helm.valuesObject`, from Terraform) | `image.repository`, `host`, `certificateArn`, `database.*`, `aws.region`, autoscaling min/max | **Terraform** |

Why the split: Terraform knows things Git can't (the RDS address, the secret's ARN, the certificate ARN). Git owns what changes per release (the tag). Keeping their keys separate means it's always clear who set a value.

**Why a separate repository:**
- Jenkins's deploy commits don't trigger the app pipeline again (no loop).
- Argo CD gets read access to one small repo, not to the app's source.
- Release history = this repo's history, uncluttered by code changes.

---

## 6. CI and CD on EKS, step by step

### What happens on a merge to `main`

```
1  Prepare                 IMAGE_TAG = short commit ID                                  ┐
2  Test the app            flake8 + pytest                                              │ CI — identical
3  Build the image         docker build …:<commit>                                      │ to the ECS pipeline
4  Check the Terraform     tf-checks.sh                                                 ┘
5  Push the image          ECR
6  Release to dev          scripts/gitops-bump.sh dev <commit>
                             → clone quickcart-gitops, set envs/dev image.tag, commit, push
   ── Jenkins is done touching dev. From here, the cluster works on its own: ──
   a. Argo CD polls Git (~3 min), sees envs/dev/values.yaml changed → app is "OutOfSync"
   b. Argo CD renders charts/orders with the new tag, applies the Deployment
   c. Kubernetes starts a new pod; it pulls the image from ECR (node role)
   d. readinessProbe passes → ALB target group registers the pod IP
   e. an old pod is removed (preStop sleep, deregistration delay) → repeat until all new
   f. Argo CD reports "Synced, Healthy"
7  Wait for Argo CD in dev  smokeTest: /health must report <commit> (waits up to ~10 min)
8  Approve production       a person clicks
9  Release to production    gitops-bump.sh prod <commit>, then smokeTest on prod
   post                     SNS email
```

On a **pull request** or a **branch**: steps 1–4 only. (No PR plan comment in this pipeline: planning would need cluster access, and keeping Jenkins out of the cluster is the point.)

### The three Git repositories, and who writes to them

| Repo | Written by | Read by |
|---|---|---|
| `quickcart-final` (code, Terraform, pipelines) | You | Jenkins |
| `quickcart-jenkins-lib` (smokeTest) | You | Jenkins |
| `quickcart-gitops` (what runs) | **Jenkins** (tags), you (everything else) | **Argo CD** |

### Infrastructure changes

Terraform is applied **by hand** for EKS (like `shared` and `jenkins`), because only identities with cluster access can apply it — and Jenkins deliberately has none. Change `.tf` → PR (CI checks it) → merge → `terraform apply` from your laptop.

---

## 7. Setting it up

Starting from: `shared` applied, an image in ECR, Jenkins running with the `github-token` credential and `quickcart-lib` library. (Destroy any ECS dev first, or use another environment — one platform per environment.)

### Step 1 — Create the GitOps repository

1. On GitHub create an **empty, private** repo `abir032/quickcart-gitops`.
2. Push the local folder:
   ```bash
   cd ../quickcart-gitops
   git remote add origin git@github-p:abir032/quickcart-gitops.git
   git push -u origin main
   ```
3. Set `envs/dev/values.yaml` → `image.tag` to a tag that **exists in ECR** (e.g. the one you pushed by hand).

### Step 2 — Tokens

- **Jenkins** writes the tag: edit the existing fine-grained token → add repository `quickcart-gitops` → **Contents: Read and write**.
- **Argo CD** reads the repo: create a **second** fine-grained token, only `quickcart-gitops`, **Contents: Read-only**. Read-only, so a leak can't change production.

### Step 3 — Switch dev to EKS

`infra/envs/dev/us-east-1/terraform.tfvars`:

```hcl
compute_platform = "eks"

eks_public_access_cidrs = ["<your-public-ip>/32"]   # curl https://checkip.amazonaws.com
gitops_repo_url         = "https://github.com/abir032/quickcart-gitops.git"
eks_node_scaling        = { min = 1, desired = 2, max = 3 }
```

### Step 4 — Apply (from your laptop)

```bash
terraform -chdir=infra/envs/dev/us-east-1 init
terraform -chdir=infra/envs/dev/us-east-1 plan      # read it: EKS, node group, add-ons, Helm releases; no ECS
terraform -chdir=infra/envs/dev/us-east-1 apply     # ~20–25 minutes: the cluster takes ~10, RDS ~10
```

The identity that runs this first apply becomes cluster admin.

### Step 5 — Connect kubectl

```bash
$(terraform -chdir=infra/envs/dev/us-east-1 output -raw kubeconfig_command)
kubectl get nodes                                # 2 nodes, Ready
kubectl get pods -A                              # argocd, kube-system, external-dns, external-secrets
```

### Step 6 — Give Argo CD read access to the GitOps repo

The token is created in the cluster by hand, so it is never in Terraform state or Git:

```bash
kubectl -n argocd create secret generic quickcart-gitops-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/abir032/quickcart-gitops.git \
  --from-literal=username=x-access-token \
  --from-literal=password='<argo-cd-read-only-token>'
kubectl -n argocd label secret quickcart-gitops-repo argocd.argoproj.io/secret-type=repository
```

Argo CD picks it up automatically; within ~3 minutes the `orders` app syncs.

### Step 7 — Check it

```bash
kubectl -n argocd get applications                  # orders   Synced   Healthy
kubectl -n orders get deploy,pods,svc,ingress,hpa
kubectl -n orders get externalsecret                # orders-db   SecretSynced
curl https://orders.dev.<zone>/health               # the tag from envs/dev/values.yaml
```

The ALB and DNS record take 2–3 minutes after the Ingress appears.

**Argo CD UI:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8443:443
# open https://localhost:8443  — user admin
```

### Step 8 — The Jenkins job

New Item → `quickcart-eks` → **Multibranch Pipeline** → GitHub source `quickcart-final`, credential `github-token` → **Script Path: `Jenkinsfile.eks`** → Save.

Run **one** of the two jobs (`quickcart` for ECS, `quickcart-eks` for EKS) — whichever matches `compute_platform`. Delete or disable the other so a push doesn't trigger both.

---

## 8. Day to day: release, watch, roll back

**Release:** branch → PR (CI) → merge → `quickcart-eks » main` → dev updates by itself → approve → prod.

**Watch a rollout:**

```bash
kubectl -n argocd get application orders -w
kubectl -n orders rollout status deploy/orders
kubectl -n orders get pods -L app.kubernetes.io/version
```

**Roll back** — change Git, not the cluster:

```bash
# option 1: revert the release commit in quickcart-gitops
git -C ../quickcart-gitops revert <deploy-commit> && git -C ../quickcart-gitops push

# option 2: point at an older tag
GITHUB_TOKEN=<token> GITOPS_REPO=abir032/quickcart-gitops scripts/gitops-bump.sh dev 8ec8c5e
```

Don't `kubectl set image` or roll back in the Argo CD UI: self-heal puts back whatever Git says within minutes. That's the feature, not a bug — Git is the only way in.

**Change settings** (memory, CPU target): edit `envs/<env>/values.yaml` or the chart in a PR to `quickcart-gitops`. Merging it is the deployment.

---

## 9. Tearing it down

```bash
terraform -chdir=infra/envs/dev/us-east-1 destroy
```

What happens, in order: the Argo CD Application is removed → Argo CD deletes the app (Ingress included) → the load balancer controller deletes the ALB, ExternalDNS deletes the record → a 150-second pause (`time_sleep.app_cleanup`) lets that finish → controllers, Argo CD, nodes, cluster, then the VPC.

If the VPC fails to delete with a dependency error, an ALB or security group made by the controller was left behind:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[?starts_with(LoadBalancerName,`k8s-`)].LoadBalancerArn'
aws ec2 describe-security-groups --filters Name=tag:elbv2.k8s.aws/cluster,Values=qc-dev-use1-eks --query 'SecurityGroups[].GroupId'
```

Delete those, then run `destroy` again. The KMS key enters a 7-day deletion window (then it's gone).

Order across stacks is unchanged: environments → jenkins → shared.

---

## 10. Cost

Per day in dev, roughly:

| Item | ECS | EKS |
|---|---|---|
| Control plane | — | $2.40 |
| Compute | Fargate tasks ~$0.90 | 2 × c7i-flex.large nodes ~$4.10 |
| NAT, ALB, RDS, ops instance, IPs | ~$2.70 | ~$2.70 |
| KMS key, logs | — | ~$0.10 |
| **Total** | **≈ $3.70** | **≈ $9.30** |

`eks_node_scaling = { min = 1, desired = 1, max = 2 }` saves ~$2/day (one node, no spread across zones). On the AWS Free plan, check EKS is allowed before applying; node types must be free-tier eligible (`c7i-flex.large` is).

---

## 11. Troubleshooting

| Symptom | Likely cause | Look at |
|---|---|---|
| First `plan`/`apply` fails connecting to Kubernetes | Helm provider can't reach a cluster that doesn't exist yet | Apply in two steps: `terraform apply -target=module.platform.module.eks[0].aws_eks_addon.this`, then a full `apply` |
| `kubectl` times out | Your IP changed; API allows only `eks_public_access_cidrs` | Update the CIDR, `apply` |
| App `Unknown` / `ComparisonError` in Argo CD | Argo CD can't read the GitOps repo | Step 6 secret; token scope |
| Pods `ImagePullBackOff` | Tag not in ECR | `aws ecr describe-images …` |
| Pods `CreateContainerConfigError` | Secret `orders-db` missing | `kubectl -n orders describe externalsecret orders-db` |
| No ALB / Ingress has no address | Controller problem | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| DNS name doesn't resolve | ExternalDNS problem | `kubectl -n external-dns logs deploy/external-dns` |
| Jenkins waits at "Wait for Argo CD" then fails | Argo CD hasn't synced or rollout stuck | `kubectl -n argocd get app orders`, `kubectl -n orders rollout status deploy/orders` |
| `gitops-bump.sh` push rejected (403) | Jenkins token lacks Contents write on `quickcart-gitops` | Token permissions |

---

## 12. What's not here yet

Honest limits of this version — good next steps:

- **Canary.** Releases are rolling updates with an approval. Add **Argo Rollouts**: replace the Deployment with a `Rollout` that sends 10% → checks metrics → 100%, aborting automatically (what `canary-check.sh` did for ECS).
- **Node autoscaling.** The HPA adds pods; nothing adds nodes when they're full. Add **Karpenter**.
- **Load balancer alarms.** Terraform doesn't own the EKS ALB, so the SLO alarm isn't created. Add CloudWatch alarms keyed on the controller's ALB tags, or Prometheus.
- **App-of-apps.** One Argo CD Application created by Terraform. Larger setups let Argo CD manage its own Applications (and the controllers) from Git too.
- **Safe-SQL job on EKS.** The ECS `ops-sql` task has no Kubernetes equivalent here; it would be a Kubernetes `Job` (and `ops-access` still works for manual access).
- **Not yet applied to a real account.** The code passes `terraform validate`, all 20 `terraform test` runs, trivy, `helm lint` and a full chart render, and the bump script was tested against a local Git repo — but the first real `apply` is where provider and timing details show up. Expect to iterate once.
