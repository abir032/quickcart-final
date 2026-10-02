# QuickCart — The Whole Flow, at a Glance

One reference for the whole project: what each piece is, why it exists, how a change travels from your editor to customers, and the conventions the code follows.

Deeper detail lives in two companion documents:

- [infrastructure-guide.md](infrastructure-guide.md) — every Terraform file and property.
- [jenkins-github-setup.md](jenkins-github-setup.md) — the Jenkins setup log, every problem we hit, and every investigation command explained.
- [eks-argocd-guide.md](eks-argocd-guide.md) — the second way to run it: `compute_platform = "eks"`, Kubernetes on EKS, released by Argo CD (GitOps).

**Contents**

1. [The whole picture in one diagram](#1-the-whole-picture-in-one-diagram)
2. [Why each piece exists](#2-why-each-piece-exists)
3. [Repository layout](#3-repository-layout)
4. [Terraform: stacks, order and state](#4-terraform-stacks-order-and-state)
5. [Terraform conventions: what each part does](#5-terraform-conventions-what-each-part-does)
6. [The modules, one line each](#6-the-modules-one-line-each)
7. [ECS: how the app runs](#7-ecs-how-the-app-runs)
8. [Jenkins: controller, agent, executor, workspace](#8-jenkins-controller-agent-executor-workspace)
9. [CI: proving a change is good](#9-ci-proving-a-change-is-good)
10. [CD: releasing a change](#10-cd-releasing-a-change)
11. [Canary releases](#11-canary-releases)
12. [Rollback](#12-rollback)
13. [scripts/, jobs/ and the shared library](#13-scripts-jobs-and-the-shared-library)
14. [Jenkinsfile conventions](#14-jenkinsfile-conventions)
15. [Shell script conventions](#15-shell-script-conventions)
16. [Docker image](#16-docker-image)
17. [Security](#17-security)
18. [Day-to-day operations and cost](#18-day-to-day-operations-and-cost)
19. [Problems we hit (quick table)](#19-problems-we-hit-quick-table)
20. [Command cheat sheet](#20-command-cheat-sheet)

---

## 1. The whole picture in one diagram

```
 YOU ──git push / PR──► GitHub ──webhook──► JENKINS (EC2, infra/jenkins)
                                              │  reads Jenkinsfile
                                              │
            ┌─────────────── CI (every PR, every branch, main) ───────────────┐
            │ Prepare → Test (flake8, pytest) → Build image → Terraform checks │
            │ PR only: plan dev and post the plan on the PR                    │
            └──────────────────────────────────────────────────────────────────┘
                                              │ main only
            ┌─────────────── CD ───────────────────────────────────────────────┐
            │ Push image to ECR → Deploy dev → Smoke test dev                   │
            │ → Approve (human) → Canary 10% prod → Check → Promote 100% prod   │
            └──────────────────────────────────────────────────────────────────┘
                                              │ terraform apply (release.sh)
                                              ▼
 ┌──────────────────────────── AWS, one environment (dev or prod) ─────────────────────────┐
 │ Route 53  orders.dev.codeemit.com ──► ALB (HTTPS, ACM cert)                              │
 │                                        ├─ 100-w % ─► ECS service "stable" (2+ tasks)     │
 │                                        └─   w %   ─► ECS service "canary" (1 task)       │
 │ VPC: public subnets (ALB, NAT) · app subnets (tasks, ops instance) · data subnets (RDS)  │
 │ RDS MySQL (password in Secrets Manager) · CloudWatch logs + alarms → SNS email           │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
 Account-wide (infra/shared): ECR repository · CloudTrail · Budget
 Terraform state for every stack: S3 bucket qc-tfstate-<account-id>
```

Two journeys to keep in mind:

```
REQUEST: browser → DNS → ALB (HTTPS) → healthy ECS task (port 8080) → MySQL → response

CHANGE:  commit → webhook → Jenkins → tests → image:<commit> → ECR
         → terraform apply (new tag) → ECS rolls tasks → smoke test → (approve) → prod
```

---

## 2. Why each piece exists

Every piece answers a problem. If you know the problem, you know why the piece is there.

| Problem | Piece | Where |
|---|---|---|
| Code must run the same everywhere | Docker image | `app/Dockerfile` |
| Images need a home | ECR repository (immutable tags) | `infra/shared` |
| Something must keep containers running | ECS on Fargate | `modules/compute`, `modules/ecs-service` |
| One copy or one data centre can fail | 2+ tasks across 2 AZs | `desired_count >= 2`, `az_count = 2` |
| Many copies need one address | Application Load Balancer + health check | `modules/compute` |
| Not everything should be internet-facing | VPC: public / app / data subnets | `modules/network` |
| Private tasks must still call out | NAT gateway (+ free S3 endpoint) | `modules/network` |
| Who may talk to whom | Security groups chain | `modules/security-groups`, `database` |
| Data must outlive containers | RDS MySQL | `modules/database` |
| Passwords must never be in code | Secrets Manager + IAM roles | `database`, `platform` |
| A friendly name and HTTPS | Route 53 + ACM certificate | `modules/certificate`, `platform` |
| Knowing when it breaks | Logs, alarms, SNS email, SLO | `modules/monitoring` |
| Traffic spikes | Autoscaling on CPU | `modules/ecs-service` |
| Engineers must reach the private DB safely | Session Manager instance, safe-sql task | `modules/ops-access`, `platform/database.tf` |
| Who changed what, what it costs | CloudTrail, budget | `infra/shared` |
| Build it twice without clicking | Terraform modules + one folder per environment | `infra/` |
| Releasing by hand is risky | Jenkins pipeline, canary, rollback | `Jenkinsfile`, `jobs/` |

---

## 3. Repository layout

```
quickcart-final/                         (GitHub: abir032/quickcart-final)
├── Jenkinsfile              main pipeline — started by the webhook
├── app/                     the Flask API, its tests, its Dockerfile
├── infra/
│   ├── shared/              ROOT  ECR, CloudTrail, budget              (applied by hand, once)
│   ├── jenkins/             ROOT  the Jenkins server                   (applied by hand)
│   ├── envs/dev/us-east-1/  ROOT  dev environment                      (applied by Jenkins)
│   ├── envs/prod/us-east-1/ ROOT  prod environment                     (applied by Jenkins, after approval)
│   └── modules/             CHILD modules, never run directly
├── scripts/                 the actual work, in bash (Jenkins and you both run these)
├── jobs/                    extra Jenkins pipelines started by hand: rollback, safe-sql, extract-logs
├── docs/                    these documents, canary criteria
├── .tflint.hcl, .trivyignore  linter and scanner settings
└── .gitignore               keeps state, .terraform/, your IP's tfvars out of git

quickcart-jenkins-lib/                   (GitHub: abir032/quickcart-jenkins-lib)
└── vars/smokeTest.groovy    shared pipeline step: smokeTest(url, version)
```

---

## 4. Terraform: stacks, order and state

### Four root stacks, four state files, one bucket

| Stack | State key in `qc-tfstate-<account>` | Who applies it | Depends on |
|---|---|---|---|
| `infra/shared` | `shared/terraform.tfstate` | You, once | nothing |
| `infra/jenkins` | `jenkins/terraform.tfstate` | You | nothing |
| `infra/envs/dev/us-east-1` | `envs/dev/us-east-1/...` | Jenkins (`release.sh`) | shared (reads `repository_url`) |
| `infra/envs/prod/us-east-1` | `envs/prod/us-east-1/...` | Jenkins, after approval | shared |

**Why separate stacks:** small blast radius (a bad dev apply can't touch prod), different lifetimes (shared outlives environments), and Jenkins must never apply the stack it runs on.

### Order

```
0. State bucket (made by hand — state can't live in a bucket that doesn't exist yet)
1. shared      — others read its ECR address
2. (push an image to ECR)
3. dev         — needs shared's output and an image that exists
4. prod        — same needs; after dev works
   jenkins     — any time; independent
Destroy in reverse: prod, dev first … shared last.
```

The rule behind it: **you can only use something after it exists.** List what each stack needs from another; a stack that needs nothing goes first.

### State

- State is Terraform's memory: "resource X in the code = real AWS object Y".
- It lives in S3, so **any machine with the code and AWS access** (your laptop, Jenkins) manages the same infrastructure. `terraform init` in a folder connects to that folder's state.
- `use_lockfile = true` stops two applies at once.

### The tag trap

`terraform.tfvars` in dev/prod says `stable_image_tag = "v2"`. Jenkins overrides it with `-var` on every deploy. A plain local `terraform apply` would use `v2` and **roll the environment back**. Locally, use `scripts/release.sh <env-dir>` — it reads the live tags and keeps them.

---

## 5. Terraform conventions: what each part does

### Block types

| Block | Role | Example in this repo |
|---|---|---|
| `terraform { required_version, required_providers, backend }` | Settings: CLI version, provider versions, where state lives | `versions.tf`, `backend.tf` |
| `provider "aws" { region, default_tags }` | Which cloud and region; tags added to everything | root `main.tf` files only |
| `resource "TYPE" "NAME" { }` | **Something Terraform creates, owns and deletes** | `resource "aws_vpc" "this"` |
| `data "TYPE" "NAME" { }` | **Looks up something that already exists; never creates** | `data "aws_route53_zone" "main"` |
| `variable "x" { description, type, default, validation }` | **Input** to a module (a function parameter) | `variable "canary_weight"` |
| `output "x" { description, value }` | **Return value** of a module | `output "alb_url"` |
| `locals { }` | Computed helper values, named once, used many times | `local.name = "qc-dev-use1"` |
| `module "x" { source = "..." ... }` | **Calls another module** (a function call) | `module "network"` |

### Resource vs module

- A **resource** is one real thing in AWS: one VPC, one subnet, one security group. Its address is `TYPE.NAME`, e.g. `aws_vpc.this`; read its attributes as `aws_vpc.this.id`.
- A **module** is a folder of resources packaged behind an interface: **variables in, outputs out**. Calling it is like calling a function: `module "network" { cidr = ... }`, then `module.network.vpc_id`.
- A **root module** is a folder you run `terraform` in (has a backend and state). A **child module** is only ever called by another module.

### File layout per folder (convention, not a Terraform rule)

| File | Contains |
|---|---|
| `versions.tf` | `required_version`, `required_providers` |
| `backend.tf` | `backend "s3"` — root modules only |
| `variables.tf` | Every `variable` |
| `main.tf` | Resources, data sources, module calls (split into more files by topic when large, e.g. `audit.tf`, `database.tf`) |
| `outputs.tf` | Every `output` |
| `terraform.tfvars` | Values for this root's variables — root modules only, loaded automatically |
| `.terraform.lock.hcl` | Exact provider versions — **commit it** |

### Conventions this repo follows

- **`this` for the only resource of its type** in a module: `aws_vpc.this`, `aws_lb.this`. Use a real name when there are several: `aws_subnet.public`, `aws_subnet.app`.
- **Providers only in root modules.** Child modules declare `required_providers` but never `provider` blocks, so the caller decides region and account.
- **Every variable has `description` and `type`;** important ones have `validation` that fails at plan time (`canary_weight` 0–50, no `latest` tags, `desired_count >= 2`).
- **Every output has a `description`.** Roots re-export the child outputs the pipeline needs.
- **One name prefix**, built once: `local.name = "${project}-${environment}-${region_code}"` → `qc-dev-use1`, used on every resource.
- **Tags everywhere:** `default_tags` in the provider, plus `merge(var.tags, { Name = ... })` on resources.
- **Values flow down, results flow up.** Sibling modules never talk directly; the parent passes one module's output into another's input.
- **Dependencies come from references.** `depends_on` only when there's no reference but order still matters (bucket policy before CloudTrail).
- **Comments explain *why***, not what — e.g. why `ignore_changes = [desired_count]`.
- **Accepted security findings are marked in place:** `#trivy:ignore:AWS-xxxx` with a reason above it.

### Meta-arguments and expressions you'll see

| Thing | Meaning |
|---|---|
| `count = cond ? 1 : 0` | Make 0 or N copies — an on/off switch (`module.database`) |
| `for_each = { stable = {...}, canary = {...} }` | One copy per key; `each.key`, `each.value` inside |
| `depends_on = [...]` | Explicit ordering |
| `lifecycle { create_before_destroy / ignore_changes }` | Replacement order; fields Terraform should stop managing |
| `dynamic "block" { for_each ... content {} }` | Generate nested blocks in a loop (or make one optional) |
| `module.x[*].attr` | Splat: list of `attr` from every copy |
| `{ for k, v in m : k => v.arn }` / `[for x in l : x if cond]` | For expressions: build maps/lists |
| `cidrsubnet`, `merge`, `concat`, `lookup`, `jsonencode`, `one`, `slice`, `templatefile` | Built-in functions |

### Commands

| Command | What it does |
|---|---|
| `init` | Download providers, connect to the backend, install modules |
| `fmt` / `validate` | Format / check the code is valid (no AWS) |
| `plan` | Compare code + state + real AWS; show the difference |
| `apply` | Make the difference real, save new state |
| `destroy` | Delete everything in this state |
| `output` | Read saved outputs |
| `state list` | List what the state tracks |
| `test` | Run `*.tftest.hcl` (here against a mocked AWS) |

---

## 6. The modules, one line each

| Module | Creates | Key outputs |
|---|---|---|
| `platform` | Wires every module below into one environment; execution role; DNS record; ops-sql task | `alb_url`, tags, log groups |
| `network` | VPC, 3 subnet tiers × 2 AZs, IGW, NAT, route tables, S3 endpoint | subnet IDs, `vpc_id` |
| `security-groups` | ALB group (443/80 in) and app group (8080 from ALB only) | `alb_id`, `app_id` |
| `certificate` | ACM certificate + DNS validation record; waits until issued | `certificate_arn` |
| `compute` | ECS cluster, ALB, 2 target groups, HTTPS listener with weights, HTTP→HTTPS redirect, access-log bucket | `cluster_arn`, `target_group_arns` |
| `ecs-service` | Log group, task definition, ECS service, CPU autoscaling — called twice | `service_name` |
| `database` | RDS MySQL, its security group, subnet group, parameter group | `address`, `secret_arn` |
| `ops-access` | Small EC2 for Session Manager, no inbound ports | `instance_id`, `security_group_id` |
| `monitoring` | SNS topic + email, SLO error-rate alarm, unhealthy-targets, CPU, DB alarms | `alerts_topic_arn` |

Wiring inside `platform`:

```
network ──vpc, subnets──► security_groups ──sg ids──► compute ◄── certificate
   │                                                     │
   ├──data subnets──► database ◄── app sg, ops sg        ├──cluster, target groups──► orders["stable"], orders["canary"]
   └──app subnet───► ops_access                          └──alb──► route53 record, monitoring
```

---

## 7. ECS: how the app runs

### The four ECS objects

| Object | What it is | Here |
|---|---|---|
| **Cluster** | A named group for services | `qc-dev-use1-cluster` (`modules/compute`) |
| **Task definition** | The recipe: image, CPU/memory, env vars, secrets, logs, port. Every change makes a new **revision** (`:1`, `:2`, …) | `qc-dev-use1-orders`, `...-orders-canary`, `...-ops-sql` |
| **Task** | One running copy of a task definition (one container here) | 2+ stable, 1 canary |
| **Service** | The promise "keep N tasks of this revision running, registered in this target group" | `qc-dev-use1-orders`, `qc-dev-use1-orders-canary` |

**Fargate** means no servers to manage: each task gets its own network interface and private IP in an app subnet (`network_mode = "awsvpc"`).

### The two roles

- **Execution role** (`<name>-exec`, `platform/main.tf`): used by **ECS itself** before your code starts — pull the image from ECR, write logs, read the DB secret.
- **Task role** (`task_role_arn`, null here): used by **your app** while running, if it calls AWS. The app doesn't, so none.

### What happens when a task starts

```
ECS picks an app subnet → creates a network interface (private IP)
→ execution role pulls ECR image <repo>:<tag> (via NAT; layers via the free S3 endpoint)
→ reads DB_USER / DB_PASSWORD from Secrets Manager and injects them as env vars
→ starts gunicorn on :8080, APP_VERSION baked into the image
→ registers the IP in the target group → ALB health-checks /health every 10 s
→ after 2 passes it gets traffic (grace period 30 s while it boots)
→ stdout goes to CloudWatch log group /ecs/<service>
```

### What happens on a deploy (new image tag)

```
terraform apply with stable_image_tag=<new>
→ new task definition revision (image <repo>:<new>)
→ service starts NEW tasks first        (minimum_healthy_percent = 100, maximum = 200)
→ waits until they pass health checks
→ drains and stops OLD tasks            (deregistration delay 30 s)
→ terraform waits for this to finish    (wait_for_steady_state = true)
If new tasks keep crashing → circuit breaker rolls back to the last working revision.
```

### Scaling

- Stable service: `aws_appautoscaling_target` (min = `desired_count`, max = `max_count`) + target-tracking policy at **60% average CPU**; scale out after 60 s, scale in after 300 s.
- `lifecycle { ignore_changes = [desired_count] }`: after creation, autoscaling owns the count — applies won't reset it.
- Canary service: fixed 1 task, no scaling.

### One-off tasks

The `ops-sql` task definition isn't a service. `scripts/safe-sql.sh` starts it with `aws ecs run-task` inside the VPC, waits for it to stop, and reads its exit code — a container that runs one job and ends.

### Where to look

| Question | Where |
|---|---|
| Which version is live? | `curl https://<host>/health` |
| Is the rollout done? | `aws ecs describe-services ... --query 'services[0].deployments'` |
| Why did a request fail? | CloudWatch log group `/ecs/qc-dev-use1-orders` |
| Are targets healthy? | EC2 console → Target groups → Targets |

---

## 8. Jenkins: controller, agent, executor, workspace

```
EC2 "qc-jenkins" (built by infra/jenkins; user-data.sh installs everything)
├── CONTROLLER  — Jenkins program, web UI :8080, receives webhooks,
│                 stores jobs/credentials/plugins/history, reads the Jenkinsfile, schedules
├── BUILT-IN NODE (acts as the agent) — label "linux", 2 executors
│     tools: git, docker, terraform, tflint, trivy, python3, aws CLI
│     AWS access: IAM role qc-jenkins (no stored keys)
├── JENKINS_HOME = /var/lib/jenkins   (all Jenkins data, on the instance's disk)
│     jobs/<job>/branches/<branch>/builds/<n>/{log,build.xml}
│     workspace/quickcart_main, workspace/quickcart_PR-2 …
└── nightly cron: JENKINS_HOME → S3 backup bucket
```

| Term | Meaning |
|---|---|
| Controller | The brain: UI, config, scheduling. Doesn't run `sh` itself |
| Node / agent | A machine that runs builds. Here the controller's own machine (built-in node) |
| Label | A tag on nodes; `agent { label 'linux' }` asks for any node with it |
| Executor | One build slot. 2 here. A build paused at approval still holds one |
| Workspace | The folder where a build checks out code and runs commands |
| Multibranch job | One sub-job per branch and PR, discovered automatically (`quickcart`) |
| Pipeline job | One Jenkinsfile, started by hand with parameters (`quickcart-rollback`) |
| Credential | Stored secret, handed to a build only inside `withCredentials` (`github-token`) |
| Shared library | Groovy steps loaded from another repo (`quickcart-lib`) |

Production differences: controller with 0 executors; separate, often throwaway agents with narrow IAM roles; configuration as code; HTTPS.

**Destroying `infra/jenkins` wipes JENKINS_HOME and the backup bucket** — you'd redo the whole setup (new password, plugins, label, credential, library, jobs, webhook URL). To save money, **stop** the instance instead.

---

## 9. CI: proving a change is good

**Continuous Integration** = every change is automatically built and tested, so problems are found before they reach anyone.

Runs for **every PR, every branch push, and main**:

| # | Stage | Jenkinsfile | What it proves |
|---|---|---|---|
| 1 | Prepare | `:29` | Sets `ACCOUNT_ID`, `REGISTRY`, `IMAGE`, **`IMAGE_TAG` = short commit ID** |
| 2 | Test the app | `:42` | `flake8` style + `pytest` (results shown via `junit`) |
| 3 | Build the image | `:60` | The Dockerfile builds; version baked in |
| 4 | Check the Terraform | `:66` → `scripts/tf-checks.sh` | fmt, validate (all roots, no backend), `terraform test` (14 mocked scenarios), tflint, trivy |
| 5 | Plan dev, post on PR | `:72` (`when { changeRequest() }`) → `scripts/plan-comment.sh` | Shows reviewers exactly what would change in AWS |

Output of CI: a ✓/✗ on the commit or PR in GitHub, and (for PRs) a plan comment. **Nothing is deployed.**

A green build proves only what the tests check — the `/orders/<id>` bug passed CI until tests for it were added.

---

## 10. CD: releasing a change

**Continuous Delivery** = every good change is releasable at the push of a button. **Continuous Deployment** = it's released automatically. This project does **both**: dev is continuous deployment, prod is continuous delivery (a human approves).

Runs on **main only**, after CI:

| # | Stage | Jenkinsfile | What it does |
|---|---|---|---|
| 6 | Push the image | `:86` | ECR login; push `quickcart/orders:<commit>` (skip if it exists; retry 3) |
| 7 | Deploy to dev | `:104` | `release.sh dev --stable <commit> --canary <commit> --weight 0`; records previous version in SSM |
| 8 | Smoke test dev | `:116` | `smokeTest`: `/health` must report `<commit>` |
| 9 | Approve prod canary | `:126` | Plan prod with canary 10% → `prod-canary-plan.txt` → **pause** (30 min) |
| 10 | Canary in production | `:141` | Apply the approved plan; `canary-check.sh` for 5 min; on failure weight → 0 |
| 11 | Promote in production | `:158` | Stable = `<commit>`, weight 0; smoke test |
| — | post | `:174` | SNS email: passed / FAILED |

The deploy chain inside one apply:

```
Jenkinsfile:110 → scripts/release.sh → terraform apply -var stable_image_tag=<commit> …
→ envs/dev main.tf → module platform → platform/main.tf:159 image = "<ecr>:<tag>"
→ ecs-service task definition (new revision) → ECS rolling deploy → wait for steady state
```

Infrastructure changes ride the same path: a merged PR that edits `.tf` files is applied by the same `release.sh` call.

### The three cases

```
PR opened/updated  → 1 2 3 4 5                       nothing deployed; plan posted on PR
Push to a branch   → 1 2 3 4                         nothing deployed
Merge/push to main → 1 2 3 4 6 7 8 → 9 PAUSE → 10 11
```

**Rules learned the hard way:** abort the prod approval if prod doesn't exist (approving builds all of prod); abort it before merging the next PR (one build per branch at a time); don't reuse a branch after its PR is merged.

---

## 11. Canary releases

```
                     ALB HTTPS listener (compute/main.tf:138,143)
              ┌── weight 100-w ──► stable service (2+ tasks, OLD)
 customers ───┤
              └── weight w ──────► canary service (1 task, NEW)
```

- Both services always exist (`platform/main.tf:145–152`). Normally canary = stable version, weight 0.
- A canary release changes two variables: `canary_image_tag = NEW`, `canary_weight = 10`.
- `scripts/canary-check.sh` calls `/orders` every 0.2 s for 5 minutes and uses the **version in each response** to tell canary replies from stable ones.
- **Abort** (weight back to 0 at once) if: canary error rate > 1%, > 5 failures from the load balancer itself, or < 20 canary responses. Written in advance in [canary-criteria.md](canary-criteria.md).
- **Promote** if it passes: stable = NEW.

Why: a bad release reaches ~10% of users for at most 5 minutes and rolls back automatically.

---

## 12. Rollback

Rollback **redeploys an older image that's still in ECR** — nothing is rebuilt. Possible because tags are immutable and ECR keeps 30 images.

`jobs/rollback.Jenkinsfile` (a Pipeline job, run by hand):

| Stage | What it does |
|---|---|
| Check the request | REASON required; `IMAGE_TAG=previous` → read SSM `/quickcart/<env>/previous_stable`; read live tag from state; confirm target exists in ECR |
| Roll back | `release.sh <env> --stable TARGET --canary TARGET --weight 0` |
| Smoke test | `/health` reports TARGET |
| Record it | Save the version you left as `previous_stable` — running again with `previous` undoes it |
| post | SNS email with the reason |

Create it once: New Item → Pipeline → Pipeline script from SCM → repo + `github-token` → branch `*/main` → Script Path `jobs/rollback.Jenkinsfile`. The first run fails on "REASON is required" — that's how Jenkins learns the parameters. Then **Build with Parameters**.

Limits: rollback changes the app, not database data; the next `main` build redeploys latest `main` — the lasting fix is a new commit (e.g. `git revert`).

---

## 13. scripts/, jobs/ and the shared library

```
Jenkinsfile (webhook)          jobs/*.Jenkinsfile (manual)
 :68  tf-checks.sh              rollback      → release.sh
 :78  plan-comment.sh → release.sh            safe-sql      → safe-sql.sh
 :110 :130 :151 :163 release.sh               extract-logs  → extract-logs.sh
 :149 canary-check.sh
 :121 :168 smokeTest()  ◄── quickcart-lib/vars/smokeTest.groovy  ──► also rollback.Jenkinsfile:56
```

| Script | Purpose |
|---|---|
| `tf-checks.sh` | All Terraform checks; also run locally before pushing |
| `release.sh` | **The one way to change what's deployed.** Unspecified settings keep their live values. `--plan-file` = plan only |
| `plan-comment.sh` | Plan dev, post it on the PR |
| `canary-check.sh` | Judge a running canary |
| `safe-sql.sh` | One SQL statement in a transaction via the `ops-sql` task; dry-run rolls back |
| `extract-logs.sh` | CloudWatch logs for a time window → file |

| | `scripts/*.sh` | library `vars/*.groovy` |
|---|---|---|
| Language | Bash | Groovy (Jenkins pipeline) |
| Uses Jenkins steps (`retry`, `error`) | No | Yes |
| Runs without Jenkins | Yes | No |
| Shared across repos | No | Yes |

Split of responsibilities: **Jenkinsfiles decide when and who** (triggers, conditions, approvals, credentials, parameters). **Scripts do the what.** The **library holds pipeline behaviour many projects share.**

---

## 14. Jenkinsfile conventions

### Structure of a declarative pipeline

```groovy
@Library('quickcart-lib') _              // load shared steps first

pipeline {
  agent { label 'linux' }                // where it runs: by label, never by machine name

  options {                              // build-wide safety settings
    timestamps()
    timeout(time: 90, unit: 'MINUTES')   // nothing hangs forever
    disableConcurrentBuilds()            // one build per branch: no two applies racing
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  parameters { ... }                     // manual jobs only: the "Build with Parameters" form

  environment {                          // constants, UPPER_CASE
    AWS_REGION = 'us-east-1'
    DEV_DIR    = 'infra/envs/dev/us-east-1'
  }

  stages {
    stage('Deploy to dev') {             // name says the outcome, readable in the UI
      when { branch 'main' }             // conditions instead of if/else
      steps {
        sh 'scripts/release.sh "$DEV_DIR" --stable "$IMAGE_TAG"'   // logic lives in scripts
      }
      post { always { archiveArtifacts artifacts: 'plan.txt', allowEmptyArchive: true } }
    }
  }

  post {                                 // runs after everything
    success { ... }
    failure { ... }
  }
}
```

### Rules this repo follows

- **Keep logic in scripts.** A stage should be one or two `sh` lines calling `scripts/…`. Long bash inside Groovy is hard to read, test and run locally.
- **Single quotes for `sh`** (`sh 'echo "$IMAGE_TAG"'`): the **shell** expands the variable. Double quotes (`"${env.IMAGE_TAG}"`) make **Groovy** expand it first — use them only for non-secret values you need in Groovy (messages, `input`). Never put a credential inside a double-quoted string; it can leak into logs.
- **Secrets only via `withCredentials { }`**, referenced by ID (`github-token`); Jenkins masks them in logs.
- **`script { }` only when needed** (setting `env.X` from command output, try/catch). Everything else stays declarative.
- **`when` for branching:** `branch 'main'`, `changeRequest()`.
- **Every wait has a limit:** `timeout` around `input`; build-wide `timeout`.
- **Retry only idempotent steps** (`retry(3)` around a push that checks first).
- **Human approval for risky changes:** plan → archive the plan → `input` → apply **that exact plan file**.
- **Archive evidence:** plans, test reports (`junit`), logs.
- **Notify in `post`**, and make notification failures harmless (`|| true`).
- **Required parameters are checked first** (`error('REASON is required.')`) before touching anything.

---

## 15. Shell script conventions

### Template

```bash
#!/usr/bin/env bash
# One line: what this script does.
#
#   scripts/name.sh ARG [--option VALUE]
#
# Needs: ENV_VAR_ONE, ENV_VAR_TWO (what they are)
set -euo pipefail

dir=${1:?usage: name.sh ARG [--option VALUE]}     # required argument, with usage on error
: "${GITHUB_TOKEN:?}" "${GH_REPO:?}"              # required environment variables
cd "$(dirname "$0")/.."                           # work from the repo root, wherever it's called from

vars=()                                           # build argument lists as arrays
[ -n "$tag" ] && vars+=(-var "stable_image_tag=$tag")

echo "Doing X for $dir"                           # say what is happening
terraform -chdir="$dir" apply -input=false "${vars[@]}"
```

### Rules this repo follows

| Rule | Why |
|---|---|
| `#!/usr/bin/env bash` | Finds bash wherever it's installed |
| Header comment with usage and needed variables | The script documents itself |
| `set -euo pipefail` | Stop on the first error (`-e`), on unset variables (`-u`), and when any part of a pipe fails |
| `${1:?usage …}` and `: "${VAR:?}"` | Fail early with a clear message instead of running half-configured |
| Quote every expansion: `"$dir"`, `"${vars[@]}"` | Spaces and empty values don't break commands |
| Arrays for optional arguments | Pass only what's known, safely |
| `-input=false`, `-no-color`, `--output text` | Never wait for keyboard input in automation; clean logs |
| Idempotent where possible (check before push, `--overwrite`) | Safe to retry |
| Non-zero exit = failure, with an `ABORT:` / error message | Jenkins fails the stage; you see why |
| `|| true` only where failure is deliberately harmless | Explicit, not accidental |
| Executable bit committed (`chmod +x`, mode `100755`) | Otherwise exit code 126 |
| Same script works on a laptop and in Jenkins | Debug locally; works when Jenkins is down |

---

## 16. Docker image

```bash
docker build --platform linux/amd64 --provenance=false --build-arg APP_VERSION=<tag> -t <ecr>/quickcart/orders:<tag> app
docker push <ecr>/quickcart/orders:<tag>
```

| Part | Why |
|---|---|
| `--platform linux/amd64` | Fargate tasks are X86_64; a Mac builds ARM by default → `exec format error` |
| `--provenance=false` | One plain image instead of an image index with extra entries |
| `--build-arg APP_VERSION` | `ARG` → `ENV` → `app.py` reports it; smoke tests and canary checks rely on it |
| `-t <registry>/<repo>:<tag>` | The name tells Docker where to push |
| `app` (context) | The folder whose files `COPY` can use; run from the repo root |

Dockerfile highlights: slim Python base; dependencies before code (layer caching); non-root `appuser` (so ports must be ≥ 1024); gunicorn on `0.0.0.0:8080` with graceful shutdown and access logs to stdout.

Pushing by hand needs `aws ecr get-login-password | docker login --username AWS --password-stdin <registry>` first (12-hour token). Jenkins does the same; ECS needs no login — it uses the execution role.

---

## 17. Security

| Item | Status |
|---|---|
| AWS keys, tokens, passwords in git | None. Scanned before every push |
| State files | In private, encrypted S3 — never in git |
| DB password | Generated by RDS, kept in Secrets Manager, injected at task start |
| Your IP (`infra/jenkins/terraform.tfvars`) | Git-ignored |
| Account ID, email, domain in git | Identifiers, not secrets — low risk; keep repos **private** |
| Jenkins reachable from | Your IP and GitHub's webhook ranges only (`api.github.com/meta`) |
| Database reachable from | App and ops security groups only; no route out |
| Engineer access | Session Manager — no SSH, no open ports, logged |

**The real risk we found:** a public repo + PR builds + Jenkins role with AdministratorAccess = a stranger's PR could run code with admin rights. Fixed by making the repos private (or remove fork-PR discovery).

Lab shortcuts to fix in production: AdministratorAccess on Jenkins, HTTP not HTTPS for Jenkins, builds on the controller, one AWS account for everything.

Rule of thumb: a value can go in git if knowing it lets nobody *do* anything. Protection comes from IAM, private buckets and secret storage — not from hiding names.

---

## 18. Day-to-day operations and cost

| Task | How |
|---|---|
| Release | Branch from latest main → PR → green → merge → abort prod approval if prod isn't wanted |
| Check what's live | `curl https://orders.dev.codeemit.com/health` |
| Apply locally (rare) | `scripts/release.sh infra/envs/dev/us-east-1` — never a bare `apply` |
| Roll back | `quickcart-rollback` job, ENVIRONMENT=dev, IMAGE_TAG=`<tag>` or `previous` |
| Pause Jenkins overnight | `aws ec2 stop-instances --instance-ids <id>` (new IP on start → update webhook) |
| Remove dev | `terraform -chdir=infra/envs/dev/us-east-1 destroy` |
| Remove prod | Same with prod (turn off `db_deletion_protection` first if the DB exists) |
| Keep | `infra/shared` — almost free; holds your images |

Approximate cost per day: dev ≈ $3.70 (NAT is the biggest part), Jenkins ≈ $2.25 (`c7i-flex.large`), prod ≈ $3.70, shared ≈ $0.05. Stopped Jenkins ≈ $0.08 (disk only).

Free-plan accounts only launch free-tier-eligible instance types: list them with
`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.

---

## 19. Problems we hit (quick table)

| Symptom | Cause | Fix |
|---|---|---|
| `path "app" not found` | `docker build` run from the wrong folder | Run from the repo root |
| `not eligible for Free Tier` | `t4g.nano` / `t3.medium` on a Free-plan account | `t4g.micro` (ops), `c7i-flex.large` (Jenkins) |
| Jenkins page doesn't load | Boot script died on a removed tflint URL (404) | Download the tflint release zip; re-apply |
| `SessionManagerPlugin is not found` | Plugin missing on the Mac | `brew install --cask session-manager-plugin` |
| Builds stuck in queue | No node with label `linux` | Label the built-in node |
| `exit code 126` | Scripts not executable in git | `chmod +x scripts/*.sh`, commit |
| `Could not update commit status` 403 | Token lacks Commit statuses | Add the permission |
| `curl: (22) … 403` posting plan | Token lacks Issues / Pull requests write | Add the permissions |
| `E302 expected 2 blank lines` | PEP 8 | Two blank lines before a top-level function |
| `/orders/<id>` returns 500 | `get_order` missing; no test | Implement in both repositories + tests |
| Fix not deployed after merge | Previous build held the branch at prod approval | Abort, then Build Now |
| Prod half-built | Approved a canary with no prod; RDS capacity error in us-east-1a/b | `terraform destroy` prod from the laptop |
| Can't open a PR | Branch already merged; fix lost by amend + reset | New branch from latest main, cherry-pick |

Full investigation steps and commands: [jenkins-github-setup.md](jenkins-github-setup.md).

---

## 20. Command cheat sheet

```bash
# who am I / which account
aws sts get-caller-identity

# Terraform for one stack (from the repo root)
terraform -chdir=infra/<stack> init
terraform -chdir=infra/<stack> plan
terraform -chdir=infra/<stack> output
terraform -chdir=infra/<stack> state list
scripts/release.sh infra/envs/dev/us-east-1            # safe local apply (keeps live tags)
scripts/tf-checks.sh                                   # the pipeline's Terraform checks

# images
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
aws ecr describe-images --repository-name quickcart/orders --query 'sort_by(imageDetails,&imagePushedAt)[].imageTags[0]' --output text

# is the app up, which version
curl https://orders.dev.codeemit.com/health
curl https://orders.dev.codeemit.com/orders/2

# Jenkins server
terraform -chdir=infra/jenkins output                  # url, webhook url, instance id
aws ssm start-session --target <instance_id>           # shell (needs the plugin)
sudo cat /var/lib/jenkins/secrets/initialAdminPassword # first login only
aws ec2 stop-instances  --instance-ids <instance_id>
aws ec2 start-instances --instance-ids <instance_id>

# ECS
aws ecs describe-services --cluster qc-dev-use1-cluster --services qc-dev-use1-orders \
  --query 'services[0].[taskDefinition,deployments[0].rolloutState]' --output text

# app logs (last 30 minutes, errors)
aws logs filter-log-events --log-group-name /ecs/qc-dev-use1-orders \
  --start-time $(( ($(date +%s) - 1800) * 1000 )) --filter-pattern '"Error"' \
  --query 'events[].message' --output text

# git: one branch per change
git checkout main && git pull && git checkout -b <change-name>
```
