# QuickCart Infrastructure Guide

A learning guide to this project's infrastructure: **why** each piece exists, **how** the pieces connect, and **what** every Terraform file and property does.

- **Part 1 — The big picture:** the problems we are solving, in plain English.
- **Part 2 — Terraform in this project:** folder structure, how files connect, and a module-by-module reference.
- **Part 3 — Doing it yourself:** how to work out what a new project needs.

---

# Part 1 — The big picture

## The one question behind everything

You understand the app: code that listens on a port and answers API requests. Everything else in this project answers one question:

> **How do strangers on the internet use my app — reliably, safely, cheaply — and how do I update it without breaking it?**

Every piece of infrastructure exists because of a specific problem. Learn the problems, and the pieces follow.

## The story: one problem at a time

You have an orders API running on your laptop at `localhost:8080`. It works. Your boss says: "Customers need to use this."

### Problem 1 — "My laptop can't be the server."

A laptop sleeps, moves, and has no fixed address. We need an always-on computer in a data centre — AWS.

But "copy my code to a server and run it" is fragile: a different language version, missing libraries, and so on.

**Solution: package the app as a container image (Docker).** The image contains the code plus everything it needs, so it runs the same everywhere.

**New problem:** the image needs to be stored somewhere AWS can download it from.
**Solution: ECR, the image registry** (in `infra/shared/`). It is shared because dev and prod run the *same* images — build once, promote the same image. Each image has a tag (`v2`, or a commit ID) so you always know exactly which version is running.

### Problem 2 — "Something must run my container and restart it if it crashes."

You could rent a virtual machine and run `docker run` by hand, but if it crashes at 3am, nobody restarts it.

**Solution: ECS on Fargate.** You tell AWS "always keep 2 copies of this image running", and it does.

- **Task definition** — the recipe: which image, how much CPU and memory, which environment variables.
- **Service** — the promise: "keep N of these running."
- **Cluster** — a folder grouping services.
- **Fargate** — you never manage a server at all.

### Problem 3 — "One copy is a single point of failure."

If the one container dies, or the whole data centre has a power problem, the site is down.

**Solution: run at least 2 copies, in 2 different data centres.** AWS calls these **Availability Zones (AZs)** — separate buildings in the same region. This is why the code enforces `desired_count >= 2` and `az_count >= 2`.

### Problem 4 — "There are 2 copies. Which one do customers call?"

Each container has its own private IP, and it changes whenever a container restarts. Customers need **one** stable address.

**Solution: a load balancer (ALB)** — the front door. Customers talk to the ALB; the ALB spreads requests across healthy copies.

- It calls `/health` on each copy every 10 seconds and stops sending traffic to broken ones — the **health check**.
- The **target group** is the ALB's list of "copies I may send to."

### Problem 5 — "I don't want everything exposed to the internet."

If containers and the database have public IPs, attackers can hit them directly and skip the front door.

**Solution: a private network (VPC), split into zones of trust.** Think of an office building:

| Building part | Subnet tier | What lives there | Reachable from the internet? |
|---|---|---|---|
| Lobby | **public** | load balancer | Yes |
| Offices | **app** | your containers | No — only through the lobby |
| Vault | **data** | database | No — and it cannot call out either |

Each tier exists once per AZ, which is why there are 6 subnets.

**Route tables** are the signposts deciding where traffic from each subnet may go. Public subnets point to the **Internet Gateway** (the building's door to the street). Data subnets point nowhere.

### Problem 6 — "My private containers can't download anything."

App-tier containers have no public IP, but they still need to *call out*: download their image, send logs, read secrets.

**Solution: a NAT gateway** — a one-way door. Traffic can go out and replies come back, but nobody outside can start a connection in. It costs about $32 a month, so there is a switch (`enable_nat`) to turn it off in cheap setups.

The **S3 endpoint** is a free private path for image downloads (image layers are stored in S3), which saves NAT data charges.

### Problem 7 — "Even inside my network, who may talk to whom?"

**Solution: security groups — firewalls around each component.** They form a chain:

```
Internet ──443/80──► ALB ──8080──► containers ──3306──► database
```

Each group only accepts traffic from the group before it. Even if an attacker lands inside the VPC, they still cannot reach the database.

### Problem 8 — "My app needs to remember orders."

Containers are disposable: when one restarts, anything stored inside it is gone. Data must live somewhere permanent.

**Solution: a managed database (RDS MySQL)** in the vault (data subnets). AWS handles backups, patching, encryption, and optionally a standby copy in a second AZ (`multi_az`).

**New problem:** the app needs the database password, but passwords must never be in code or Git.
**Solution: Secrets Manager.** RDS generates the password and stores it there. When a container starts, ECS reads the secret and injects it as an environment variable. No human ever sees it.

The **IAM execution role** is the permission slip allowing ECS to read that secret (and pull the image, and write logs). In AWS, nothing is allowed unless a role says so.

### Problem 9 — "Customers can't type `qc-dev-alb-12345.elb.amazonaws.com`, and traffic isn't encrypted."

**Solution:**

- **Route 53 (DNS):** `orders.example.com` points at the ALB.
- **ACM certificate:** HTTPS — the padlock in the browser. ACM proves you own the domain by asking for a special DNS record, which Terraform creates automatically.
- The **HTTP listener** redirects `http://` to `https://`.

### Problem 10 — "How do I know when it's broken?"

You can't watch it all day.

- **Logs (CloudWatch):** what each container printed — *why* it broke.
- **ALB access logs (S3):** every request, with path, status and timing — *which* requests failed.
- **Alarms + SNS email:** "more than 0.5% of requests failed in 5 minutes", "a container is unhealthy", "database disk almost full" — *that* it broke, before customers complain.
- **SLO (for example 99.5%):** the promise you make — at most 0.5% of requests may fail. The main alarm watches exactly that promise.

### Problem 11 — "Black Friday: traffic goes up five times."

Two copies can't cope.

**Solution: autoscaling.** When average CPU passes 60%, AWS adds copies, up to `max_count`. When traffic calms down, it removes them. `max_count` also caps the bill.

### Problem 12 — "An engineer needs to fix bad data in the database."

The database is deliberately in the vault with no internet access. The old answer was a "bastion" server with SSH open to the world — risky.

**Solution:**

- A tiny **ops instance** reached through **Session Manager**: no open ports, no SSH keys, every session logged.
- The **ops-sql task**: a one-off container that runs a single SQL statement inside a transaction. "Dry-run" mode rolls back; "commit" mode saves.

### Problem 13 — "Who changed what? And how much is this costing?"

- **CloudTrail:** records every action anyone takes in the AWS account — a security camera.
- **Budget:** emails you when spending passes 80% of the limit.

Both are account-wide, so they live in `infra/shared/`.

### Problem 14 — "I need all of this twice (dev and prod), and I can't click 80 things in the console."

Building by hand is slow, error-prone, unreviewable, and impossible to reproduce exactly.

**Solution: Terraform — infrastructure as code.** You *describe* what should exist; Terraform makes reality match.

- **Same code, different settings** gives dev and prod. That is why dev and prod are identical files with different `terraform.tfvars`.
- **Modules** are reusable building blocks, one per problem above: network, security groups, compute, and so on.
- **State** is Terraform's memory of what it built, stored in S3 so the team and Jenkins share it.
- **Separate stacks** (`shared`, `jenkins`, `dev`, `prod`) mean a mistake in one cannot destroy another.

### Problem 15 — "Releasing new versions by hand is scary."

Building, pushing, updating dev, testing, updating prod by hand means forgotten steps — or a broken version reaching every customer.

**Solution: a CI/CD pipeline (Jenkins).** On every `git push`:

1. Test the app, build the image, push it to ECR.
2. Deploy to **dev**, then run a smoke test ("does it answer?").
3. A human approves a production **canary**: the new version gets only **10%** of traffic. If it misbehaves, only 10% of users notice, and it is rolled back automatically.
4. **Promote** the new version to 100%.
5. If something goes wrong later, the **rollback job** restores the previous version.

This is why the ALB has two target groups (stable and canary), and why a release is just changing three Terraform variables: the stable tag, the canary tag and the canary weight.

Jenkins itself needs a server — the `infra/jenkins/` stack.

## The two journeys

If you can explain these two journeys, you understand the architecture.

**Journey of one customer request:**

```
Customer opens https://orders.example.com/orders
  → DNS (Route 53): "that name is the load balancer"
  → ALB (public subnet): terminates HTTPS, picks a healthy container
        (90% stable / 10% canary during a release)
  → Security group allows ALB → container on port 8080
  → Container (private app subnet) runs the API code
  → Container queries MySQL (private data subnet); password injected from Secrets Manager
  → Response travels back the same way
  → Logs and metrics are recorded; alarms watch the error rate
```

**Journey of one code change:**

```
git push
  → Jenkins: test → build image → push to ECR (tag = commit ID)
  → terraform apply dev (new tag) → ECS replaces containers one at a time → smoke test
  → human approves → terraform apply prod (canary at 10%) → watch error rate
  → promote to 100%   (or set weight to 0 = instant rollback)
```

## The whole architecture

```
                         Internet
                            │
                    Route 53 (DNS) + ACM (HTTPS)
                            │
┌──────────────────────── VPC (one per environment) ────────────────────────┐
│                                                                            │
│   AZ a                                   AZ b                              │
│  ┌──────────── public ─────────────┐   ┌──────────── public ─────────┐     │
│  │  ALB node      NAT gateway      │   │  ALB node                   │     │
│  └─────────────────────────────────┘   └─────────────────────────────┘     │
│  ┌──────────── app ────────────────┐   ┌──────────── app ────────────┐     │
│  │  orders task(s)   ops instance  │   │  orders task(s)             │     │
│  └─────────────────────────────────┘   └─────────────────────────────┘     │
│  ┌──────────── data ───────────────┐   ┌──────────── data ───────────┐     │
│  │  RDS MySQL (primary)            │   │  (standby if multi_az)      │     │
│  └─────────────────────────────────┘   └─────────────────────────────┘     │
└────────────────────────────────────────────────────────────────────────────┘

Account-wide (shared):  ECR image registry · CloudTrail · Budget
Separate (jenkins):     Jenkins server · backup bucket · pipeline notifications
Per environment:        CloudWatch logs + alarms · SNS email · Secrets Manager
```

---

# Part 2 — Terraform in this project

## 2.1 Five core ideas

**1. A folder is a module.** Terraform reads every `.tf` file in a folder and merges them. File names (`main.tf`, `variables.tf`) are only convention — you could put everything in one file.

**2. Root module vs child module.**

- **Root module:** a folder where you run `terraform init/plan/apply`. It has its own state file.
- **Child module:** a folder you never run directly. Another module calls it with `module "x" { source = "..." }` — like calling a function.

**3. The block types used here:**

| Block | Think of it as | Purpose |
|---|---|---|
| `terraform {}` | settings | Terraform version, providers, backend |
| `provider "aws" {}` | driver | Which cloud, which region, default tags |
| `resource "type" "name" {}` | create | Something Terraform creates and owns |
| `data "type" "name" {}` | read | Looks up something that already exists; never creates it |
| `variable "x" {}` | function parameter | Input to the module |
| `output "x" {}` | return value | Value the module hands back |
| `locals {}` | local variable | Computed helper values |
| `module "x" {}` | function call | Calls a child module |

**4. References build the dependency graph.** When one block mentions `aws_vpc.this.id`, Terraform knows the VPC must exist first. You never write the order yourself.

**5. State** is a JSON file mapping "resource X in my code" to "real AWS object Y". Here it lives in S3 (the backend).

## 2.2 Folder structure

```
infra/
├── shared/              ROOT  — applied once. ECR, CloudTrail, budget.   state: shared/terraform.tfstate
├── jenkins/             ROOT  — the Jenkins EC2 server.                  state: jenkins/terraform.tfstate
├── envs/
│   ├── dev/us-east-1/   ROOT  — the dev environment.    state: envs/dev/us-east-1/terraform.tfstate
│   └── prod/us-east-1/  ROOT  — the prod environment.   state: envs/prod/us-east-1/terraform.tfstate
└── modules/             CHILD modules — reusable building blocks, never run directly
    ├── platform/        the "whole environment" module; wires the others together
    │   └── tests/       terraform test, against a mocked AWS
    ├── network/         VPC, subnets, NAT, routes
    ├── security-groups/ ALB and app firewalls
    ├── certificate/     HTTPS certificate and its DNS validation
    ├── compute/         ECS cluster, ALB, target groups, listeners, log bucket
    ├── ecs-service/     one ECS service: task definition, service, autoscaling
    ├── database/        RDS MySQL
    ├── ops-access/      small EC2 instance for Session Manager
    └── monitoring/      SNS topic and CloudWatch alarms
```

**Why four root modules instead of one?** Each has its own state file, which limits the **blast radius**: a bad apply in dev cannot touch prod, and the Jenkins stack cannot destroy the ECR repository. They also change at different speeds — shared almost never, Jenkins rarely, environments on every deploy.

**Why are dev and prod nearly identical?** Their `main.tf`, `variables.tf` and `outputs.tf` are identical. Only `backend.tf` (the state `key`) and `terraform.tfvars` (the values) differ. Same code, different inputs, different state — the standard "folder per environment" pattern.

**Why `dev/us-east-1/`?** Room for more regions later: copy the folder, change the region, CIDR and state key.

## 2.3 The files inside each root (using dev)

### `versions.tf` — which Terraform and providers

```hcl
terraform {
  required_version = ">= 1.10"          # Terraform CLI must be 1.10+ (needed for use_lockfile)
  required_providers {
    aws = {
      source  = "hashicorp/aws"         # registry address of the plugin
      version = "~> 6.0"                # any 6.x, never 7.0 ("~>" = only the last number may rise)
    }
  }
}
```

`terraform init` reads this and downloads the provider into `.terraform/`. Every child module has the same file, declaring "I need aws 6.x."

### `backend.tf` — where state lives

```hcl
terraform {
  backend "s3" {
    bucket       = "qc-tfstate-111122223333"              # S3 bucket holding the state
    key          = "envs/dev/us-east-1/terraform.tfstate" # path inside the bucket — unique per root
    region       = "us-east-1"
    encrypt      = true                                    # encrypt the state file at rest
    use_lockfile = true                                    # a .tflock file in S3 stops two applies at once
  }
}
```

All four roots share one bucket with different keys. Backend blocks **cannot use variables**, so values are typed out.

> **Note:** no code in this repository creates the state bucket. It is a chicken-and-egg problem — state can't be stored in a bucket that doesn't exist yet — so it is created by hand once.

### `variables.tf` — inputs this root accepts

```hcl
variable "enable_nat" {
  description = "..."   # documentation; shown in errors and prompts
  type        = bool    # string, number, bool, list(...), map(...), object({...})
  default     = true    # optional. No default = required; the plan fails if it isn't set
}
```

Many variables in the child modules also have a `validation` block:

```hcl
validation {
  condition     = var.desired_count >= 2   # must be true
  error_message = "..."                     # shown at plan time when it is false
}
```

### `terraform.tfvars` — the values

Loaded **automatically**. Each line is `variable_name = value`. This is the only file that really differs between environments:

| Variable | dev | prod | Effect |
|---|---|---|---|
| `vpc_cidr` | 10.10.0.0/16 | 10.30.0.0/16 | Non-overlapping address ranges |
| `hostname` | orders.dev | orders | orders.dev.example.com vs orders.example.com |
| `max_count` | 4 | 6 | Autoscaling ceiling |
| `log_retention_days` | 7 | 30 | Log retention |
| `db_deletion_protection` | false | true | Prod database cannot be deleted |
| `slo_availability_percent` | 99.0 | 99.5 | Alarm threshold |

`stable_image_tag`, `canary_image_tag` and `canary_weight` are **overridden by Jenkins** on each deploy with `-var` (see 2.6).

### `main.tf` — the wiring

1. **`provider "aws"`** — `region = var.region`. `default_tags` adds `Project`, `Environment` and `ManagedBy` tags to every resource automatically.
2. **`data "terraform_remote_state" "shared"`** — reads the **outputs of another root's state** (the shared stack). This is how dev learns the ECR URL without hard-coding it. `backend` and `config` say where that state file is. Used as `data.terraform_remote_state.shared.outputs.repository_url`.
3. **`data "aws_route53_zone" "main"`** — looks up the existing DNS zone by `name`. `private_zone = false` means the public zone. Terraform **reads** this zone; it does not own it.
4. **`module "platform"`** — `source = "../../../modules/platform"` is a relative path to the child module. Every other line passes a value into a platform variable, for example `domain_name = "${var.hostname}.${var.zone_name}"` produces `orders.dev.example.com`.

### `outputs.tf` — what this root exposes

```hcl
output "alb_url" {
  description = "..."
  value       = module.platform.alb_url   # re-export the child module's output
}
```

A child module's outputs are not visible from the CLI; the root must re-export them. Jenkins reads them with `terraform output -raw alb_url`.

## 2.4 How everything connects

```
                     ┌─────────── shared/ (state: shared/...) ───────────┐
                     │ aws_ecr_repository.orders                         │
                     │ output repository_url ─────────────────────┐      │
                     └────────────────────────────────────────────│──────┘
                                                                  │ terraform_remote_state
envs/dev/us-east-1/                                               ▼
  terraform.tfvars ──► variables.tf ──► main.tf: module "platform" { image_repository_url = ..., vpc_cidr = var.vpc_cidr, ... }
  Jenkins -var ─────┘                             │
                                                  ▼
modules/platform/  (variables.tf receives the values)
   locals: name = "qc-dev-use1", tags, task_subnet_ids
   │
   ├─ module network ─────────► outputs vpc_id, public/app/data_subnet_ids
   │                                │
   ├─ module security_groups ◄──────┘ (vpc_id)     ─► outputs alb_id, app_id
   ├─ module certificate (domain, zone_id)         ─► output certificate_arn
   ├─ module compute ◄── public subnets, alb_id, certificate_arn
   │                                               ─► cluster_arn, target_group_arns{stable,canary}, alb_dns_name
   ├─ aws_route53_record.site ◄── compute.alb_dns_name     (orders.dev.example.com → ALB)
   ├─ aws_iam_role.execution  (the role ECS uses to start tasks)
   ├─ module ops_access ◄── app_subnet_ids[0]      ─► instance_id, security_group_id
   ├─ module database ◄── data_subnet_ids, [app SG, ops SG]  ─► address, secret_arn
   ├─ module orders["stable"], orders["canary"] (ecs-service) ◄── cluster, target group, image, subnets, DB settings
   └─ module monitoring ◄── alb_arn_suffix, target group suffix, service_name
   │
   outputs.tf ──► envs/dev/.../outputs.tf ──► `terraform output` ──► Jenkins and scripts
```

**The pattern:** values flow **down** through variables and **up** through outputs. Sibling modules never talk to each other directly — the parent (`platform`) takes one module's output and passes it as another module's input. For example, `module "security_groups" { vpc_id = module.network.vpc_id }`. That reference is also why Terraform builds `network` before `security_groups`.

## 2.5 Module-by-module reference

### `infra/shared/` — account-wide, applied once

**`main.tf`**

- `aws_ecr_repository.orders` — the Docker image registry.
  - `name = "quickcart/orders"` — repository name.
  - `image_tag_mutability = "IMMUTABLE"` — a tag can never be overwritten, so `v2` always means the same image. This makes rollback trustworthy.
  - `force_delete = true` — `destroy` works even when images exist (a lab setting).
  - `image_scanning_configuration.scan_on_push` — scan every pushed image for known vulnerabilities.
- `aws_ecr_lifecycle_policy.orders` — keep the 30 newest images, expire the rest.
  - `jsonencode({...})` turns an HCL map into a JSON string, because AWS expects JSON.
  - `repository = aws_ecr_repository.orders.name` is a reference, so the policy is created after the repository.
- Outputs `repository_url` and `repository_name` are read by the environments.

**`audit.tf`**

- `data "aws_caller_identity" "current"` — your account ID, used to make bucket names globally unique.
- `aws_s3_bucket.trail` — bucket for the audit logs.
- `aws_s3_bucket_public_access_block` — all four flags `true`: the bucket can never be made public.
- `aws_s3_bucket_versioning` — keeps previous versions of objects.
- `data "aws_iam_policy_document"` — writes an IAM policy in HCL instead of raw JSON. Each `statement` has `actions` (what), `resources` (on which ARNs), `principals` (who — here the CloudTrail service), and an optional `condition`.
- `aws_s3_bucket_policy` — attaches that policy's `.json` to the bucket.
- `aws_cloudtrail.account` — records every API call.
  - `is_multi_region_trail` — covers all regions.
  - `include_global_service_events` — includes IAM and other global services.
  - `enable_log_file_validation` — hourly signed digests, so edited logs can be detected.
  - `depends_on = [aws_s3_bucket_policy.trail]` — an **explicit** dependency. Nothing references the policy, but CloudTrail checks it at creation, so it must exist first.
- `aws_budgets_budget.monthly` — cost alerts. The two `notification` blocks email at 80% of actual spend and at 100% of forecast spend. `tostring()` converts the number into the string the API expects.

### `infra/jenkins/` — the CI server, a separate stack

- `data "aws_vpc" "default"` and `data "aws_subnets"` — use the account's default VPC in us-east-1a. Jenkins doesn't need a custom network.
- `data "aws_ami" "al2023"` — newest Amazon Linux 2023 image. `most_recent` picks the newest; `owners = ["amazon"]` trusts only official images; `filter` matches by name pattern.
- `data "http" "github_meta"` — calls the GitHub API (needs the `hashicorp/http` provider, declared in `versions.tf`). `locals.github_hook_cidrs` keeps only IPv4 ranges (`!strcontains(c, ":")` drops IPv6).
- `aws_security_group.jenkins`
  - `ingress` — inbound rules: port 8080 only from your IP and from GitHub's webhook addresses.
  - `egress` — outbound rules: everything allowed.
  - `#trivy:ignore:...` comments silence the security scanner for accepted risks.
- `aws_iam_role` + `aws_iam_role_policy_attachment` + `aws_iam_instance_profile` — give the EC2 instance an identity instead of stored access keys.
  - `assume_role_policy` — who may use the role (`ec2.amazonaws.com`).
  - `for_each = toset([...])` — one attachment per policy ARN; `each.value` is the current item.
  - `AdministratorAccess` is a lab shortcut; the code comment says so.
- Backup bucket, versioning and lifecycle — `filter { prefix = "jenkins-home/" }` with `expiration { days = 30 }` deletes old backups.
- `aws_sns_topic` + `aws_sns_topic_subscription` — email notifications. An `email` subscription must be confirmed from the inbox.
- `aws_instance.jenkins`
  - `ami`, `instance_type`, `subnet_id`, `vpc_security_group_ids`, `iam_instance_profile` — the basics.
  - `associate_public_ip_address = true` — reachable from the internet (through the security group).
  - `user_data = templatefile("${path.module}/user-data.sh", {...})` — the boot script, with `${backup_bucket}` filled in. `path.module` is this folder.
  - `user_data_replace_on_change = true` — changing the script rebuilds the instance.
  - `metadata_options.http_tokens = "required"` — forces IMDSv2, which blocks a common credential-theft attack (SSRF).
  - `root_block_device` — 30 GB encrypted gp3 disk.
- `terraform.tfvars.example` — the real `terraform.tfvars` is git-ignored because it contains your IP.

### `infra/modules/platform/` — the whole environment

The hub: environments call it, and it calls everything else.

**`locals`**

- `region_codes` with `lookup(map, key, default)` — `us-east-1` becomes `use1`. For unknown regions, `replace()` strips the dashes.
- `name = "qc-dev-use1"` — prefix for every resource name. Kept short because ALB and target group names are limited to 32 characters.
- `task_subnet_ids = var.enable_nat ? app_subnets : public_subnets` — the **ternary** `condition ? a : b`.
- `assign_public_ip = !var.enable_nat` — tasks need a public IP only when there is no NAT.

**Module calls** (each `source` points at a sibling folder)

- `module "ops_access" { count = var.enable_ops_access ? 1 : 0 }` — **`count`** creates 0 or N copies; 0 means it does not exist. Refer to it as `module.ops_access[0]`, or `module.ops_access[*].x` (the **splat**: a list of `x` from every copy, empty when count is 0).
- `locals.db_clients = concat([app_sg], module.ops_access[*].security_group_id)` — joins two lists. If ops access is off, only the app security group is included.
- `module "orders"` uses **`for_each`** over a map:

  ```hcl
  for_each = { stable = {...}, canary = {...} }
  ```

  This creates two copies of `ecs-service`: `module.orders["stable"]` and `module.orders["canary"]`. Inside, `each.key` is `"stable"` or `"canary"`, and `each.value.tag` reads that item's field. `target_group_arn = module.compute.target_group_arns[each.key]` picks the matching target group. `depends_on` makes sure IAM permissions exist before any task starts.
- `aws_route53_record.site` — an `A` record with an **`alias`** block pointing the domain at the ALB (`name` and `zone_id` are the ALB's DNS name and zone; `evaluate_target_health` makes DNS consider ALB health).
- `aws_iam_role.execution` — the role ECS itself uses to pull images, write logs and read secrets. `aws_iam_role_policy_attachment` attaches AWS's managed ECS execution policy.

**`database.tf`**

- Everything has `count = var.enable_database ? 1 : 0` — the whole database feature toggles with one flag.
- `aws_iam_role_policy.read_db_secret` — an inline policy letting the execution role read **only this one** secret.
- `aws_ecs_task_definition.ops_sql` — a one-off Fargate task that runs SQL safely in a transaction.
  - `<<-EOT ... EOT` is a **heredoc**: a multi-line string.
  - `secrets` with `valueFrom = "<secret_arn>:username::"` makes ECS inject a single key of the JSON secret when the task starts. The password never appears in code or in the plan.

**`variables.tf`** — validations reject bad input at plan time: environment must be `dev`, `stg` or `prod`; image tags can't be `latest`; `canary_weight` must be 0–50; `desired_count` must be at least 2; `project` must match a regex (`can(regex(...))` returns true or false instead of failing).

### `infra/modules/network/`

- `data "aws_availability_zones"` — lists zones in the region. `locals.azs = slice(names, 0, var.az_count)` keeps the first two.
- `locals.az_index = { for i, az in local.azs : az => i }` — a **for expression** building `{"us-east-1a" = 0, "us-east-1b" = 1}`.
- `aws_vpc.this`
  - `cidr_block` — the VPC's address range.
  - `enable_dns_support` / `enable_dns_hostnames` — required for RDS endpoints and private DNS.
  - `tags = merge(var.tags, { Name = ... })` — `merge` combines the common tags with a `Name` tag.
- Three subnet tiers, each with `for_each = local.az_index` (one subnet per AZ):
  - `cidrsubnet(var.cidr, 8, n)` carves a /24 out of the /16 (16 + 8 = 24), number `n`.
  - public: `10.10.0.0/24`, `10.10.1.0/24`
  - app: `10.10.10.0/24`, `10.10.11.0/24` (+10)
  - data: `10.10.20.0/24`, `10.10.21.0/24` (+20)
  - `map_public_ip_on_launch = true` — only on public subnets.
- `aws_internet_gateway`, a public `aws_route_table` with route `0.0.0.0/0 → IGW`, and `aws_route_table_association` (subnet ↔ route table) — together they make a subnet "public". `for_each = aws_subnet.public` loops over another resource's instances.
- NAT
  - `locals.nat_azs` — `[]` (no NAT), `[first AZ]` (single NAT), or every AZ.
  - `aws_eip` — a static public IP for the NAT; `domain = "vpc"`.
  - `aws_nat_gateway` — lives in a public subnet; `allocation_id` is its EIP. `toset()` converts a list to a set so `for_each` accepts it.
- App route tables use **`dynamic "route"`**, which generates nested blocks in a loop. `for_each = enable_nat ? [1] : []` means "one route block, or none" — the way to make a nested block optional.
- Data route table — no routes at all, so the database cannot reach the internet.
- `aws_vpc_endpoint.s3` — free gateway endpoint so image downloads skip the NAT. `route_table_ids = [for az in local.azs : aws_route_table.app[az].id]` is a for expression producing a list.

### `infra/modules/security-groups/`

The chain: internet → ALB group → app group.

- ALB group — `dynamic "ingress"` over `{ https = 443, http = 80 }`. `ingress.key` and `ingress.value` are the loop variables (named after the block). `from_port` / `to_port` are a port range (same number = one port); `protocol = "tcp"`; `cidr_blocks` are the allowed sources.
- ALB egress — only to `var.vpc_cidr` on the app port. Terraform **removes** AWS's default allow-all egress rule, so egress must be written explicitly.
- App group ingress — `security_groups = [alb.id]` references a **security group, not an IP range**: only the ALB may connect. Egress `protocol = "-1"` means all protocols.
- `app_port` validation — must be 1024 or above, because a non-root container cannot listen on lower ports.

### `infra/modules/certificate/`

1. `aws_acm_certificate` — `validation_method = "DNS"`: prove ownership with a DNS record. `lifecycle { create_before_destroy = true }`: on replacement, the new certificate is created before the old one is deleted, so there is no downtime.
2. `aws_route53_record.validation` — writes the CNAME record ACM asked for. `domain_validation_options` is a set; `one([for ...])` takes its single item (and fails if there isn't exactly one). `allow_overwrite = true` accepts an existing record. `ttl = 60` is the DNS cache time in seconds.
3. `aws_acm_certificate_validation` — creates nothing in AWS; it **waits** until the certificate is issued. The module's output reads the ARN from this resource, so the HTTPS listener cannot be created until the certificate is valid — an ordering trick.

### `infra/modules/compute/`

- `aws_ecs_cluster` — the logical group of services. `containerInsights = disabled` saves cost.
- ALB access-log bucket
  - `data "aws_elb_service_account"` — AWS's load balancer account in this region; the only principal allowed to write the logs.
  - Lifecycle rule with `filter {}` (empty = whole bucket) and `expiration`.
  - `force_destroy = var.logs_force_destroy`.
- `aws_lb.this`
  - `load_balancer_type = "application"` — an HTTP-aware (layer 7) load balancer.
  - `internal = false` — internet-facing.
  - `subnets` — at least two AZs (enforced by validation).
  - `enable_deletion_protection`.
  - `drop_invalid_header_fields` — defends against request smuggling.
  - `access_logs { bucket, prefix, enabled }`.
  - `depends_on` the bucket policy, because AWS tests write access when logging is enabled.
- `aws_lb_target_group.this` with `for_each = toset(["stable", "canary"])`
  - `target_type = "ip"` — required for Fargate (`awsvpc` networking).
  - `deregistration_delay = 30` — wait 30 seconds for in-flight requests before removing a target.
  - `health_check` — `path` to call, `matcher = "200"` expected status, `interval` and `timeout` in seconds, `healthy_threshold` / `unhealthy_threshold` consecutive results needed to change state.
- `aws_lb_listener.https` — `port = 443`, `protocol = "HTTPS"`, `ssl_policy` (allowed TLS versions and ciphers), `certificate_arn`. Its `default_action.forward` has **two weighted target groups**: stable gets `100 - canary_weight`, canary gets `canary_weight`. **This is the canary mechanism** — change one number and the traffic split changes.
- `aws_lb_listener.http` — port 80 redirects to 443 with `HTTP_301`.
- Outputs — `{ for k, tg in aws_lb_target_group.this : k => tg.arn }` turns the `for_each` resource into a map `{ stable = arn, canary = arn }`. `arn_suffix` is the form CloudWatch uses in metric dimensions.

### `infra/modules/ecs-service/` — called twice (stable and canary)

- `aws_cloudwatch_log_group` — `/ecs/<name>` with `retention_in_days`.
- `aws_ecs_task_definition` — the container blueprint.
  - `family` — name; each change creates a new revision (`:1`, `:2`, …).
  - `requires_compatibilities = ["FARGATE"]` — serverless containers.
  - `network_mode = "awsvpc"` — each task gets its own network interface and IP (required by Fargate).
  - `cpu` / `memory` — 256 = a quarter vCPU; 512 MB.
  - `execution_role_arn` — ECS's role (pull image, read secrets). `task_role_arn` — the app's own role while running (null here).
  - `runtime_platform` — OS and CPU architecture; must match how the image was built (amd64).
  - `container_definitions = jsonencode([...])` — `name`, `image`; `essential = true` (if this container dies, the task dies); `portMappings`; `environment` (plain variables, built from sorted keys so the order is stable and plans show no false changes); `secrets` (injected from Secrets Manager); `logConfiguration` (send output to CloudWatch).
- `aws_ecs_service` — keeps N tasks running.
  - `desired_count`, `launch_type = "FARGATE"`.
  - `deployment_minimum_healthy_percent = 100` with `deployment_maximum_percent = 200` — start new tasks before stopping old ones; capacity never drops.
  - `deployment_circuit_breaker { enable, rollback }` — if new tasks keep failing, ECS rolls back by itself.
  - `health_check_grace_period_seconds = 30` — ignore ALB health checks for 30 seconds while the app starts.
  - `wait_for_steady_state = true` — `apply` doesn't finish until the deploy is healthy. The pipeline relies on this.
  - `network_configuration` — subnets, security group, public IP.
  - `load_balancer` — register the tasks' `container_name:container_port` in the target group.
  - `lifecycle { ignore_changes = [desired_count] }` — after creation Terraform ignores the count, so autoscaling owns it. Without this, every apply would reset the scale.
- Autoscaling, with `count = var.autoscaling == null ? 0 : 1` (the canary passes `null`, so it has none):
  - `aws_appautoscaling_target` — `service_namespace = "ecs"`, `resource_id = "service/<cluster>/<service>"`, `scalable_dimension` (what is scaled), `min_capacity` / `max_capacity`.
  - `aws_appautoscaling_policy` — `TargetTrackingScaling`: `target_value = 60` keeps average CPU near 60%; `scale_out_cooldown = 60` seconds (scale out fast); `scale_in_cooldown = 300` seconds (scale in slowly).
- The `autoscaling` variable uses `type = object({ min, max, cpu_target })` — a structured type.

### `infra/modules/database/`

- `aws_security_group.db` — ingress on 3306 only from the allowed security groups. No egress: a database never starts connections.
- `aws_db_subnet_group` — which subnets RDS may use (the data tier; at least two AZs required).
- `aws_db_parameter_group` — `family = "mysql8.0"`. Each `parameter` is a MySQL server setting; here the slow-query log is on, at 2 seconds.
- `aws_db_instance.this`
  - `identifier` — instance name.
  - `engine` / `engine_version` / `instance_class` — MySQL 8.0 on `db.t4g.micro`.
  - `allocated_storage = 20` GB, `storage_type = "gp3"`, `storage_encrypted`.
  - `db_name` — the database created inside; `username` — the admin user.
  - `manage_master_user_password = true` — RDS generates the password and stores it in Secrets Manager. It is never in code or state.
  - `multi_az` — standby copy in a second AZ.
  - `publicly_accessible = false`.
  - `backup_retention_period` — days of automatic backups.
  - `deletion_protection`.
  - `skip_final_snapshot = !deletion_protection` — dev deletes without a snapshot; prod takes a final snapshot named `final_snapshot_identifier`.
- Output `secret_arn = ...master_user_secret[0].secret_arn` — `[0]` because the provider exposes that attribute as a list.

### `infra/modules/ops-access/`

A `t4g.nano` EC2 instance in a private subnet. Engineers reach the database through `aws ssm start-session`. No SSH, no public IP, and **no ingress rule at all** — the Session Manager agent connects outward. The role only has the `AmazonSSMManagedInstanceCore` policy. Same IMDSv2 and encrypted-disk settings as Jenkins.

### `infra/modules/monitoring/`

- `aws_sns_topic` — `kms_master_key_id = "alias/aws/sns"` encrypts it with AWS's managed key. Plus an email subscription.
- `aws_cloudwatch_metric_alarm.error_rate` — the **SLO alarm**, using metric math:
  - `metric_query` blocks with ids `app`, `lb` and `requests` fetch raw metrics.
  - `rate` has `expression = "100 * (FILL(app, 0) + FILL(lb, 0)) / requests"`; `return_data = true` marks it as the value the alarm watches.
  - `threshold = 100 - slo` (for example 0.5%).
  - `treat_missing_data = "notBreaching"` — no traffic is not an alarm.
  - `alarm_actions` / `ok_actions` — notify SNS when it fires and when it recovers.
- Other alarms (simple form) — `namespace` / `metric_name` / `dimensions` choose the metric; `statistic` (Sum, Average, Maximum); `period` (seconds per data point); `evaluation_periods` (how many bad points in a row fire it); `comparison_operator` and `threshold`.
- Database alarms use `count = var.db_instance_id == null ? 0 : 1`.
- Output `alarm_names` uses `concat(...)` with the splat `[*]`, so absent database alarms add nothing.

### `infra/modules/platform/tests/platform.tftest.hcl`

Run with `terraform test` from `infra/modules/platform`.

- `mock_provider "aws"` — a fake AWS: no account, no cost. `mock_data` / `mock_resource` supply values (ARNs and so on) AWS would normally generate.
- `variables {}` — inputs shared by all runs.
- Each `run "name"` — `command = plan` (plan only); optional per-run `variables {}`; `assert { condition, error_message }` for what must be true; or `expect_failures = [var.x]`, which says this run **should** fail validation — that is how the validations themselves are tested.

### `.tflint.hcl`

Configuration for the linter `tflint`. `plugin "terraform"` with `preset = "recommended"` checks general best practice; `plugin "aws"` adds AWS-specific checks (such as invalid instance types). `version` and `source` pin the plugin.

## 2.6 Runtime flow: who runs what, and when

**First-time setup (by hand):**

1. Create the S3 bucket `qc-tfstate-<account-id>` (no code does this).
2. `cd infra/shared && terraform init && terraform apply` — ECR, CloudTrail, budget.
3. `cd infra/jenkins`, copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in, then `terraform init && terraform apply` — Jenkins.
4. `cd infra/envs/dev/us-east-1 && terraform init && terraform apply`, then the same for prod.

**What the commands do:**

- `init` — downloads the providers in `versions.tf`, connects to the S3 backend, and installs the modules named by `source`.
- `plan` — reads state, asks AWS for reality, compares both with the code, and prints the difference (`+` create, `~` update, `-` destroy, `-/+` replace).
- `apply` — carries out the plan in dependency order (independent things in parallel) and saves the new state.

**On every deploy** (see [Jenkinsfile](../Jenkinsfile) and [scripts/release.sh](../scripts/release.sh)):

1. Build the image and push it to ECR (the repository from the shared stack).
2. Dev: `terraform -chdir=infra/envs/dev/us-east-1 apply -var stable_image_tag=<sha> -var canary_image_tag=<sha> -var canary_weight=0`. `-var` overrides `terraform.tfvars`. Only the task definitions change, then the ECS service rolls; `wait_for_steady_state` blocks until it is healthy.
3. Prod canary: `plan -out=canary.tfplan` with `canary_weight=10`, a human approves, then `apply canary.tfplan` applies **exactly** the plan that was approved. The listener now sends 10% of traffic to the canary target group.
4. Promote: stable = new tag, weight 0. If the canary check fails, weight goes to 0 — an instant rollback.
5. `terraform output -raw alb_url` and `terraform output -raw stable_image_tag` read values back from state; this is how scripts find the URL and the previous version (used by [jobs/rollback.Jenkinsfile](../jobs/rollback.Jenkinsfile)).

A deploy in this project is **changing three Terraform variables**. Infrastructure and releases share one source of truth.

## 2.7 Design notes and small issues worth knowing

- **`enable_nat` default mismatch:** `platform` defaults to `false`, the environment folders default to `true`. Harmless — environments always pass a value — but confusing.
- **`single_nat` and `enable_ops_access`** aren't exposed by the environment folders, so they always use the platform defaults (both `true`). To vary them per environment, add them to the environment's `variables.tf` and `main.tf`.
- **`monitoring.db_instance_id = "${local.name}-db"`** rebuilds the database name as a string instead of referencing `module.database[0]`, so Terraform sees no dependency and may create the alarm before the database. CloudWatch allows that, but a real reference is the better habit.
- **`terraform_remote_state` couples stacks:** environments need read access to the shared state. Alternatives are passing the ECR URL as a variable, or a `data "aws_ecr_repository"` lookup.
- **Dev and prod `main.tf` are copies:** every change must be made twice. This is the usual trade-off of the folder-per-environment pattern; Terragrunt, or one root with workspaces, avoids it at the cost of less isolation.

---

# Part 3 — Doing it yourself

## Start from questions, not services

Don't begin with a list of AWS services. Begin with **questions** about the app. Each "yes" brings in a component.

| # | Ask yourself | If yes, you need |
|---|---|---|
| 1 | How does my app run? (language, port, settings) | Container image + registry |
| 2 | What keeps it running and restarts it? | ECS/Fargate (or a VM, or Kubernetes) |
| 3 | Must it survive one copy or one data centre failing? | 2+ copies across 2 AZs |
| 4 | More than one copy — so one address? | Load balancer + health check |
| 5 | Public to the internet, or internal only? | VPC with public and private subnets |
| 6 | Do private things need to call out? | NAT gateway (or VPC endpoints) |
| 7 | Who may talk to whom? | Security groups |
| 8 | Does it store data? | Managed database in private subnets + backups |
| 9 | Does it have passwords or keys? | Secrets Manager + IAM roles |
| 10 | Do people use a friendly name and HTTPS? | DNS + certificate |
| 11 | How will I know it's broken? | Logs, metrics, alarms, notifications |
| 12 | Does traffic vary a lot? | Autoscaling |
| 13 | How are updates shipped? | CI/CD pipeline |
| 14 | How many environments? | Terraform modules + a folder per environment |
| 15 | Cost limits or audit requirements? | Budget, CloudTrail |

## Worked example (hypothetical)

> "Deploy our Python API with PostgreSQL. Customers will use it. The budget is small."

1. Python on port 5000 → Dockerfile and ECR.
2. → An ECS Fargate service.
3. Customers depend on it → 2 copies in 2 AZs.
4. → An ALB with a `/health` endpoint.
5. Public API → a VPC with public subnets (ALB) and private subnets (app, database).
6. Small budget → maybe skip NAT: give tasks public IPs and lock them down with security groups. This project supports exactly that with `enable_nat = false`.
7. → Three security groups: ALB, app, database.
8. PostgreSQL → RDS Postgres, single-AZ to save money, backups on.
9. → Database password in Secrets Manager.
10. → A Route 53 record and an ACM certificate.
11. → CloudWatch logs and two or three alarms to email.
12. Probably not yet → a fixed 2 copies.
13. → A simple pipeline: test, build, push, deploy to dev, approve, deploy to prod. Skip the canary at first.
14. → Dev and prod folders reusing the same modules.
15. → A budget alert.

That is an architecture, derived from questions rather than memorised.

## Must-have vs. extras in this project

- **Core** (almost every web app): image registry, container runtime, 2+ copies, load balancer, VPC and subnets, security groups, database and secrets, DNS and HTTPS, logs and alarms, Terraform, a pipeline.
- **Mature extras** (add when needed): canary releases, autoscaling, Session Manager ops access, ALB access logs, CloudTrail, budget alerts, the S3 endpoint, Terraform tests.

## Build it up in layers

Build it yourself, one layer at a time. Get each layer working before adding the next:

1. Run your container on your laptop with Docker.
2. Push it to ECR and run **one** Fargate task in the default VPC with a public IP. Reach it by IP.
3. Add an ALB with two tasks.
4. Move to your own VPC with public and private subnets, plus security groups.
5. Add RDS and Secrets Manager.
6. Add a domain and HTTPS.
7. Add alarms.
8. Turn it into Terraform modules, with dev and prod folders.
9. Add a pipeline.

After each step, ask: **"What problem would I hit if I stopped here?"** The answer is your next step. That is how this project was designed, and how you will design the next one.

## Hands-on practice

- `cd infra/modules/platform && terraform init && terraform test` — runs the mocked tests; no AWS account needed.
- `terraform console` in any initialised folder — try expressions such as `cidrsubnet("10.10.0.0/16", 8, 10)`.
- Suggested reading order: [network](../infra/modules/network/main.tf) → [security-groups](../infra/modules/security-groups/main.tf) → [compute](../infra/modules/compute/main.tf) → [ecs-service](../infra/modules/ecs-service/main.tf) → [platform](../infra/modules/platform/main.tf) (see the wiring) → [envs/dev](../infra/envs/dev/us-east-1/main.tf).
