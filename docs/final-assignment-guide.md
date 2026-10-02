# Final assignment: QuickCart, from laptop to production

One complete product built with everything from the month — Terraform only, no console builds. A real domain with a trusted certificate, private subnets, a database the app really uses, alarms tied to an SLO, Session Manager instead of a bastion, and a Jenkins pipeline that takes a commit to production by canary. Every step starts with the problem it solves.

## Your values

Replace these placeholders everywhere before running anything — your editor's find-and-replace does it in one go:

| Placeholder | What to put there |
|---|---|
| YOUR_ACCOUNT_ID | account id |
| YOUR_AWS_PROFILE | aws profile name |
| YOUR_GITHUB_USER | github username |
| YOUR_DOMAIN | your domain |
| YOUR_EMAIL | alert email |
| YOUR_PUBLIC_IP | your public ip |

The complete, tested repository is in `quickcart-final.zip`, to compare against.

## Contents

**Get ready**

- [Stage 00 — Before you start](#stage-00)
- [Stage 01 — The domain](#stage-01)
- [Stage 02 — The repository and the app](#stage-02)
- [Stage 03 — State bucket and shared stack](#stage-03)

**Modules**

- [Stage 04 — Network: private, and a free path to S3](#stage-04)
- [Stage 05 — Module: certificate](#stage-05)
- [Stage 06 — Module: compute](#stage-06)
- [Stage 07 — Module: ecs-service](#stage-07)
- [Stage 08 — Module: database](#stage-08)
- [Stage 09 — Module: ops-access — SSM, not a bastion](#stage-09)
- [Stage 10 — Module: monitoring](#stage-10)
- [Stage 11 — Module: platform](#stage-11)
- [Stage 12 — Tests and checks](#stage-12)

**Environments**

- [Stage 13 — Build dev](#stage-13)
- [Stage 14 — Reach the database with Session Manager](#stage-14)
- [Stage 15 — Build prod](#stage-15)

**Delivery**

- [Stage 16 — The Jenkins controller](#stage-16)
- [Stage 17 — Set up Jenkins](#stage-17)
- [Stage 18 — The pipeline in the repository](#stage-18)
- [Stage 19 — The first release](#stage-19)

**Drills**

- [Stage 20 — A bad release](#stage-20)
- [Stage 21 — Triage and roll back](#stage-21)
- [Stage 22 — Change data safely](#stage-22)
- [Stage 23 — The runbook](#stage-23)

**Finish**

- [Stage 24 — Tear down](#stage-24)
- [Stage 25 — Readiness review](#stage-25)

---

<a id="stage-00"></a>

## Stage 00 — Before you start

*What you're building, how every week of the month shows up in it, and what it costs.*

### 00.1 What you're building

- [ ] Done

> 🔴 **The problem this solves.** Each assignment so far built one slice: a network, a runtime, the code, a pipeline. A real product needs all of them working together — and a customer never sees the slices, only whether `https://orders.YOUR_DOMAIN` works.

```
customer ─▶ Route 53: orders.YOUR_DOMAIN
              │
              ▼
     Application Load Balancer  (public subnets, trusted HTTPS from ACM)
        │ 90–100% stable      │ 0–10% canary
        ▼                      ▼
     ECS tasks  ── private app subnets ── out through NAT ─▶ internet
        │
        ▼
     RDS MySQL  (data subnets — no route out at all)
        ▲
        └── ops instance  ◀── you, through Session Manager (no SSH, no public IP)

  every request ─▶ S3 access logs     every API call ─▶ CloudTrail
  errors above the SLO ─▶ CloudWatch alarm ─▶ SNS ─▶ your email

  git push ─▶ GitHub ─▶ webhook ─▶ Jenkins ─▶ tests, plan, image
                                     ─▶ dev ─▶ approval ─▶ prod canary ─▶ promote
```

Two environments — **dev** and **prod** — built from identical code. The pipeline takes every change through dev, then to 10% of production, then to everyone.

### 00.2 Where every week shows up

- [ ] Done

| Week | Concept | Where it is in this build |
|---|---|---|
| 1 | DORA, trunk-based delivery, small changes | Every change is a pull request; the pipeline records every deploy |
| 1 | SLOs and error budgets | A written availability target per environment, enforced by an alarm |
| 1 | IAM least privilege | Separate roles for ECS, the ops instance and Jenkins — none holding stored keys |
| 1 | VPC: public, app and data tiers; NAT | Tasks in private subnets, the database in subnets with no way out |
| 2 | Load balancer, health checks, auto scaling | HTTPS load balancer; the service scales on CPU between set limits |
| 2 | Route 53 and ACM | A real name and a certificate browsers trust, validated through DNS by Terraform |
| 2 | RDS and Secrets Manager | MySQL the app reads; the password goes from Secrets Manager into the task |
| 2 | S3, CloudWatch, CloudTrail | Access logs in S3, alarms by email, an account-wide audit trail |
| 3 | Docker, ECR, ECS, zero-downtime releases | The order service, circuit breaker, stable and canary copies |
| 4 | Terraform modules, remote state, environments, tests | Everything below — nothing is clicked into existence |
| 5 | Jenkins, canary, rollback, operations jobs, runbook | The delivery pipeline and everything you do on a bad day |
| new | Session Manager instead of a bastion | Reach the private database from your Mac with no SSH and no open port |

### 00.3 What it costs, and why it's more than before

- [ ] Done

| Running | About per day | Why |
|---|---|---|
| NAT gateway, one per environment | $1.10 each | Private subnets need a way out. This is the price of not giving tasks public IPs |
| Load balancer, one per environment | $0.55 each |  |
| ECS: 2 stable + 1 canary task per environment | $0.90 each | The canary task always runs; it only gets traffic during a release |
| RDS db.t4g.micro, per environment | $0.40 each | Single-zone. Multi-AZ would double it |
| Ops instance t4g.nano, per environment | $0.10 each |  |
| Jenkins t3.medium | $1.00 |  |
| Route 53 hosted zone, CloudTrail, S3 | a few cents | The first CloudTrail trail of management events is free |
| **Everything running** | **about $7** | The shared stack sets a budget alarm, so you're emailed before any surprise |

> ⚠️ **Plan the days.** Build, do the exercises, and tear down (stage 27) within a few days. Nothing here should run for weeks. A domain name, if you register one, costs about $14 a year.

### 00.4 Install the tools

- [ ] Done

```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform tflint trivy mysql-client && brew install --cask session-manager-plugin
```

| Part | What it means |
|---|---|
| `hashicorp/tap/terraform` | Terraform, from HashiCorp's own collection |
| `tflint, trivy` | the linter and the security scanner from A4 |
| `mysql-client` | to query the database through Session Manager in stage 15 |
| `--cask session-manager-plugin` | lets the AWS CLI open Session Manager connections from your Mac |

```bash
terraform version && session-manager-plugin --version
```

> ✅ **You should see:** A Terraform version of 1.10 or later, then a plugin version number. If the plugin says *command not found*, open a new terminal window.

You also need Docker Desktop running, and git with your SSH access to GitHub from A4.

### 00.5 Log in to AWS and fill in your values

- [ ] Done

```bash
export AWS_PROFILE=YOUR_AWS_PROFILE && aws sts get-caller-identity
```

| Part | What it means |
|---|---|
| `export AWS_PROFILE=...` | every aws and terraform command in this window uses this login |
| `aws sts get-caller-identity` | who am I? |

> ✅ **You should see:** Your account number. Put it in the **account id** box on the left.

```bash
curl -s https://checkip.amazonaws.com
```

| Part | What it means |
|---|---|
| `checkip.amazonaws.com` | tells you the public IP your internet connection uses |

> ✅ **You should see:** An address like `203.0.113.25`. Put it in **your public ip**. Only this address will be able to open Jenkins.

Fill in **alert email** with an address you can read: alarms, budget warnings and pipeline results go there.

---

<a id="stage-01"></a>

## Stage 01 — The domain

*A trusted certificate needs a name you control. Route 53 is where that name lives.*

### 01.1 Why a domain now

- [ ] Done

> 🔴 **The problem this solves.** In A3 and A4 you used a self-signed certificate, so every `curl` needed `-k` and every browser showed a warning. Customers can't click past a warning. A certificate browsers trust must be issued for a name — and the issuer needs proof you control that name.

ACM gives that proof through DNS: it asks for a special record to exist in your domain, checks for it, and issues the certificate. Terraform writes the record. That only works if your domain's DNS is in **Route 53**.

### 01.2 Check you have a hosted zone

- [ ] Done

```bash
aws route53 list-hosted-zones-by-name --dns-name YOUR_DOMAIN --query 'HostedZones[0].[Name,Id]' --output text
```

| Part | What it means |
|---|---|
| `list-hosted-zones-by-name` | find the zone for a domain |
| `--query` | print just its name and ID |

> ✅ **You should see:** Your domain with a dot at the end, like `YOUR_DOMAIN.`, and an ID starting `/hostedzone/`. If you used a domain in A2, it's already here.

> ⚠️ **No domain, or it's registered elsewhere?.** Register one in the console: **Route 53 → Registered domains → Register domains** (about $14 a year). Route 53 creates the hosted zone for you. If the domain is registered with another company, create a hosted zone in Route 53 and change the domain's name servers, at that company, to the four listed in the zone's NS record.

> 💡 **Why the zone isn't created by Terraform here.** The zone outlives every environment: destroy prod, and the domain must still exist. So environments only **look it up** with a `data` block. Things with different lifetimes are managed in different places — the A4 lesson again.

---

<a id="stage-02"></a>

## Stage 02 — The repository and the app

*A new repository, and an order service that finally reads from a real database.*

### 02.1 Create the repository

- [ ] Done

> 🔴 **The problem this solves.** A4 and A5 grew one repository step by step. A product that's handed to a customer starts clean, with its history telling one story.

On github.com create **two private repositories**: `quickcart-final` and `quickcart-jenkins-lib`. Clone the first with the SSH alias of the account that owns it:

```bash
git clone git@github.com:YOUR_GITHUB_USER/quickcart-final.git && cd quickcart-final
```

| Part | What it means |
|---|---|
| `git@github.com:` | use your SSH host alias here if the repository belongs to your second account |

Everything from A4 that didn't change — `.tflint.hcl`, `.trivyignore`, `scripts/tf-checks.sh` and the security-groups module — copy across from your A4 repository. Everything new or changed is shown in full in this guide. The complete, tested repository is also in your downloads as `quickcart-final.zip`, to compare against.

**`.gitignore`**

```
# Terraform working files — never commit
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
tfplan
crash.log
.terraform.tfstate.lock.info

# Python
__pycache__/
.venv/
.pytest_cache/
reports/

# Local notes and secrets
*.pem
.env
logs-*.txt

# Holds your own IP address — not for the repository
infra/jenkins/terraform.tfvars
```

One new line at the end: the Jenkins stack's values file holds your home IP address, which doesn't belong in a repository.

### 02.2 The data layer: the repository pattern

- [ ] Done

> 🔴 **The problem this solves.** Until now the order service returned three orders written into its code. A real service reads real data — but the tests must still run on a laptop with no database, and the code that handles web requests shouldn't know or care which database is behind it.

This is the repository pattern you know from app development: one interface — `list_orders()`, `ping()` — with two implementations. The web code only ever talks to the interface.

**`app/repository.py`**

```python
"""Where orders come from. The rest of the app talks to this, never to MySQL directly."""
import os

import pymysql

SEED = [("keyboard", 2), ("monitor", 1), ("mouse", 5)]


class InMemoryOrders:
    """Used in tests, and on a laptop with no database."""

    def __init__(self):
        self._rows = [{"id": i + 1, "item": item, "qty": qty} for i, (item, qty) in enumerate(SEED)]

    def list_orders(self):
        return list(self._rows)

    def ping(self):
        return True


class MySQLOrders:
    """Used in AWS. ECS fills the connection details from Secrets Manager."""

    def __init__(self, host, user, password, database):
        self._params = dict(host=host, user=user, password=password, database=database,
                            connect_timeout=3, read_timeout=5,
                            cursorclass=pymysql.cursors.DictCursor)
        self._schema_ready = False

    def _connect(self):
        return pymysql.connect(**self._params)

    def _ensure_schema(self, conn):
        """Create the table and seed it once. Safe when several tasks start together:
        the named lock lets only one of them do it at a time."""
        if self._schema_ready:
            return
        with conn.cursor() as cur:
            cur.execute("SELECT GET_LOCK('quickcart_schema', 10) AS got")
            try:
                cur.execute("CREATE TABLE IF NOT EXISTS orders ("
                            "id INT AUTO_INCREMENT PRIMARY KEY, "
                            "item VARCHAR(50) NOT NULL, qty INT NOT NULL)")
                cur.execute("SELECT COUNT(*) AS n FROM orders")
                if cur.fetchone()["n"] == 0:
                    cur.executemany("INSERT INTO orders (item, qty) VALUES (%s, %s)", SEED)
                conn.commit()
            finally:
                cur.execute("SELECT RELEASE_LOCK('quickcart_schema')")
        self._schema_ready = True

    def list_orders(self):
        conn = self._connect()
        try:
            self._ensure_schema(conn)
            with conn.cursor() as cur:
                cur.execute("SELECT id, item, qty FROM orders ORDER BY id")
                return cur.fetchall()
        finally:
            conn.close()

    def ping(self):
        try:
            self._connect().close()
            return True
        except pymysql.MySQLError:
            return False


def build_repository(env=None):
    """Pick the storage from the environment: MySQL in AWS, memory everywhere else."""
    env = os.environ if env is None else env
    if env.get("DB_HOST"):
        return MySQLOrders(env["DB_HOST"], env["DB_USER"], env["DB_PASSWORD"],
                           env.get("DB_NAME", "quickcart"))
    return InMemoryOrders()
```

| Part | Why |
|---|---|
| `InMemoryOrders` | Tests and laptops. No database needed |
| `MySQLOrders` | AWS. Host, user and password arrive as environment variables — ECS fills the password from Secrets Manager |
| `GET_LOCK('quickcart_schema', 10)` | Two tasks starting at once would both see an empty table and seed it twice. The named lock lets one go at a time. Tested: four tasks started together produced 3 rows, not 12 |
| `connect_timeout=3` | A database problem shows up as a quick error, not a request hanging for a minute |
| `build_repository()` | Chooses by environment: `DB_HOST` set means MySQL. The composition root, in one function |

**`app/app.py`**

```python
import json
import os
import random
import socket

from flask import Flask, jsonify

from repository import build_repository

app = Flask(__name__)
VERSION = os.environ.get("APP_VERSION", "v1")

# Share of /orders requests that fail. Always 0 in a healthy release.
# The "bad release" exercise changes this default to prove the canary catches it.
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))

repo = build_repository()


@app.get("/health")
def health():
    """For the load balancer. Never touches the database: a slow database must not
    make every task look dead and get replaced."""
    return jsonify(status="ok", version=VERSION)


@app.get("/ready")
def ready():
    """For people and smoke tests: can this task actually reach its database?"""
    ok = repo.ping()
    return jsonify(database="ok" if ok else "unreachable", version=VERSION), (200 if ok else 503)


@app.get("/")
def home():
    return jsonify(service="order-service", version=VERSION, served_by=socket.gethostname())


@app.get("/orders")
def orders():
    if random.random() < FAIL_RATE:
        print(json.dumps({"level": "ERROR", "event": "orders_failed", "version": VERSION}),
              flush=True)
        return jsonify(error="internal_error", version=VERSION), 500
    rows = repo.list_orders()
    return jsonify(version=VERSION, count=len(rows), orders=rows)
```

| Endpoint | Touches the database? | Why |
|---|---|---|
| `/health` | No | The load balancer checks this every 10 seconds. If it touched the database, a slow database would make every task look dead — and ECS would replace them all at once |
| `/ready` | Yes | For people and smoke tests: can this task really reach its data? |
| `/orders` | Yes | The real work |

**`app/test_app.py`**

```python
import app as order_service
from repository import InMemoryOrders, MySQLOrders, build_repository


def client():
    order_service.app.config["TESTING"] = True
    return order_service.app.test_client()


def test_health_is_ok_without_a_database():
    r = client().get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_orders_returns_three():
    order_service.FAIL_RATE = 0
    r = client().get("/orders")
    assert r.status_code == 200
    assert r.get_json()["count"] == 3


def test_every_response_reports_its_version():
    for path in ("/health", "/ready", "/", "/orders"):
        assert "version" in client().get(path).get_json()


def test_ready_reports_the_database():
    r = client().get("/ready")
    assert r.status_code == 200
    assert r.get_json()["database"] == "ok"


def test_memory_is_used_when_there_is_no_database():
    assert isinstance(build_repository({}), InMemoryOrders)


def test_mysql_is_used_when_a_database_is_configured():
    repo = build_repository({"DB_HOST": "db.internal", "DB_USER": "u", "DB_PASSWORD": "p"})
    assert isinstance(repo, MySQLOrders)
```

**`app/requirements.txt`**

```
flask==3.0.3
gunicorn==23.0.0
pymysql==1.1.1
```

The `Dockerfile` is A4's with one line changed, so the new file is copied into the image: `COPY app.py repository.py ./`.

```bash
cd app && python3 -m venv .venv && source .venv/bin/activate && pip install -q -r requirements-dev.txt && flake8 --max-line-length 100 *.py && pytest -q && cd ..
```

> ✅ **You should see:** `6 passed`.

---

<a id="stage-03"></a>

## Stage 03 — State bucket and shared stack

*Terraform's memory, then the things every environment shares: images, the audit trail and the budget.*

### 03.1 The state bucket

- [ ] Done

> 🔴 **The problem this solves.** Terraform needs one shared, locked, versioned memory — and the code that uses it can't create it.

If your A4 bucket `qc-tfstate-YOUR_ACCOUNT_ID` still exists, reuse it: this project's state keys are different, so nothing collides. Otherwise create it exactly as in A4 stage 02 — the one console step in this project: versioning on, public access blocked, ACLs disabled.

### 03.2 The shared stack: images, audit trail, budget

- [ ] Done

> 🔴 **The problem this solves.** Three things belong to the **account**, not to an environment. Images must survive environments being destroyed. An audit trail must record everything, in every region. And cost must be watched across everything at once.

`infra/shared/` keeps A4's `versions.tf`, `backend.tf` and `main.tf` (the ECR repository). Two files are new:

**`infra/shared/audit.tf`**

```hcl
# ---------- CloudTrail: who did what, in every region ----------
# Every API call in the account — console clicks, CLI, Terraform, Jenkins —
# recorded with who made it. The first thing asked in any security question.

data "aws_caller_identity" "current" {}

# CloudTrail can use a customer-managed KMS key; S3-managed encryption is accepted here.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "trail" {
  bucket = "qc-cloudtrail-${data.aws_caller_identity.current.account_id}"

  # Lab: let destroy delete the audit logs with the bucket. In production,
  # false — audit logs are evidence, and are often kept for years.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "trail" {
  statement {
    sid       = "CloudTrailCanCheckTheBucket"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "CloudTrailCanWriteLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail.json
}

# The trail's own log files are encrypted by S3; a KMS key is an optional extra.
#trivy:ignore:AWS-0015
resource "aws_cloudtrail" "account" {
  name                          = "quickcart-audit"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true

  # A signed digest file each hour proves the logs weren't edited afterwards.
  enable_log_file_validation = true

  depends_on = [aws_s3_bucket_policy.trail]
}

# ---------- a budget: find out about cost before the bill does ----------

resource "aws_budgets_budget" "monthly" {
  name         = "quickcart-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "cloudtrail_bucket" {
  description = "Where the audit trail is kept"
  value       = aws_s3_bucket.trail.bucket
}
```

| Piece | Why |
|---|---|
| `aws_cloudtrail`, `is_multi_region_trail` | Every API call in every region, with who made it — console, CLI, Terraform or Jenkins. The first thing a security review asks for |
| `enable_log_file_validation` | An hourly signed digest proves logs weren't edited after the fact |
| The bucket policy's two statements | CloudTrail must be able to check the bucket and write into its own folder, and nothing more. `bucket-owner-full-control` keeps the files yours |
| `aws_budgets_budget` | An email at 80% of the monthly amount, and another when AWS **forecasts** you'll go over — before it happens, not after |
| `#trivy:ignore` lines | Accepted findings sit on the resource they're about, with the reason |

**`infra/shared/variables.tf`**

```hcl
variable "alert_email" {
  description = "Who is told when spending passes the budget"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Expected monthly spend. You're emailed at 80% of it, and when AWS forecasts going over."
  type        = number
  default     = 100
}
```

**`infra/shared/terraform.tfvars`**

```hcl
alert_email        = "YOUR_EMAIL"
monthly_budget_usd = 100
```

```bash
terraform -chdir=infra/shared init && terraform -chdir=infra/shared apply
```

> ✅ **You should see:** The ECR repository and lifecycle policy (unless they exist from A4 — then `No changes` for those), plus the trail bucket, its settings, the trail and the budget. Type `yes`. Then an email from AWS Budgets confirming the alert address.

### 03.3 Build and push the first image

- [ ] Done

> 🔴 **The problem this solves.** Environments need an image to start. This is the only image you'll ever push by hand — from stage 20 on, Jenkins does it.

It's tagged `v2`: A4 may already have pushed a `v1` of the old app, and the repository refuses to overwrite a tag.

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

> ✅ **You should see:** `Login Succeeded`.

```bash
docker build --platform linux/amd64 --provenance=false --build-arg APP_VERSION=v2 -t YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders:v2 app && docker push YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders:v2
```

| Part | What it means |
|---|---|
| `--platform linux/amd64` | build for AWS's processors, not your Mac's |
| `--provenance=false` | one plain image, so the vulnerability scan shows on the tag |

> ✅ **You should see:** Layers uploading, then a `digest` line.

---

<a id="stage-04"></a>

## Stage 04 — Network: private, and a free path to S3

*Tasks move into private subnets — and one small addition cuts what that costs.*

### 04.1 Why private subnets now

- [ ] Done

> 🔴 **The problem this solves.** In A3 and A4, tasks sat in public subnets with public IPs, to save the cost of a NAT gateway. The security group kept them safe — but one wrong rule would expose them directly. In production, you want two locks, not one.

With `enable_nat = true`, tasks run in the **app** subnets. They have no public IP, so nothing on the internet can even address them; they reach out through the NAT gateway. The A4 network module already supports this — it's one value in `terraform.tfvars`.

|   | Public subnets + public IP (A4) | Private subnets + NAT (now) |
|---|---|---|
| Can the internet reach a task? | Only if the security group allows it | No — it has no public address |
| Protection layers | One: the security group | Two: no route in, and the security group |
| Cost | Free | About $1.10 a day per NAT gateway, plus data charges |

### 04.2 A gateway endpoint for S3

- [ ] Done

> 🔴 **The problem this solves.** Every image pull downloads the image's layers — which ECR stores in S3. From a private subnet, all of it flows through the NAT gateway, which charges for every gigabyte. Each deploy pays for it again.

Copy `infra/modules/network/` from A4, then add this at the end of its `main.tf`:

**`infra/modules/network/main.tf  (add at the end)`**

```hcl
# ---------- a free, private path to S3 ----------
# Container image layers are stored in S3. Without this, every image pull from
# a private subnet goes through the NAT gateway, which charges per gigabyte.
# A gateway endpoint costs nothing and keeps that traffic inside AWS.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for az in local.azs : aws_route_table.app[az].id]

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}
```

| Setting | Why |
|---|---|
| `vpc_endpoint_type = "Gateway"` | Gateway endpoints for S3 are free. (Interface endpoints for other services cost per hour) |
| `route_table_ids` | Adds an S3 route to the app subnets' route tables. S3 traffic now skips the NAT gateway |
| `data "aws_region"` | The service name contains the region. Looked up, never typed — so a second region still works |

---

<a id="stage-05"></a>

## Stage 05 — Module: certificate

*Route 53 and ACM working together: a certificate every browser trusts, with no manual step.*

### 05.1 How DNS validation works

- [ ] Done

> 🔴 **The problem this solves.** Anyone can ask for a certificate for any name. The issuer must check you really control the name before signing — and the check must be automatic, or renewals will fail a year from now when nobody remembers how.

| Step | Who | What happens |
|---|---|---|
| 1 | Terraform → ACM | Request a certificate for `orders.dev.YOUR_DOMAIN` |
| 2 | ACM | Reply: prove it by creating a record called `_abc123.orders.dev.YOUR_DOMAIN` with this value |
| 3 | Terraform → Route 53 | Create that record |
| 4 | ACM | Find the record, and issue the certificate |
| 5 | ACM, every year | Renew automatically — the record is still there |

Create `infra/modules/certificate/`. Its `versions.tf` is the same as network's.

### 05.2 The files

- [ ] Done

**`infra/modules/certificate/variables.tf`**

```hcl
variable "domain_name" {
  description = "The full name the site is served on, for example orders.dev.YOUR_DOMAIN"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a full lowercase host name, like orders.YOUR_DOMAIN."
  }
}

variable "zone_id" {
  description = "Route 53 hosted zone that owns the domain. The validation record is written there."
  type        = string
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/certificate/main.tf`**

```hcl
# A certificate browsers trust, proved by DNS: ACM asks for a special record,
# Terraform writes it into Route 53, ACM sees it and issues the certificate.
# No email, no manual step, and it renews itself for as long as the record exists.

resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  # A replacement is issued and attached before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.domain_name })
}

resource "aws_route53_record" "validation" {
  zone_id         = var.zone_id
  name            = one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_name])
  type            = one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_type])
  records         = [one([for d in aws_acm_certificate.this.domain_validation_options : d.resource_record_value])]
  ttl             = 60
  allow_overwrite = true
}

# Waits until ACM has actually issued the certificate. Anything that uses the
# ARN from here can't start with a certificate that isn't ready.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}
```

| Piece | Why |
|---|---|
| `validation_method = "DNS"` | The alternative, email, needs a person to click a link — once now, and at every renewal |
| `create_before_destroy` | A new certificate is attached before the old one is removed. No moment without HTTPS |
| `one([for d in ... : d.resource_record_name])` | ACM returns its instructions as a list. `one()` takes the single entry — and fails loudly if there were ever two, rather than silently using the wrong one |
| `allow_overwrite = true` | If a previous certificate for this name left its record behind, reuse it instead of failing |
| `aws_acm_certificate_validation` | Waits until the certificate is really issued. Usually a minute or two |

**`infra/modules/certificate/outputs.tf`**

```hcl
output "certificate_arn" {
  description = "The issued certificate. Read from the validation, so it only exists once the certificate is ready."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
```

> 💡 **Why the output comes from the validation, not the certificate.** The load balancer uses this ARN. Reading it from the **validation** resource makes Terraform wait until the certificate is issued before attaching it. Read it from the certificate itself, and Terraform could try to attach a certificate that isn't ready — the listener would fail.

---

<a id="stage-06"></a>

## Stage 06 — Module: compute

*The load balancer now uses the real certificate, and records every request in S3.*

### 06.1 What changed from A4

- [ ] Done

> 🔴 **The problem this solves.** Metrics tell you *how many* requests failed. During an incident you need to know *which* ones: the path, the client, the status, how long each part took. And the self-signed certificate has to go.

| Removed | Added |
|---|---|
| The self-signed certificate and the tls provider | `certificate_arn` as an input, from the certificate module |
|  | An S3 bucket for access logs, with a policy letting only AWS's load balancer service write into it |
|  | New outputs for alarms and DNS |

### 06.2 The files

- [ ] Done

**`infra/modules/compute/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

**`infra/modules/compute/variables.tf`**

```hcl
variable "name" {
  description = "Prefix for every resource name. Keep it short: load balancer and target group names are limited to 32 characters."
  type        = string

  validation {
    condition     = length(var.name) <= 20
    error_message = "name must be 20 characters or fewer, so names like <name>-canary stay under AWS's 32-character limit."
  }
}

variable "vpc_id" {
  description = "The VPC for the target groups"
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the load balancer, one per zone"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An application load balancer needs subnets in at least two zones."
  }
}

variable "alb_security_group_id" {
  description = "Security group for the load balancer"
  type        = string
}

variable "app_port" {
  description = "The port the targets listen on"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Page the load balancer checks. Must return 200 without touching a database."
  type        = string
  default     = "/health"
}

variable "canary_weight" {
  description = "Percentage of traffic sent to the canary target group. 0 means no canary."
  type        = number
  default     = 0

  validation {
    condition     = var.canary_weight >= 0 && var.canary_weight <= 100
    error_message = "canary_weight must be between 0 and 100."
  }
}

variable "certificate_arn" {
  description = "The HTTPS certificate, issued and validated by the certificate module"
  type        = string

  validation {
    condition     = startswith(var.certificate_arn, "arn:aws:acm:")
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "access_log_retention_days" {
  description = "How long to keep load balancer access logs in S3"
  type        = number
  default     = 30
}

variable "logs_force_destroy" {
  description = "Let terraform destroy delete the log bucket even when it holds logs. True for labs; false where logs are evidence."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Stop the load balancer being deleted. True for production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/compute/main.tf`**

```hcl
# ---------- the cluster ----------

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = var.tags
}

# ---------- access logs: every request, kept in S3 ----------
# Metrics say how many requests failed. Access logs say WHICH ones: path,
# client, status, and how long each part took. The first place to look in 5xx triage.

data "aws_caller_identity" "current" {}

# The AWS account that runs load balancers in this region. Only it may write logs.
data "aws_elb_service_account" "this" {}

# ALB access logs only support S3-managed encryption, so a customer-managed key isn't an option.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.logs_force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

# ---------- the load balancer ----------

# Public by design: this is the site's front door.
#trivy:ignore:AWS-0053
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.deletion_protection

  # Reject requests with malformed headers instead of passing them to the app.
  # Closes off a class of request-smuggling attacks.
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  # AWS checks it may write to the bucket when logging is switched on.
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = var.tags
}

# Two target groups: "stable" serves normal traffic, "canary" receives a
# small share while a new version is tested. A5 uses the canary.
resource "aws_lb_target_group" "this" {
  for_each = toset(["stable", "canary"])

  name                 = "${var.name}-${each.key}"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.this["stable"].arn
        weight = 100 - var.canary_weight
      }

      target_group {
        arn    = aws_lb_target_group.this["canary"].arn
        weight = var.canary_weight
      }
    }
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

| Piece | Why |
|---|---|
| `data "aws_elb_service_account"` | Load balancers write logs from an AWS-owned account that differs by region. Looked up, so it's always the right one |
| The bucket policy | Only that account may write, and only into this account's folder |
| `force_destroy` | Lets `terraform destroy` empty and delete the bucket. True for a lab; in production, false — logs can be evidence |
| Lifecycle, 30 days | Access logs grow every second. Old ones are deleted automatically |
| `depends_on = [aws_s3_bucket_policy.alb_logs]` | AWS tests it can write to the bucket when logging is switched on. Without this, the load balancer could be created first and fail |
| `certificate_arn = var.certificate_arn` | The module no longer makes a certificate; it's given one. Each module does one job |

**`infra/modules/compute/outputs.tf`**

```hcl
output "cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  description = "The load balancer's address"
  value       = aws_lb.this.dns_name
}

output "target_group_arns" {
  description = "Target group ARNs, keyed stable and canary"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "https_listener_arn" {
  description = "The HTTPS listener"
  value       = aws_lb_listener.https.arn
}

output "alb_arn_suffix" {
  description = "The load balancer, as CloudWatch names it"
  value       = aws_lb.this.arn_suffix
}

output "alb_zone_id" {
  description = "The load balancer's DNS zone, for Route 53 alias records"
  value       = aws_lb.this.zone_id
}

output "target_group_arn_suffixes" {
  description = "Target groups as CloudWatch names them, keyed stable and canary"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn_suffix }
}

output "alb_logs_bucket" {
  description = "Where load balancer access logs go"
  value       = aws_s3_bucket.alb_logs.bucket
}
```

---

<a id="stage-07"></a>

## Stage 07 — Module: ecs-service

*Secrets from Secrets Manager, auto scaling on CPU, and who owns the task count.*

### 07.1 What changed from A4

- [ ] Done

> 🔴 **The problem this solves.** The app now needs a database password — which must never appear in the task definition, the plan, or a log. And a fixed two tasks is either wasteful at night or too few at lunchtime.

### 07.2 The files

- [ ] Done

**`infra/modules/ecs-service/variables.tf`**

```hcl
variable "name" {
  description = "Service name, also used for the task family and log group, for example qc-dev-use1-orders"
  type        = string
}

variable "region" {
  description = "Region, for the log configuration"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name, needed by auto scaling"
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster to run in"
  type        = string
}

variable "image" {
  description = "Full image address including tag, for example YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders:a1b2c3d"
  type        = string

  validation {
    condition     = can(regex(":[^/]+$", var.image)) && !endswith(var.image, ":latest")
    error_message = "image must include a tag, and the tag must not be latest. Use a version or a commit ID."
  }
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "CPU units for the task. 1024 is one vCPU."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "cpu must be a Fargate size: 256, 512, 1024, 2048 or 4096."
  }
}

variable "memory" {
  description = "Memory for the task in MB. Must be a valid pairing with cpu."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "How many copies to START with. After creation, auto scaling (or nobody) owns the count — Terraform won't reset it."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count cannot be negative."
  }
}

variable "subnet_ids" {
  description = "Subnets the tasks run in"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the tasks"
  type        = string
}

variable "assign_public_ip" {
  description = "Give tasks a public IP. Needed when their subnets have no NAT, so they can pull images."
  type        = bool
  default     = false
}

variable "target_group_arn" {
  description = "Target group the tasks register with"
  type        = string
}

variable "execution_role_arn" {
  description = "Role ECS uses before the app starts: pull the image, write logs"
  type        = string
}

variable "task_role_arn" {
  description = "Role the app itself uses while running. Null when the app calls no AWS services."
  type        = string
  default     = null
}

variable "environment_variables" {
  description = "Plain settings for the container"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Settings read from Secrets Manager when a task starts, as NAME => secret ARN with key. Never visible in the task definition."
  type        = map(string)
  default     = {}
}

variable "autoscaling" {
  description = "Scale on CPU between min and max tasks. Null for a fixed count."
  type = object({
    min        = number
    max        = number
    cpu_target = number
  })
  default = null

  validation {
    condition     = var.autoscaling == null ? true : (var.autoscaling.min >= 1 && var.autoscaling.max >= var.autoscaling.min && var.autoscaling.cpu_target > 10 && var.autoscaling.cpu_target < 90)
    error_message = "autoscaling needs min of at least 1, max no lower than min, and cpu_target between 10 and 90."
  }
}

variable "log_retention_days" {
  description = "How long to keep logs"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/ecs-service/main.tf`**

```hcl
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Must match how the image was built: --platform linux/amd64.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [for k in sort(keys(var.environment_variables)) : {
      name  = k
      value = var.environment_variables[k]
    }]

    secrets = [for k in sort(keys(var.secrets)) : {
      name      = k
      valueFrom = var.secrets[k]
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Replace one task at a time without ever dropping below full strength.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # If new tasks keep failing, stop and go back to the last working version.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 30

  # Terraform waits until the release has finished before reporting success.
  # This is the "wait for stable" step the pipeline relies on.
  wait_for_steady_state = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # Once created, the task count belongs to auto scaling. Without this, every
  # apply would reset it to desired_count — scaling down in the middle of a busy period.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

# ---------- auto scaling on CPU ----------

resource "aws_appautoscaling_target" "this" {
  count = var.autoscaling == null ? 0 : 1

  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling.min
  max_capacity       = var.autoscaling.max
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.autoscaling == null ? 0 : 1

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  # Add tasks when average CPU is above the target, remove them when below.
  # Scale out fast, scale in slowly, so a short dip doesn't remove capacity.
  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

| Piece | Why |
|---|---|
| `secrets = [...]` in the container | The task definition holds only the secret's **address**. When a task starts, ECS fetches the value and hands it to the container. Anyone reading the task definition sees an ARN, never a password |
| `ignore_changes = [desired_count]` | Once the service exists, auto scaling decides how many tasks run. Without this, every `terraform apply` would reset the count — shrinking the service mid-rush |
| `aws_appautoscaling_target` | The limits: never fewer than `min`, never more than `max`. The max caps what a traffic spike can cost |
| `TargetTrackingScaling` on CPU | Keep average CPU near the target by adding or removing tasks. Like a thermostat |
| Scale out in 60s, in over 300s | React quickly to load; remove capacity cautiously, so a brief lull doesn't strip the service just before the next wave |
| `count = var.autoscaling == null ? 0 : 1` | The canary copy passes `null`: it always runs exactly one task |

> 💡 **A lifecycle rule can't be switched on and off.** You might want `ignore_changes` only when auto scaling is on. Terraform doesn't allow that — `lifecycle` must be fixed values. So the rule applies to every service, and `desired_count` now means "how many to **start** with". The variable's description says so, so nobody is surprised.

**`infra/modules/ecs-service/outputs.tf`**

```hcl
output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "The task definition revision now in use"
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "Where the app's logs go"
  value       = aws_cloudwatch_log_group.this.name
}

output "service_arn" {
  description = "ECS service ARN"
  value       = aws_ecs_service.this.id
}
```

---

<a id="stage-08"></a>

## Stage 08 — Module: database

*MySQL in subnets with no way out, reachable only by the app and the ops instance.*

### 08.1 The files

- [ ] Done

> 🔴 **The problem this solves.** The data is the one thing you can't rebuild with `terraform apply`. It needs the tightest network position, a password nobody knows, backups, and protection against being deleted.

Create `infra/modules/database/`, with network's `versions.tf`.

**`infra/modules/database/variables.tf`**

```hcl
variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in"
  type        = string
}

variable "subnet_ids" {
  description = "Data subnets, one per zone. They have no route out of the VPC."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS needs subnets in at least two zones, even for a single-zone database."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 3306 — the app, and the operations task"
  type        = list(string)
}

variable "instance_class" {
  description = "Database size. db.t4g.micro is the smallest."
  type        = string
  default     = "db.t4g.micro"
}

variable "multi_az" {
  description = "Keep a standby copy in a second zone. Doubles the cost; true for production."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuse deletion, even from the console. True for production."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automatic backups. 0 turns backups off."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/database/main.tf`**

```hcl
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Database: MySQL from the app and operations tasks only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from allowed security groups"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  # No egress block: a database answers connections, it never starts them.

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-mysql8"
  family = "mysql8.0"

  # Log queries slower than 2 seconds, so slow SQL can be found later.
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "quickcart"
  username = "qcadmin"

  # RDS creates the password, keeps it in Secrets Manager and can rotate it.
  # It never appears in this code, in the plan, or in the state file.
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period   = var.backup_retention_days
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-db-final" : null

  tags = var.tags
}
```

| Setting | Why |
|---|---|
| No `egress` block | A database answers connections; it never starts them. With no outbound rule, even a compromised database can't send data anywhere |
| `allowed_security_group_ids` | Only named groups — the app's and the ops instance's — can connect on 3306 |
| Data subnets | Their route table has no route out of the VPC at all |
| `manage_master_user_password` | RDS makes the password and keeps it in Secrets Manager. It never exists in code, in the plan, or in state |
| `storage_encrypted` | Encrypted on disk, and in every snapshot |
| Slow query log | Queries over 2 seconds are recorded, for the day someone asks why the site is slow |
| `deletion_protection` and `skip_final_snapshot` | Tied together: a protected database also gets a final snapshot if it's ever deleted. prod sets it true |

**`infra/modules/database/outputs.tf`**

```hcl
output "address" {
  description = "Host name to connect to"
  value       = aws_db_instance.this.address
}

output "database_name" {
  description = "The database created inside the instance"
  value       = aws_db_instance.this.db_name
}

output "secret_arn" {
  description = "Secrets Manager secret holding the username and password"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
```

---

<a id="stage-09"></a>

## Stage 09 — Module: ops-access — SSM, not a bastion

*How engineers reach private resources without SSH, keys or open ports.*

### 09.1 The problem with bastion hosts

- [ ] Done

> 🔴 **The problem this solves.** The database is deliberately unreachable. But an engineer still sometimes needs to look at data — during an incident, or to check a migration. The traditional answer is a **bastion host**: a public server with SSH open, that you jump through.

|   | Bastion host | Session Manager |
|---|---|---|
| Public IP | Yes | No |
| Inbound port | 22, open to some addresses | None at all |
| Credentials | SSH keys — copied around, rarely rotated, hard to revoke | Your normal AWS login and IAM permissions |
| Who connected, when | Only if you set up logging | Every session start recorded in CloudTrail |
| Removing someone's access | Find and delete their key on every server | Remove their IAM permission |

**How it works without an open port:** the SSM agent on the instance makes an **outbound** connection to the Systems Manager service and keeps it open. When you start a session, your traffic travels down that connection. Nothing ever connects *in*.

### 09.2 The files

- [ ] Done

Create `infra/modules/ops-access/`, with network's `versions.tf`.

**`infra/modules/ops-access/variables.tf`**

```hcl
variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "vpc_id" {
  description = "VPC the instance lives in"
  type        = string
}

variable "subnet_id" {
  description = "A private app subnet. It needs a way out (NAT) to reach Systems Manager."
  type        = string
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/ops-access/main.tf`**

```hcl
# A tiny instance that lets engineers reach private resources — like the
# database — through Systems Manager Session Manager.
#
# Compared with a bastion host: no public IP, no SSH key to lose, no port 22
# open to anyone, and every session is logged in CloudTrail with who started it.

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-ops"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

# The only permission it needs: to be managed by Systems Manager.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-ops"
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = "${var.name}-ops"
  description = "Ops access instance: nothing may connect in"
  vpc_id      = var.vpc_id

  # No ingress block at all. Session Manager connections are started FROM the
  # instance, outbound, so no inbound port is ever needed.

  # Accepted: it must reach Systems Manager and the database.
  #trivy:ignore:AWS-0104
  egress {
    description = "outbound to Systems Manager and the database"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-ops" })
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.al2023_arm.id
  instance_type               = "t4g.nano"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name}-ops" })
}
```

| Setting | Why |
|---|---|
| `AmazonSSMManagedInstanceCore` | The one permission it needs: to register with Systems Manager |
| No `ingress` block | Nothing may connect in — and nothing needs to |
| A private app subnet | No public IP. It reaches Systems Manager through the NAT gateway |
| `t4g.nano`, arm64 | The smallest instance there is. It only relays connections |
| No `key_name` | There is no SSH key. Not a hidden one — none |
| Amazon Linux 2023 | The SSM agent comes pre-installed |

**`infra/modules/ops-access/outputs.tf`**

```hcl
output "instance_id" {
  description = "Target for aws ssm start-session"
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Give this group access to anything engineers must reach, such as the database"
  value       = aws_security_group.this.id
}
```

> ⚠️ **It needs a way out.** The agent must reach Systems Manager. Here that's the NAT gateway. Without NAT you'd add interface endpoints for `ssm`, `ssmmessages` and `ec2messages` — about $7 a month each per zone.

---

<a id="stage-10"></a>

## Stage 10 — Module: monitoring

*The Week 1 SLO, turned into an alarm that emails you.*

### 10.1 From an SLO to an alarm

- [ ] Done

> 🔴 **The problem this solves.** "Is the site OK?" has no useful answer without a definition. Week 1's answer: an SLO. "99.5% of requests succeed" leaves an error budget of 0.5% — spend more than that, and someone should know.

Create `infra/modules/monitoring/`, with network's `versions.tf`.

**`infra/modules/monitoring/variables.tf`**

```hcl
variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "alert_email" {
  description = "Who is told when an alarm fires. The subscription must be confirmed from the email."
  type        = string
}

variable "slo_availability_percent" {
  description = "The availability target. 99.5 means at most 0.5% of requests may fail."
  type        = number
  default     = 99.5

  validation {
    condition     = var.slo_availability_percent > 90 && var.slo_availability_percent < 100
    error_message = "slo_availability_percent must be between 90 and 100, for example 99.5."
  }
}

variable "alb_arn_suffix" {
  description = "The load balancer, as CloudWatch names it"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "The stable target group, as CloudWatch names it"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "service_name" {
  description = "The stable ECS service name"
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance identifier. Null when there is no database."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
```

**`infra/modules/monitoring/main.tf`**

```hcl
# Alarms that match what customers feel, sent to email through SNS.

#trivy:ignore:AWS-0136
resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  error_budget_percent = 100 - var.slo_availability_percent
  alb_dims             = { LoadBalancer = var.alb_arn_suffix }
}

# The SLO alarm. Failed requests as a share of all requests, over 5 minutes.
# Counts both the app's errors and the load balancer's own (no task answered).
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.name}-error-rate-above-slo"
  alarm_description   = "More than ${local.error_budget_percent}% of requests failed: the ${var.slo_availability_percent}% availability target is being missed."
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.error_budget_percent
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * (FILL(app, 0) + FILL(lb, 0)) / requests"
    label       = "Failed requests (%)"
    return_data = true
  }

  metric_query {
    id = "app"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "lb"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.name}-unhealthy-targets"
  alarm_description   = "At least one task has failed its health check for 3 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "service_cpu" {
  alarm_name          = "${var.name}-service-cpu-high"
  alarm_description   = "Average CPU above 85% for 10 minutes, even with auto scaling. Check whether it has hit its maximum."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  count = var.db_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-db-storage-low"
  alarm_description   = "Less than 2 GB of database storage left."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count = var.db_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-db-cpu-high"
  alarm_description   = "Database CPU above 80% for 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}
```

| Alarm | Fires when | Tells you |
|---|---|---|
| **Error rate above SLO** | Failed requests over 5 minutes exceed the error budget | Customers are being hurt, now |
| Unhealthy targets | Any task failing health checks for 3 minutes | Tasks crashing, or unable to start |
| Service CPU | Average above 85% for 10 minutes | Auto scaling has probably hit its maximum |
| Database storage | Under 2 GB free | The database will stop accepting writes |
| Database CPU | Above 80% for 10 minutes | Slow queries, or not enough capacity |

| Detail | Why |
|---|---|
| `metric_query` with an expression | The error **rate**, not the error count. 50 errors in 100 requests is a crisis; 50 in a million is noise |
| `FILL(app, 0)` | A 5-minute period with no errors has no data point, not a zero. Without FILL, the sum would be empty |
| App errors **and** load balancer errors | A 502 — no task answered — never reaches your app's metrics, but a customer still saw it fail |
| `treat_missing_data = "notBreaching"` | No traffic at 3am isn't an outage |
| `ok_actions` | You're also told when it recovers — so you know when an incident ended |

**`infra/modules/monitoring/outputs.tf`**

```hcl
output "alerts_topic_arn" {
  description = "Send anything else that needs a person here"
  value       = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  description = "Every alarm this module created"
  value = concat(
    [aws_cloudwatch_metric_alarm.error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.unhealthy_targets.alarm_name,
    aws_cloudwatch_metric_alarm.service_cpu.alarm_name],
    aws_cloudwatch_metric_alarm.db_storage[*].alarm_name,
    aws_cloudwatch_metric_alarm.db_cpu[*].alarm_name,
  )
}
```

dev's target is 99.0% and prod's is 99.5% — a value per environment, in `terraform.tfvars`.

---

<a id="stage-11"></a>

## Stage 11 — Module: platform

*The composition root: nine pieces connected in one place.*

### 11.1 How the pieces fit

- [ ] Done

> 🔴 **The problem this solves.** Nine modules that don't know about each other still have to be wired together — once, correctly, in one place. Modules never call each other; the platform connects them.

```
network ──vpc_id, subnets──▶ security-groups, compute, database, ops-access, services
certificate ──certificate_arn──▶ compute
compute ──cluster, target groups──▶ services
compute ──alb name, zone──▶ Route 53 alias record
security-groups + ops-access ──allowed groups──▶ database
database ──address, secret──▶ services, ops task
compute + services ──names──▶ monitoring
```

`versions.tf` is the same as network's — the tls provider is gone.

### 11.2 The files

- [ ] Done

**`infra/modules/platform/variables.tf`**

```hcl
variable "project" {
  description = "Short project code, used at the start of every name"
  type        = string
  default     = "qc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.project))
    error_message = "project must be 2 to 6 lowercase letters or digits, starting with a letter."
  }
}

variable "environment" {
  description = "Which environment this is"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be dev, stg or prod."
  }
}

variable "region" {
  description = "AWS region to build in"
  type        = string
}

variable "vpc_cidr" {
  description = "Address range for this environment's VPC. Give each environment and region its own, so they could be connected later."
  type        = string
}

variable "enable_nat" {
  description = "Build NAT gateways and run tasks in private subnets. About $32 a month per gateway."
  type        = bool
  default     = false
}

variable "single_nat" {
  description = "Share one NAT gateway across zones. Only used when enable_nat is true."
  type        = bool
  default     = true
}

variable "image_repository_url" {
  description = "ECR repository address, without a tag"
  type        = string
}

variable "stable_image_tag" {
  description = "Version serving normal traffic"
  type        = string

  validation {
    condition     = length(var.stable_image_tag) > 0 && var.stable_image_tag != "latest"
    error_message = "stable_image_tag must be a real version or commit ID, never latest."
  }
}

variable "canary_image_tag" {
  description = "Version the canary runs. Same as stable when there is no canary."
  type        = string

  validation {
    condition     = length(var.canary_image_tag) > 0 && var.canary_image_tag != "latest"
    error_message = "canary_image_tag must be a real version or commit ID, never latest."
  }
}

variable "canary_weight" {
  description = "Percentage of traffic sent to the canary"
  type        = number
  default     = 0

  validation {
    condition     = var.canary_weight >= 0 && var.canary_weight <= 50
    error_message = "canary_weight must be between 0 and 50. A canary is a small share; above that, promote instead."
  }
}

variable "desired_count" {
  description = "Stable tasks to start with, and the fewest auto scaling may go to. At least 2, so one zone can fail."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 2
    error_message = "desired_count must be at least 2, so the service survives losing a zone."
  }
}

variable "max_count" {
  description = "The most stable tasks auto scaling may run. Caps the cost of a traffic spike."
  type        = number
  default     = 4
}

variable "domain_name" {
  description = "Full host name for this environment, for example orders.dev.YOUR_DOMAIN"
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone that owns domain_name"
  type        = string
}

variable "alert_email" {
  description = "Who receives alarms for this environment"
  type        = string
}

variable "slo_availability_percent" {
  description = "Availability target for this environment"
  type        = number
  default     = 99.5
}

variable "enable_ops_access" {
  description = "Build the Session Manager instance engineers use to reach private resources. Needs enable_nat."
  type        = bool
  default     = true
}

variable "cpu" {
  description = "CPU units per task"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Memory per task in MB"
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "How long to keep logs"
  type        = number
  default     = 7
}

variable "alb_deletion_protection" {
  description = "Stop the load balancer being deleted"
  type        = bool
  default     = false
}

variable "enable_database" {
  description = "Build a MySQL database, connect the app to it, and add the operations task for safe SQL"
  type        = bool
  default     = true
}

variable "db_multi_az" {
  description = "Standby database copy in a second zone. True for production."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database. True for production."
  type        = bool
  default     = false
}
```

**`infra/modules/platform/main.tf`**

```hcl
locals {
  # A short code for the region keeps names under AWS's length limits
  # and makes the region visible in every name.
  region_codes = {
    "us-east-1"      = "use1"
    "us-east-2"      = "use2"
    "us-west-2"      = "usw2"
    "eu-west-1"      = "euw1"
    "eu-central-1"   = "euc1"
    "ap-south-1"     = "aps1"
    "ap-southeast-1" = "apse1"
  }
  region_code = lookup(local.region_codes, var.region, replace(var.region, "-", ""))

  name = "${var.project}-${var.environment}-${local.region_code}"

  tags = {
    Project     = "quickcart"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # With NAT, tasks run in private app subnets. Without it, they need public
  # subnets and a public IP to reach ECR. The security group still only lets
  # the load balancer in either way.
  task_subnet_ids  = var.enable_nat ? module.network.app_subnet_ids : module.network.public_subnet_ids
  assign_public_ip = !var.enable_nat
}

# ---------- the network and who may talk to whom ----------

module "network" {
  source = "../network"

  name       = local.name
  cidr       = var.vpc_cidr
  enable_nat = var.enable_nat
  single_nat = var.single_nat
  tags       = local.tags
}

module "security_groups" {
  source = "../security-groups"

  name     = local.name
  vpc_id   = module.network.vpc_id
  vpc_cidr = var.vpc_cidr
  tags     = local.tags
}

# ---------- a trusted certificate and a real name ----------

module "certificate" {
  source = "../certificate"

  domain_name = var.domain_name
  zone_id     = var.zone_id
  tags        = local.tags
}

module "compute" {
  source = "../compute"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security_groups.alb_id
  certificate_arn       = module.certificate.certificate_arn
  canary_weight         = var.canary_weight
  deletion_protection   = var.alb_deletion_protection
  tags                  = local.tags
}

# orders.dev.YOUR_DOMAIN -> the load balancer. An alias record follows the
# load balancer's changing IP addresses automatically, and costs nothing.
resource "aws_route53_record" "site" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.compute.alb_dns_name
    zone_id                = module.compute.alb_zone_id
    evaluate_target_health = true
  }
}

# ---------- the role ECS uses to start tasks ----------
# IAM is global, not regional. The name includes the region code, otherwise
# a second region would fail with "role already exists".

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- engineers' way in: Session Manager, not a bastion ----------

module "ops_access" {
  source = "../ops-access"
  count  = var.enable_ops_access ? 1 : 0

  name      = local.name
  vpc_id    = module.network.vpc_id
  subnet_id = module.network.app_subnet_ids[0]
  tags      = local.tags
}

# ---------- the service: a stable copy and a canary copy ----------

locals {
  # Only the app and the ops instance may reach the database.
  db_clients = concat([module.security_groups.app_id], module.ops_access[*].security_group_id)

  # When there's a database, ECS reads the password from Secrets Manager as the
  # task starts. It never appears in the task definition, the plan, or a log.
  app_env = var.enable_database ? {
    DB_HOST = module.database[0].address
    DB_NAME = module.database[0].database_name
  } : {}
  app_secrets = var.enable_database ? {
    DB_USER     = "${module.database[0].secret_arn}:username::"
    DB_PASSWORD = "${module.database[0].secret_arn}:password::"
  } : {}
}

module "orders" {
  source = "../ecs-service"

  for_each = {
    # Stable scales between desired_count and max_count on CPU.
    stable = { tag = var.stable_image_tag, count = var.desired_count, suffix = "", scaling = { min = var.desired_count, max = var.max_count, cpu_target = 60 } }
    # The canary always runs one task. Its share of traffic is set by canary_weight.
    canary = { tag = var.canary_image_tag, count = 1, suffix = "-canary", scaling = null }
  }

  name                  = "${local.name}-orders${each.value.suffix}"
  region                = var.region
  cluster_arn           = module.compute.cluster_arn
  cluster_name          = module.compute.cluster_name
  image                 = "${var.image_repository_url}:${each.value.tag}"
  cpu                   = var.cpu
  memory                = var.memory
  desired_count         = each.value.count
  autoscaling           = each.value.scaling
  subnet_ids            = local.task_subnet_ids
  security_group_id     = module.security_groups.app_id
  assign_public_ip      = local.assign_public_ip
  target_group_arn      = module.compute.target_group_arns[each.key]
  execution_role_arn    = aws_iam_role.execution.arn
  environment_variables = local.app_env
  secrets               = local.app_secrets
  log_retention_days    = var.log_retention_days
  tags                  = local.tags

  # Permissions must exist before any task tries to start — including the
  # right to read the database secret.
  depends_on = [aws_iam_role_policy_attachment.execution, aws_iam_role_policy.read_db_secret]
}

# ---------- alarms ----------

module "monitoring" {
  source = "../monitoring"

  name                     = local.name
  alert_email              = var.alert_email
  slo_availability_percent = var.slo_availability_percent
  alb_arn_suffix           = module.compute.alb_arn_suffix
  target_group_arn_suffix  = module.compute.target_group_arn_suffixes["stable"]
  cluster_name             = module.compute.cluster_name
  service_name             = module.orders["stable"].service_name
  db_instance_id           = var.enable_database ? "${local.name}-db" : null
  tags                     = local.tags
}
```

| Piece | Why |
|---|---|
| `aws_route53_record "site"`, an alias | Points the name at the load balancer. An alias follows the load balancer's changing IP addresses by itself, and alias lookups are free |
| `evaluate_target_health` | Route 53 knows whether the load balancer has healthy targets — the basis for failing over between regions later |
| `db_clients` | The app's security group, plus the ops instance's when it exists — using `module.ops_access[*]`, which is an empty list when it's switched off |
| `app_env`, `app_secrets` | The database's address as plain settings; the username and password as secrets |
| Stable: `scaling = { ... }`; canary: `null` | Stable scales with load. The canary is one task whose traffic is set by `canary_weight` |
| `depends_on` includes `read_db_secret` | A task that starts before it may read its secret fails straight away |

**`infra/modules/platform/database.tf`**

```hcl
# Everything here exists only when enable_database is true.

module "database" {
  source = "../database"
  count  = var.enable_database ? 1 : 0

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.data_subnet_ids
  allowed_security_group_ids = local.db_clients
  multi_az                   = var.db_multi_az
  deletion_protection        = var.db_deletion_protection
  tags                       = local.tags
}

# The execution role reads the database secret so ECS can hand the username
# and password to the app and the operations task. Scoped to this one secret.
data "aws_iam_policy_document" "read_db_secret" {
  count = var.enable_database ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.database[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "read_db_secret" {
  count = var.enable_database ? 1 : 0

  name   = "read-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_db_secret[0].json
}

resource "aws_cloudwatch_log_group" "ops_sql" {
  count = var.enable_database ? 1 : 0

  name              = "/ecs/${local.name}-ops-sql"
  retention_in_days = 30
  tags              = local.tags
}

locals {
  # Runs inside the VPC. Wraps one statement in a transaction and either
  # rolls it back (dry-run) or commits it. The statement arrives base64-encoded
  # so quotes and new lines survive the trip.
  ops_sql_script = <<-EOT
    set -eu
    printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" > /tmp/my.cnf
    chmod 600 /tmp/my.cnf
    echo "$SQL_B64" | base64 -d > /tmp/statement.sql
    if [ "$MODE" = "commit" ]; then END_TX="COMMIT"; else END_TX="ROLLBACK"; fi
    printf 'START TRANSACTION;\n%s;\nSELECT ROW_COUNT() AS rows_affected;\n%s;\n' "$(cat /tmp/statement.sql)" "$END_TX" > /tmp/run.sql
    echo "Mode: $MODE. Ending with: $END_TX"
    mysql --defaults-extra-file=/tmp/my.cnf --database="$DB_NAME" --table < /tmp/run.sql
    echo "Finished: $END_TX"
  EOT
}

resource "aws_ecs_task_definition" "ops_sql" {
  count = var.enable_database ? 1 : 0

  family                   = "${local.name}-ops-sql"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "sql"
    image     = "public.ecr.aws/docker/library/mysql:8.0"
    essential = true

    # Run the script instead of starting a MySQL server.
    entryPoint = ["sh", "-c"]
    command    = [local.ops_sql_script]

    environment = [
      { name = "DB_HOST", value = module.database[0].address },
      { name = "DB_NAME", value = module.database[0].database_name },
      { name = "MODE", value = "dry-run" },
      { name = "SQL_B64", value = "" },
    ]

    secrets = [
      { name = "DB_USER", valueFrom = "${module.database[0].secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${module.database[0].secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ops_sql[0].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ops"
      }
    }
  }])

  tags = local.tags
}
```

The operations task from A5, for the safe-SQL job: it runs one statement inside the VPC, in a transaction, and never needs Jenkins to see the password.

**`infra/modules/platform/outputs.tf`**

```hcl
output "name" {
  description = "The prefix used for every name in this environment"
  value       = local.name
}

output "alb_url" {
  description = "The site's address, with a trusted certificate"
  value       = "https://${var.domain_name}"
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = module.compute.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "azs" {
  description = "Availability zones in use"
  value       = module.network.azs
}

output "stable_image_tag" {
  description = "Version serving normal traffic"
  value       = var.stable_image_tag
}

output "canary_image_tag" {
  description = "Version the canary runs"
  value       = var.canary_image_tag
}

output "canary_weight" {
  description = "Share of traffic on the canary"
  value       = var.canary_weight
}

output "target_group_arns" {
  description = "Target groups, keyed stable and canary"
  value       = module.compute.target_group_arns
}

output "log_groups" {
  description = "Log groups, keyed stable and canary"
  value       = { for k, m in module.orders : k => m.log_group_name }
}

# ---------- used by the operations jobs in A5 ----------

output "task_subnet_ids" {
  description = "Subnets tasks run in"
  value       = local.task_subnet_ids
}

output "app_security_group_id" {
  description = "Security group for app and operations tasks"
  value       = module.security_groups.app_id
}

output "assign_public_ip" {
  description = "Whether tasks need a public IP"
  value       = local.assign_public_ip
}

output "ops_sql_task_family" {
  description = "Task definition family for the safe SQL job. Null when there is no database."
  value       = var.enable_database ? aws_ecs_task_definition.ops_sql[0].family : null
}

output "ops_sql_log_group" {
  description = "Where the safe SQL job's output goes"
  value       = var.enable_database ? aws_cloudwatch_log_group.ops_sql[0].name : null
}

output "ops_instance_id" {
  description = "Session Manager target for reaching the database. Null when ops access is off."
  value       = var.enable_ops_access ? module.ops_access[0].instance_id : null
}

output "db_address" {
  description = "Database host name, reachable only from inside the VPC"
  value       = var.enable_database ? module.database[0].address : null
}

output "alerts_topic_arn" {
  description = "Where this environment's alarms go"
  value       = module.monitoring.alerts_topic_arn
}

output "alb_logs_bucket" {
  description = "Load balancer access logs"
  value       = module.compute.alb_logs_bucket
}
```

---

<a id="stage-12"></a>

## Stage 12 — Tests and checks

*14 plans against a mocked AWS, then every linter — before anything costs money.*

### 12.1 The tests

- [ ] Done

> 🔴 **The problem this solves.** A wrong rule in the platform module would only show up after a 15-minute apply — or never, until an outage.

**`infra/modules/platform/tests/platform.tftest.hcl`**

```hcl
# Runs plans against a mocked AWS: no account, no cost, no waiting.
# Asserts only check values known at plan time — names, counts, settings —
# never ARNs or IDs, which AWS only creates during apply.

mock_provider "aws" {
  # Values AWS would normally create. ARNs must look real, because the
  # provider checks their format even in a mocked plan.
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::127311923021:root" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/test/abc", arn_suffix = "app/test/abc" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/test/abc", arn_suffix = "targetgroup/test/abc" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:111122223333:certificate/abc"
      domain_validation_options = [{
        domain_name           = "orders.dev.example.com"
        resource_record_name  = "_abc.orders.dev.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_xyz.acm-validations.aws."
      }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/test" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:cluster/test" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111122223333:task-definition/test:1" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:111122223333:test" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::test-bucket" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111122223333:log-group:test" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address = "qc-dev-use1-db.abc.us-east-1.rds.amazonaws.com"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-abc"
        secret_status = "active"
        kms_key_id    = ""
      }]
    }
  }
}

variables {
  environment          = "dev"
  region               = "us-east-1"
  vpc_cidr             = "10.10.0.0/16"
  enable_nat           = true
  domain_name          = "orders.dev.example.com"
  zone_id              = "Z0123456789ABC"
  alert_email          = "ops@example.com"
  image_repository_url = "111122223333.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders"
  stable_image_tag     = "v1"
  canary_image_tag     = "v1"
}

run "names_include_environment_and_region" {
  command = plan
  assert {
    condition     = output.name == "qc-dev-use1"
    error_message = "Expected the name prefix qc-dev-use1, got ${output.name}"
  }
}

run "site_is_served_on_its_domain" {
  command = plan
  assert {
    condition     = output.alb_url == "https://orders.dev.example.com"
    error_message = "The site should be served on its own domain name"
  }
}

run "tasks_run_privately_behind_nat" {
  command = plan
  assert {
    condition     = local.assign_public_ip == false
    error_message = "With NAT, tasks must not get public IPs"
  }
}

run "no_nat_means_public_ip_for_tasks" {
  command = plan
  variables {
    enable_nat        = false
    enable_ops_access = false
  }
  assert {
    condition     = local.assign_public_ip == true
    error_message = "Without NAT, tasks need a public IP to pull images"
  }
}

run "session_manager_access_by_default" {
  command = plan
  assert {
    condition     = length(module.ops_access) == 1
    error_message = "The Session Manager instance should exist by default"
  }
}

run "database_and_ops_task_by_default" {
  command = plan
  assert {
    condition     = output.ops_sql_task_family == "qc-dev-use1-ops-sql"
    error_message = "Expected the operations task family qc-dev-use1-ops-sql"
  }
}

run "five_alarms_with_a_database" {
  command = plan
  assert {
    condition     = length(module.monitoring.alarm_names) == 5
    error_message = "Expected SLO, unhealthy targets, service CPU, database storage and database CPU alarms"
  }
}

run "three_alarms_without_a_database" {
  command = plan
  variables {
    enable_database = false
  }
  assert {
    condition     = length(module.monitoring.alarm_names) == 3 && output.ops_sql_task_family == null
    error_message = "Without a database: three alarms and no operations task"
  }
}

run "canary_off_by_default" {
  command = plan
  assert {
    condition     = output.canary_weight == 0
    error_message = "With no canary settings, the canary must get no traffic"
  }
}

run "canary_at_ten_percent" {
  command = plan
  variables {
    canary_image_tag = "a1b2c3d"
    canary_weight    = 10
  }
  assert {
    condition     = output.canary_image_tag == "a1b2c3d" && output.canary_weight == 10
    error_message = "A 10% canary should plan with the canary's version and weight"
  }
}

run "rejects_one_task" {
  command = plan
  variables {
    desired_count = 1
  }
  expect_failures = [var.desired_count]
}

run "rejects_unknown_environment" {
  command = plan
  variables {
    environment = "production"
  }
  expect_failures = [var.environment]
}

run "rejects_latest_tag" {
  command = plan
  variables {
    stable_image_tag = "latest"
  }
  expect_failures = [var.stable_image_tag]
}

run "rejects_canary_over_50" {
  command = plan
  variables {
    canary_weight = 80
  }
  expect_failures = [var.canary_weight]
}
```

Every assertion checks something known at plan time — names, counts, settings. Never an ARN: AWS only creates those during apply, which is exactly the mistake from last week. The account number here is deliberately fake.

```bash
terraform -chdir=infra/modules/platform init -backend=false && terraform -chdir=infra/modules/platform test
```

> ✅ **You should see:** `Success! 14 passed, 0 failed.`

### 12.2 Every check

- [ ] Done

```bash
scripts/tf-checks.sh
```

| Part | What it means |
|---|---|
| `tf-checks.sh` | format, validate, test, tflint and trivy — the same script the pipeline runs |

> ✅ **You should see:** `All Terraform checks passed.` Each accepted security finding sits on its resource as a `#trivy:ignore` comment with its reason.

---

<a id="stage-13"></a>

## Stage 13 — Build dev

*The first complete environment: private network, database, trusted HTTPS, alarms.*

### 13.1 The environment folder

- [ ] Done

> 🔴 **The problem this solves.** Everything so far is reusable parts. An environment is where they become real — and where the only truly environment-specific things live: its values and its state.

Create `infra/envs/dev/us-east-1/`. `versions.tf` is A4's without the tls provider; `backend.tf` is A4's.

**`infra/envs/dev/us-east-1/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

**`infra/envs/dev/us-east-1/main.tf`**

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "quickcart"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# The image repository lives in the shared stack. Read its address from
# that stack's state instead of typing it.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

# The hosted zone already exists — Route 53 made it when the domain was
# registered. Look it up; never manage it from an environment.
data "aws_route53_zone" "main" {
  name         = var.zone_name
  private_zone = false
}

module "platform" {
  source = "../../../modules/platform"

  environment              = var.environment
  region                   = var.region
  vpc_cidr                 = var.vpc_cidr
  enable_nat               = var.enable_nat
  domain_name              = "${var.hostname}.${var.zone_name}"
  zone_id                  = data.aws_route53_zone.main.zone_id
  alert_email              = var.alert_email
  image_repository_url     = data.terraform_remote_state.shared.outputs.repository_url
  stable_image_tag         = var.stable_image_tag
  canary_image_tag         = var.canary_image_tag
  canary_weight            = var.canary_weight
  desired_count            = var.desired_count
  max_count                = var.max_count
  log_retention_days       = var.log_retention_days
  enable_database          = var.enable_database
  db_multi_az              = var.db_multi_az
  db_deletion_protection   = var.db_deletion_protection
  slo_availability_percent = var.slo_availability_percent
}
```

| Piece | Why |
|---|---|
| `data "aws_route53_zone"` | Looks up your existing zone by name. The environment uses it; never owns it |
| `domain_name = "${var.hostname}.${var.zone_name}"` | `orders.dev` + `YOUR_DOMAIN`. The only naming difference between dev and prod |

**`infra/envs/dev/us-east-1/variables.tf`**

```hcl
variable "state_bucket" {
  description = "The S3 bucket holding Terraform state, to read the shared stack"
  type        = string
}

variable "environment" {
  description = "dev or prod"
  type        = string
}

variable "region" {
  description = "AWS region for this environment"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC address range. Unique per environment."
  type        = string
}

variable "enable_nat" {
  description = "Run tasks in private subnets behind a NAT gateway"
  type        = bool
  default     = true
}

variable "zone_name" {
  description = "Your domain's hosted zone, for example YOUR_DOMAIN"
  type        = string
}

variable "hostname" {
  description = "The part before the domain: orders.dev gives orders.dev.YOUR_DOMAIN"
  type        = string
}

variable "alert_email" {
  description = "Who receives this environment's alarms"
  type        = string
}

variable "desired_count" {
  description = "Fewest stable tasks"
  type        = number
  default     = 2
}

variable "max_count" {
  description = "Most stable tasks auto scaling may run"
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "How long to keep app logs"
  type        = number
  default     = 7
}

variable "enable_database" {
  description = "Build the database and connect the app to it"
  type        = bool
  default     = true
}

variable "db_multi_az" {
  description = "Standby database in a second zone"
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database"
  type        = bool
  default     = false
}

variable "slo_availability_percent" {
  description = "Availability target"
  type        = number
  default     = 99.5
}

# Release settings. The pipeline passes these on every run.
variable "stable_image_tag" {
  description = "Version serving normal traffic"
  type        = string
}

variable "canary_image_tag" {
  description = "Version the canary runs"
  type        = string
}

variable "canary_weight" {
  description = "Percentage of traffic on the canary"
  type        = number
  default     = 0
}
```

**`infra/envs/dev/us-east-1/outputs.tf`**

```hcl
output "alb_url" {
  description = "The site's address"
  value       = module.platform.alb_url
}

output "name" {
  description = "Name prefix for this environment"
  value       = module.platform.name
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = module.platform.cluster_name
}

output "stable_image_tag" {
  description = "Version serving normal traffic"
  value       = module.platform.stable_image_tag
}

output "canary_image_tag" {
  description = "Version the canary runs"
  value       = module.platform.canary_image_tag
}

output "canary_weight" {
  description = "Share of traffic on the canary"
  value       = module.platform.canary_weight
}

output "target_group_arns" {
  description = "Target groups, keyed stable and canary"
  value       = module.platform.target_group_arns
}

output "log_groups" {
  description = "Log groups, keyed stable and canary"
  value       = module.platform.log_groups
}

output "task_subnet_ids" {
  description = "Subnets tasks run in"
  value       = module.platform.task_subnet_ids
}

output "app_security_group_id" {
  description = "Security group for app and operations tasks"
  value       = module.platform.app_security_group_id
}

output "assign_public_ip" {
  description = "Whether tasks need a public IP"
  value       = module.platform.assign_public_ip
}

output "ops_sql_task_family" {
  description = "Task definition family for the safe SQL job"
  value       = module.platform.ops_sql_task_family
}

output "ops_sql_log_group" {
  description = "Where the safe SQL job's output goes"
  value       = module.platform.ops_sql_log_group
}

output "ops_instance_id" {
  description = "Session Manager target for reaching the database"
  value       = module.platform.ops_instance_id
}

output "db_address" {
  description = "Database host, reachable only inside the VPC"
  value       = module.platform.db_address
}

output "alerts_topic_arn" {
  description = "Where alarms go"
  value       = module.platform.alerts_topic_arn
}

output "alb_logs_bucket" {
  description = "Load balancer access logs"
  value       = module.platform.alb_logs_bucket
}
```

**`infra/envs/dev/us-east-1/terraform.tfvars`**

```hcl
state_bucket = "qc-tfstate-YOUR_ACCOUNT_ID"

environment = "dev"
region      = "us-east-1"
vpc_cidr    = "10.10.0.0/16"
enable_nat  = true

zone_name   = "YOUR_DOMAIN"
hostname    = "orders.dev"
alert_email = "YOUR_EMAIL"

desired_count      = 2
max_count          = 4
log_retention_days = 7

enable_database        = true
db_multi_az            = false
db_deletion_protection = false

slo_availability_percent = 99.0

stable_image_tag = "v2"
canary_image_tag = "v2"
canary_weight    = 0
```

### 13.2 Apply it

- [ ] Done

```bash
terraform -chdir=infra/envs/dev/us-east-1 init && terraform -chdir=infra/envs/dev/us-east-1 plan
```

> ✅ **You should see:** About 66 resources to add. Read the plan's groups: the network (with a NAT gateway and the S3 endpoint), the certificate and its DNS record, the load balancer and its log bucket, the database, the ops instance, two services, auto scaling, and five alarms.

```bash
terraform -chdir=infra/envs/dev/us-east-1 apply
```

> ✅ **You should see:** Type `yes`. **15 to 20 minutes** — the database alone takes 5 to 10, and the certificate waits for DNS. Then `Apply complete!` and the outputs.

> ✅ **You should see:** An email from AWS Notifications asking you to confirm the alarm subscription. **Click the link** — until you do, alarms go nowhere.

### 13.3 Check it, like a customer would

- [ ] Done

```bash
curl https://orders.dev.YOUR_DOMAIN/health
```

| Part | What it means |
|---|---|
| `no -k` | the certificate is trusted now. If this fails with a certificate error, something is wrong |

> ✅ **You should see:** `{"status":"ok","version":"v2"}`

```bash
curl https://orders.dev.YOUR_DOMAIN/ready
```

> ✅ **You should see:** `{"database":"ok","version":"v2"}` — this task reached MySQL.

```bash
curl https://orders.dev.YOUR_DOMAIN/orders
```

> ✅ **You should see:** Three orders — read from the database. The first request created and seeded the table.

Open `https://orders.dev.YOUR_DOMAIN/orders` in a browser: a padlock, and no warning.

```bash
terraform -chdir=infra/envs/dev/us-east-1 plan -detailed-exitcode; echo "exit code: $?"
```

> ✅ **You should see:** `No changes.` and `exit code: 0` — the clean second plan from A4.

---

<a id="stage-14"></a>

## Stage 14 — Reach the database with Session Manager

*Into a private subnet with no SSH, no key and no open port — and every session on record.*

### 14.1 A shell, with no SSH

- [ ] Done

> 🔴 **The problem this solves.** The database is unreachable on purpose. When you genuinely need to look inside it, the way in must not weaken that — no public server, no port open to the internet, no key that could leak.

```bash
aws ssm start-session --target $(terraform -chdir=infra/envs/dev/us-east-1 output -raw ops_instance_id)
```

| Part | What it means |
|---|---|
| `aws ssm start-session` | open a Session Manager session |
| `--target` | which instance |
| `$(terraform ... output -raw ops_instance_id)` | run the command inside first, and use its answer — the ops instance's ID |

> ✅ **You should see:** `Starting session with SessionId: ...` then a `sh-5.2$` prompt. You're on a machine with no public IP and no inbound port.

```bash
whoami && exit
```

> ✅ **You should see:** `ssm-user`, then the session closes.

### 14.2 Forward the database to your Mac

- [ ] Done

Session Manager can also carry a connection *through* the instance to something only it can reach. Get the database password first — reading it needs IAM permission, and is itself recorded in CloudTrail:

```bash
aws secretsmanager get-secret-value --secret-id $(aws rds describe-db-instances --db-instance-identifier qc-dev-use1-db --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text) --query SecretString --output text
```

| Part | What it means |
|---|---|
| `describe-db-instances ... SecretArn` | find which secret RDS keeps the password in |
| `get-secret-value` | read it |

> ✅ **You should see:** `{"username":"qcadmin","password":"..."}`. Keep this window's output to yourself.

In a **second terminal**, open the tunnel. It stays running:

```bash
aws ssm start-session --target $(terraform -chdir=infra/envs/dev/us-east-1 output -raw ops_instance_id) --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=$(terraform -chdir=infra/envs/dev/us-east-1 output -raw db_address),portNumber=3306,localPortNumber=13306
```

| Part | What it means |
|---|---|
| `AWS-StartPortForwardingSessionToRemoteHost` | the Session Manager recipe for forwarding a port to another host |
| `host=...` | the database's address — reachable from the ops instance, not from you |
| `portNumber=3306` | MySQL's port on the database |
| `localPortNumber=13306` | the port on your Mac that leads there |

> ✅ **You should see:** `Port 13306 opened for sessionId ...` and `Waiting for connections...`

In a **third terminal**, connect as if the database were on your Mac:

```bash
$(brew --prefix mysql-client)/bin/mysql -h 127.0.0.1 -P 13306 -u qcadmin -p quickcart
```

| Part | What it means |
|---|---|
| `$(brew --prefix mysql-client)/bin/mysql` | Homebrew keeps this mysql out of your normal path; this finds it |
| `-h 127.0.0.1 -P 13306` | your end of the tunnel |
| `-p` | ask for the password — paste it from the secret |

```
SELECT * FROM orders;
```

> ✅ **You should see:** The three orders. Type `exit`, then press Ctrl+C in the tunnel window to close it.

> 💡 **Looking, not changing.** This is for investigating. **Changes** to data go through the safe-SQL job in stage 22 — with a dry run, guard rails and an approval. Two different doors for two different risks.

### 14.3 See it in the audit trail

- [ ] Done

```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=StartSession --max-results 3 --query 'Events[].[EventTime,Username]' --output table
```

| Part | What it means |
|---|---|
| `lookup-events` | search the last 90 days of the audit trail |
| `EventName ... StartSession` | only session starts |

> ✅ **You should see:** Your sessions, with times and your user name. It can take a few minutes to appear. This is what "every session on record" means.

---

<a id="stage-15"></a>

## Stage 15 — Build prod

*The same code with production's values — and the proof that nothing else differs.*

### 15.1 Copy, change two files, prove it

- [ ] Done

> 🔴 **The problem this solves.** "Staging worked but production didn't" almost always means the two weren't really the same. The fix from A4: identical code, different values, and a `diff` that proves it.

```bash
mkdir -p infra/envs/prod/us-east-1 && cp infra/envs/dev/us-east-1/{versions,main,variables,outputs}.tf infra/envs/prod/us-east-1/
```

**`infra/envs/prod/us-east-1/backend.tf`**

```hcl
terraform {
  backend "s3" {
    bucket       = "qc-tfstate-YOUR_ACCOUNT_ID"
    key          = "envs/prod/us-east-1/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

**`infra/envs/prod/us-east-1/terraform.tfvars`**

```hcl
state_bucket = "qc-tfstate-YOUR_ACCOUNT_ID"

environment = "prod"
region      = "us-east-1"
vpc_cidr    = "10.30.0.0/16"
enable_nat  = true

zone_name   = "YOUR_DOMAIN"
hostname    = "orders"
alert_email = "YOUR_EMAIL"

desired_count      = 2
max_count          = 6
log_retention_days = 30

enable_database = true
# Multi-AZ doubles the database cost. Turn it on for real production.
db_multi_az            = false
db_deletion_protection = true

slo_availability_percent = 99.5

stable_image_tag = "v2"
canary_image_tag = "v2"
canary_weight    = 0
```

| Value | dev | prod | Why |
|---|---|---|---|
| `hostname` | orders.dev | orders | prod is the customer-facing name |
| `max_count` | 4 | 6 | More room to scale where real traffic is |
| `log_retention_days` | 7 | 30 | Evidence kept longer |
| `db_deletion_protection` | false | true | Nobody deletes production data by accident — stage 25 shows the deliberate way |
| `slo_availability_percent` | 99.0 | 99.5 | A stricter promise to customers than to developers |

```bash
diff -rq --exclude=.terraform --exclude=.terraform.lock.hcl infra/envs/dev/us-east-1 infra/envs/prod/us-east-1
```

> ✅ **You should see:** Exactly two files differ: `backend.tf` and `terraform.tfvars`. Screenshot it.

```bash
terraform -chdir=infra/envs/prod/us-east-1 init && terraform -chdir=infra/envs/prod/us-east-1 apply && curl https://orders.YOUR_DOMAIN/ready
```

> ✅ **You should see:** After 15 to 20 minutes, `{"database":"ok","version":"v2"}`. Confirm prod's alarm subscription email too.

```bash
git add . && git commit -m "Platform: dev and prod" && git push
```

---

<a id="stage-16"></a>

## Stage 16 — The Jenkins controller

*Built with Terraform, reached only from your IP, and holding no AWS keys.*

### 16.1 Why build it with Terraform

- [ ] Done

> 🔴 **The problem this solves.** From now on nobody applies to dev or prod from a laptop — Jenkins does. That makes Jenkins itself something you must be able to rebuild in minutes.

Create `infra/jenkins/`. Its `backend.tf` is the shared stack's with the key `jenkins/terraform.tfstate`.

**`infra/jenkins/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}
```

**`infra/jenkins/variables.tf`**

```hcl
variable "my_ip_cidr" {
  description = "Your own public IP with /32 on the end, so only you can open Jenkins. Find it at https://checkip.amazonaws.com"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && endswith(var.my_ip_cidr, "/32")
    error_message = "my_ip_cidr must be a single address ending in /32, for example YOUR_PUBLIC_IP/32."
  }
}

variable "alert_email" {
  description = "Where pipeline notifications are sent. You must confirm the subscription email."
  type        = string
}

variable "instance_type" {
  description = "Jenkins controller size. t3.medium has room for Jenkins, Docker builds and Terraform at once."
  type        = string
  default     = "t3.medium"
}
```

**`infra/jenkins/main.tf`**

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "quickcart"
      ManagedBy = "terraform"
      Stack     = "jenkins"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# GitHub publishes the addresses its webhooks come from. Reading them here
# means the security group stays correct without anyone copying a list.
data "http" "github_meta" {
  url = "https://api.github.com/meta"

  request_headers = {
    Accept = "application/json"
  }
}

locals {
  github_hook_cidrs = [
    for c in jsondecode(data.http.github_meta.response_body).hooks : c if !strcontains(c, ":")
  ]
}

# ---------- network access ----------

resource "aws_security_group" "jenkins" {
  name        = "qc-jenkins"
  description = "Jenkins: the web UI for you, webhooks for GitHub"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Jenkins UI from your IP only"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Webhooks from GitHub"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.github_hook_cidrs
  }

  # Accepted: Jenkins must reach GitHub, package repositories and AWS APIs.
  #trivy:ignore:AWS-0104
  egress {
    description = "all outbound: GitHub, AWS APIs, package downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- identity: a role, not stored keys ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "qc-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Lab shortcut: Terraform creates VPCs, roles and load balancers, so the
# pipeline needs broad rights. In production, split this into a read-only
# role for plans and a separate, approved role per environment for applies.
resource "aws_iam_role_policy_attachment" "jenkins" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AdministratorAccess",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.jenkins.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "qc-jenkins"
  role = aws_iam_role.jenkins.name
}

# ---------- backups of JENKINS_HOME ----------

# Encrypted with S3's own keys (the default). A customer-managed KMS key adds
# control over who can decrypt, at extra cost. Accepted for this lab.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "backup" {
  bucket = "qc-jenkins-backup-${data.aws_caller_identity.current.account_id}"

  # Lab: let destroy delete the backups with the bucket. In production, false.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "keep-30-days"
    status = "Enabled"

    filter {
      prefix = "jenkins-home/"
    }

    expiration {
      days = 30
    }
  }
}

# ---------- notifications ----------

# Encrypted with AWS's own SNS key. A customer-managed key adds control over
# who can decrypt, at extra cost. Accepted for this lab.
#trivy:ignore:AWS-0136
resource "aws_sns_topic" "pipeline" {
  name              = "quickcart-pipeline"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------- the controller ----------

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user-data.sh", {
    backup_bucket = aws_s3_bucket.backup.bucket
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "qc-jenkins"
  }
}
```

| Piece | Why |
|---|---|
| `data "http" "github_meta"` | GitHub publishes the addresses its webhooks come from. Only those, and your IP, may reach port 8080 |
| An instance role | Jenkins gets short-lived AWS credentials automatically. There is no access key to store, leak or rotate |
| `AdministratorAccess` | Lab shortcut, with the production alternative written next to it: separate plan and apply roles |
| `AmazonSSMManagedInstanceCore` | You open a shell with Session Manager, exactly like the ops instance. No SSH |
| Backup bucket and nightly cron | `JENKINS_HOME` holds every job and credential |
| SNS topic | Pipeline results by email |

**`infra/jenkins/outputs.tf`**

```hcl
output "jenkins_url" {
  description = "Open this in your browser. Only your IP can reach it."
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "webhook_url" {
  description = "Paste this into the GitHub repository's webhook settings"
  value       = "http://${aws_instance.jenkins.public_ip}:8080/github-webhook/"
}

output "instance_id" {
  description = "For connecting with Session Manager"
  value       = aws_instance.jenkins.id
}

output "backup_bucket" {
  description = "Where JENKINS_HOME backups go"
  value       = aws_s3_bucket.backup.bucket
}

output "sns_topic_arn" {
  description = "Pipeline notifications"
  value       = aws_sns_topic.pipeline.arn
}
```

**`infra/jenkins/user-data.sh`**

```bash
#!/bin/bash
# Runs once, as root, on first boot. Output goes to /var/log/cloud-init-output.log
set -euxo pipefail

# ---- base tools ----
dnf install -y java-21-amazon-corretto-headless git docker jq unzip cronie python3-pip dnf-plugins-core

# ---- Jenkins, from the official repository ----
curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# ---- Terraform, from HashiCorp's repository ----
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- linters used by the pipeline ----
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# ---- let Jenkins build images ----
systemctl enable --now docker
usermod -aG docker jenkins

# ---- start Jenkins (after joining the docker group, so it takes effect) ----
systemctl enable --now jenkins

# ---- nightly backup of JENKINS_HOME to S3 ----
cat > /usr/local/bin/backup-jenkins.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive=/tmp/jenkins-home-$stamp.tgz
# Workspaces and caches can be rebuilt, so they are left out.
tar --exclude='workspace' --exclude='caches' --exclude='.cache' -czf "$archive" -C /var/lib jenkins
aws s3 cp "$archive" "s3://${backup_bucket}/jenkins-home/$stamp.tgz"
rm -f "$archive"
echo "Backed up JENKINS_HOME to s3://${backup_bucket}/jenkins-home/$stamp.tgz"
SCRIPT
chmod 755 /usr/local/bin/backup-jenkins.sh
echo "30 2 * * * root /usr/local/bin/backup-jenkins.sh >> /var/log/jenkins-backup.log 2>&1" > /etc/cron.d/jenkins-backup
systemctl enable --now crond

echo "Jenkins setup finished"
```

### 16.2 Apply it

- [ ] Done

Create `infra/jenkins/terraform.tfvars` — it's in `.gitignore`:

```
my_ip_cidr  = "YOUR_PUBLIC_IP/32"
alert_email = "YOUR_EMAIL"
```

```bash
terraform -chdir=infra/jenkins init && terraform -chdir=infra/jenkins apply
```

> ✅ **You should see:** Outputs including `jenkins_url`. Confirm the SNS subscription email. Give it **5 minutes** — the first boot installs Jenkins, Docker, Terraform, tflint and trivy.

---

<a id="stage-17"></a>

## Stage 17 — Set up Jenkins

*Unlock it, give it a label, a GitHub token and the shared library, and lock down who can do what.*

### 17.1 Unlock and install plugins

- [ ] Done

> 🧭 **EC2** → Instances → `qc-jenkins` → **Connect** → **Session Manager** → Connect

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open the `jenkins_url` output in your browser, paste the password, choose **Install suggested plugins**, and create your own admin user. Keep the Jenkins URL it suggests.

### 17.2 Give the built-in node a label

- [ ] Done

> 🧭 **Manage Jenkins** → Nodes → **Built-In Node** → Configure

| Field | Enter |
|---|---|
| Number of executors | `2` |
| Labels | `linux` |

> 💡 **A lab shortcut, contained.** Builds run on the controller here, to save a second machine. The pipeline asks for the label `linux`, never "the controller" — moving to real agents later is a settings change. And pull-request builds never receive deploy credentials.

### 17.3 The GitHub token

- [ ] Done

On github.com: your photo → **Settings** → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.

| Field | Enter |
|---|---|
| Repository access | Only `quickcart-final` and `quickcart-jenkins-lib` |
| Contents | Read-only |
| Pull requests | Read and write |
| Issues | Read and write |
| Commit statuses | Read and write |

> 🧭 **Manage Jenkins** → Credentials → System → Global credentials → **Add Credentials**

| Field | Enter |
|---|---|
| Kind | Username with password |
| Username | `YOUR_GITHUB_USER` |
| Password | the token |
| ID | `github-token` |

### 17.4 The shared library

- [ ] Done

Push this one file to the `quickcart-jenkins-lib` repository, on `main`:

**`quickcart-jenkins-lib/vars/smokeTest.groovy`**

```groovy
// Shared pipeline step: smokeTest(url: 'https://...', version: 'a1b2c3d')
//
// Passes when /health answers with the expected version. Retries, because a
// load balancer can take a few seconds to shift traffic to new tasks.

def call(Map args) {
  String url = args.url
  String version = args.version
  int attempts = args.get('attempts', 10)

  if (!url || !version) {
    error('smokeTest needs both url and version')
  }

  retry(attempts) {
    sleep(time: 3, unit: 'SECONDS')
    sh "curl -skf '${url}/health' | grep -q '\"version\":\"${version}\"'"
  }
  echo "Smoke test passed: ${url} is serving ${version}"
}
```

> 🧭 **Manage Jenkins** → System → **Global Trusted Pipeline Libraries** → Add

| Field | Enter |
|---|---|
| Name | `quickcart-lib` |
| Default version | `main` |
| Retrieval method | Modern SCM → GitHub |
| Credentials | github-token |
| Repository HTTPS URL | `https://github.com/YOUR_GITHUB_USER/quickcart-jenkins-lib` |

### 17.5 Folders and who may do what

- [ ] Done

> 🔴 **The problem this solves.** The safe-SQL job can change production data. "Safe enough to hand to a colleague" includes choosing which colleagues.

> 🧭 **Manage Jenkins** → Security → Authorization → **Project-based Matrix Authorization Strategy**. Give your user **Administer**, and Authenticated Users **Overall / Read**.

Then **New Item** → Folder, twice: `quickcart` and `operations`. On `operations` → Configure → **Enable project-based security**, and grant Build only to the people who handle incidents.

---

<a id="stage-18"></a>

## Stage 18 — The pipeline in the repository

*Scripts, the Jenkinsfile, three jobs — and the connections from GitHub to Jenkins.*

### 18.1 The scripts

- [ ] Done

> 🔴 **The problem this solves.** Logic inside a Jenkinsfile can only be tested by running Jenkins. Logic in scripts can be run and tested anywhere — each of these was tested on its own before being used.

**`scripts/release.sh`**

```bash
#!/usr/bin/env bash
# Apply one environment with explicit release settings.
#
#   scripts/release.sh ENV_DIR [--stable TAG] [--canary TAG] [--weight N] [--plan-file FILE]
#
# Any setting not given keeps its current live value, read from Terraform's
# outputs. That way a canary change never accidentally resets the stable version.
# With --plan-file, it only writes a plan for someone to approve.
set -euo pipefail

dir=${1:?usage: release.sh ENV_DIR [options]}
shift

stable="" canary="" weight="" planfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stable)       stable=$2; shift 2 ;;
    --canary)       canary=$2; shift 2 ;;
    --weight)       weight=$2; shift 2 ;;
    --plan-file)    planfile=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

terraform -chdir="$dir" init -input=false >/dev/null

current() { terraform -chdir="$dir" output -raw "$1" 2>/dev/null || true; }
: "${stable:=$(current stable_image_tag)}"
: "${canary:=$(current canary_image_tag)}"
: "${weight:=$(current canary_weight)}"

# Only pass values we know. On the very first apply there are no outputs yet,
# so terraform.tfvars supplies them instead.
vars=()
[ -n "$stable" ] && vars+=(-var "stable_image_tag=$stable")
[ -n "$canary" ] && vars+=(-var "canary_image_tag=$canary")
[ -n "$weight" ] && vars+=(-var "canary_weight=$weight")

echo "Release settings for $dir: stable=${stable:-tfvars} canary=${canary:-tfvars} weight=${weight:-tfvars}"

if [ -n "$planfile" ]; then
  terraform -chdir="$dir" plan -input=false -out="$planfile" "${vars[@]}"
else
  terraform -chdir="$dir" apply -input=false -auto-approve "${vars[@]}"
fi
```

Every deploy, canary, promotion and rollback goes through this one script. Anything not given keeps its live value, so starting a canary can never reset the stable version. Tested with a stand-in for Terraform: a canary change kept stable at `v7`.

**`scripts/plan-comment.sh`**

````bash
#!/usr/bin/env bash
# Plan one environment and post the plan onto the pull request as a comment.
#
#   scripts/plan-comment.sh ENV_DIR
#
# Needs: GITHUB_TOKEN, GH_REPO (owner/name), CHANGE_ID (the pull request number,
# which Jenkins sets on pull request builds).
set -euo pipefail
dir=${1:?usage: plan-comment.sh ENV_DIR}
: "${GITHUB_TOKEN:?}" "${GH_REPO:?}" "${CHANGE_ID:?}"

"$(dirname "$0")/release.sh" "$dir" --plan-file pr.tfplan
terraform -chdir="$dir" show -no-color pr.tfplan > plan.txt
summary=$(grep -E '^(Plan:|No changes)' plan.txt | tail -1 || true)

# GitHub comments are limited to 65,536 characters.
if [ "$(wc -c < plan.txt)" -gt 60000 ]; then
  head -c 60000 plan.txt > plan-short.txt
  printf '\n\n... plan cut short. The full plan is in the Jenkins build artifacts.\n' >> plan-short.txt
else
  cp plan.txt plan-short.txt
fi

jq -Rs --arg dir "$dir" --arg summary "$summary" \
  '{body: ("### Terraform plan for `" + $dir + "`\n\n**" + $summary + "**\n\n<details><summary>Full plan</summary>\n\n```\n" + . + "\n```\n</details>")}' \
  plan-short.txt > comment.json

curl -fsS -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GH_REPO/issues/$CHANGE_ID/comments" \
  --data @comment.json > /dev/null

echo "Posted the plan for $dir to pull request #$CHANGE_ID: $summary"
````

**`scripts/canary-check.sh`**

```bash
#!/usr/bin/env bash
# Judge a running canary against criteria written down BEFORE the release.
# See docs/canary-criteria.md.
#
#   scripts/canary-check.sh URL CANARY_VERSION [MINUTES] [MAX_ERROR_PERCENT]
#
# Sends steady traffic, and uses the version each response reports to tell
# canary responses apart from stable ones. Exits non-zero to abort.
set -euo pipefail
url=${1:?usage: canary-check.sh URL CANARY_VERSION [MINUTES] [MAX_ERROR_PERCENT]}
canary=${2:?canary version required}
minutes=${3:-5}
max_pct=${4:-1}

ok=0 bad=0 unknown_fail=0
end=$((SECONDS + minutes * 60))
echo "Watching $url for $minutes minutes. Abort if canary errors exceed $max_pct%."

while [ "$SECONDS" -lt "$end" ]; do
  resp=$(curl -sk -m 3 -w '\n%{http_code}' "$url/orders" || printf '\n000')
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  version=$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null || true)

  if [ "$version" = "$canary" ]; then
    if [ "$code" = "200" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  elif [ "$code" != "200" ] && [ -z "$version" ]; then
    # A failure with no version: the load balancer itself answered, e.g. 502.
    unknown_fail=$((unknown_fail + 1))
  fi
  sleep 0.2
done

total=$((ok + bad))
echo "Canary responses: $total   ok: $ok   failed: $bad   unattributed failures: $unknown_fail"

if [ "$total" -lt 20 ]; then
  echo "ABORT: only $total canary responses — too few to judge. Is the canary running and weighted?"
  exit 1
fi
if [ "$unknown_fail" -gt 5 ]; then
  echo "ABORT: $unknown_fail failures came from the load balancer itself."
  exit 1
fi
if awk -v b="$bad" -v t="$total" -v m="$max_pct" 'BEGIN { exit !((b * 100 / t) > m) }'; then
  echo "ABORT: canary error rate $(awk -v b="$bad" -v t="$total" 'BEGIN { printf "%.1f", b * 100 / t }')% is above $max_pct%."
  exit 1
fi
echo "PASS: canary error rate is within $max_pct%."
```

Tested against the real app: a healthy version passed with 0 failures in 280 canary responses; a version failing 30% of the time aborted at 29%.

**`scripts/safe-sql.sh`**

```bash
#!/usr/bin/env bash
# Run ONE SQL statement against an environment's database, inside a transaction,
# from a task inside the VPC. Dry-run rolls back; commit keeps the change.
#
# Reads from the environment (Jenkins parameters become environment variables):
#   ENV_DIR    infra/envs/dev/us-east-1
#   SQL        the statement
#   MODE       dry-run | commit
#   TICKET     why — required, recorded on the task
#   ALLOW_DDL  true to allow CREATE / ALTER
set -euo pipefail
: "${ENV_DIR:?}" "${SQL:?SQL is empty}" "${MODE:?}" "${TICKET:=}" "${ALLOW_DDL:=false}"

die() { echo "REFUSED: $*" >&2; exit 2; }

# ---- the guard rails ----
[ -n "$TICKET" ] || die "TICKET is required. Every change to data needs a reason on record."
case "$MODE" in dry-run|commit) ;; *) die "MODE must be dry-run or commit." ;; esac

statement=$(printf '%s' "$SQL" | sed -e 's/[[:space:]]*;[[:space:]]*$//')
upper=$(printf '%s' "$statement" | tr '[:lower:]' '[:upper:]')

case "$statement" in *";"*) die "One statement per run. Remove the semicolons inside it." ;; esac

if printf '%s' "$upper" | grep -Eq '\b(DROP|TRUNCATE)\b'; then
  die "DROP and TRUNCATE are never run from this job. They need a reviewed migration."
fi

if printf '%s' "$upper" | grep -Eq '^[[:space:]]*(CREATE|ALTER|RENAME|GRANT|REVOKE)\b'; then
  [ "$ALLOW_DDL" = "true" ] || die "This changes the schema. Tick ALLOW_DDL if that is intended."
  [ "$MODE" = "commit" ] || die "Schema changes cannot be dry-run: MySQL commits them immediately, even inside a transaction. Use commit mode."
fi

if printf '%s' "$upper" | grep -Eq '^[[:space:]]*(UPDATE|DELETE)\b' && ! printf '%s' "$upper" | grep -Eq '\bWHERE\b'; then
  die "UPDATE and DELETE need a WHERE clause. Without one they change every row."
fi

# ---- where to run it: read from Terraform, never typed ----
terraform -chdir="$ENV_DIR" init -input=false >/dev/null
out() { terraform -chdir="$ENV_DIR" output -json "$1"; }
cluster=$(out cluster_name | jq -r .)
family=$(out ops_sql_task_family | jq -r .)
log_group=$(out ops_sql_log_group | jq -r .)
subnets=$(out task_subnet_ids | jq -r 'join(",")')
sg=$(out app_security_group_id | jq -r .)
public_ip=$(out assign_public_ip | jq -r 'if . then "ENABLED" else "DISABLED" end')
[ "$family" != "null" ] || die "$ENV_DIR has no database. Set enable_database = true first."

sql_b64=$(printf '%s' "$statement" | base64 -w0)
started_by=$(printf 'sql-%s' "$TICKET" | tr -cd 'A-Za-z0-9_-' | cut -c1-36)

overrides=$(jq -cn --arg sql "$sql_b64" --arg mode "$MODE" \
  '{containerOverrides: [{name: "sql", environment: [{name: "SQL_B64", value: $sql}, {name: "MODE", value: $mode}]}]}')

echo "Running in $cluster, mode $MODE, ticket $TICKET:"
echo "  $statement"

task_arn=$(aws ecs run-task --cluster "$cluster" --task-definition "$family" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=$public_ip}" \
  --overrides "$overrides" --started-by "$started_by" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn"
exit_code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)

# Logs can arrive a few seconds after the task stops.
sleep 5
aws logs get-log-events --log-group-name "$log_group" \
  --log-stream-name "ops/sql/${task_arn##*/}" --start-from-head \
  --output json | jq -r '.events[].message'

if [ "$exit_code" != "0" ]; then
  echo "The statement failed (exit code $exit_code). Nothing was committed."
  exit 1
fi
```

**`scripts/extract-logs.sh`**

```bash
#!/usr/bin/env bash
# Pull an app's logs for a time window into a file.
#
# Reads from the environment:
#   LOG_GROUP   e.g. /ecs/qc-dev-use1-orders
#   START, END  UTC, e.g. "2026-09-29 14:00"
#   FILTER      optional CloudWatch filter pattern, e.g. ERROR
set -euo pipefail
: "${LOG_GROUP:?}" "${START:?}" "${END:?}" "${FILTER:=}"

start_s=$(date -u -d "$START" +%s) || { echo "Could not read START: $START" >&2; exit 2; }
end_s=$(date -u -d "$END" +%s)     || { echo "Could not read END: $END" >&2; exit 2; }
[ "$end_s" -gt "$start_s" ] || { echo "END must be after START." >&2; exit 2; }
[ $((end_s - start_s)) -le 86400 ] || { echo "Keep the window to 24 hours or less." >&2; exit 2; }

args=(--log-group-name "$LOG_GROUP" --start-time "${start_s}000" --end-time "${end_s}000")
[ -n "$FILTER" ] && args+=(--filter-pattern "$FILTER")

file="logs-$(printf '%s' "$LOG_GROUP" | tr '/' '_')-$(date -u -d "$START" +%Y%m%dT%H%M).txt"

aws logs filter-log-events "${args[@]}" --output json \
  | jq -r '.events[] | "\((.timestamp / 1000 | floor | strftime("%Y-%m-%dT%H:%M:%SZ")))  \(.logStreamName)  \(.message)"' \
  > "$file"

echo "Wrote $(wc -l < "$file") lines from $LOG_GROUP between $START and $END UTC${FILTER:+ matching $FILTER} to $file"
```

**`docs/canary-criteria.md`**

```markdown
# Canary criteria — order service

Written **before** any canary release. The pipeline enforces these exactly, in
`scripts/canary-check.sh`. Changing them means changing this file in a pull
request, so the change is reviewed like any other.

## The canary

| Setting | Value | Why |
|---|---|---|
| Traffic to the new version | 10% | Small enough that a bad version affects few customers; large enough to measure |
| Canary tasks | 1 | Always running; it only gets traffic while the weight is above 0 |
| Watch window | 5 minutes | Long enough for a few hundred canary requests |
| Environment | production | 10% of real customers, for 5 minutes, before anyone else gets it |

## Abort — any one of these stops the release and returns all traffic to the stable version

1. **Canary error rate above 1%** — more than 1 in 100 canary responses is not a 200.
2. **More than 5 failures the load balancer answered itself** (502, 503, 504 with no app response) — the new tasks aren't serving at all.
3. **Fewer than 20 canary responses in the window** — too little evidence to judge. Not judging is treated as failing.

## Promote — only if none of the above happened

All traffic moves to the new version, the canary is switched off, and the
previous version is recorded so the rollback job can return to it in one click.

## What a person checks after promotion

- The smoke test passed on the promoted version.
- No new alarm fired in the 15 minutes after promotion.
- If either fails: run the **rollback** job with the default `previous`.
```

### 18.2 The Jenkinsfile and the jobs

- [ ] Done

**`Jenkinsfile`**

```groovy
// QuickCart delivery pipeline.
//
// Pull request: test, build, check the Terraform, post the dev plan on the PR.
// Merge to main: push the image, deploy dev, smoke test, then — after approval —
// a 10% canary in production, judged against docs/canary-criteria.md, then promote.

@Library('quickcart-lib') _

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 90, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    AWS_REGION       = 'us-east-1'
    GH_REPO          = 'YOUR_GITHUB_USER/quickcart-final'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
    DEV_DIR          = 'infra/envs/dev/us-east-1'
    PROD_DIR         = 'infra/envs/prod/us-east-1'
  }

  stages {
    stage('Prepare') {
      steps {
        script {
          env.ACCOUNT_ID = sh(returnStdout: true, script: 'aws sts get-caller-identity --query Account --output text').trim()
          env.REGISTRY   = "${env.ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.IMAGE      = "${env.REGISTRY}/quickcart/orders"
          env.IMAGE_TAG  = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          env.TOPIC_ARN  = "arn:aws:sns:${env.AWS_REGION}:${env.ACCOUNT_ID}:quickcart-pipeline"
        }
        echo "Commit ${env.IMAGE_TAG} on ${env.BRANCH_NAME}"
      }
    }

    stage('Test the app') {
      steps {
        dir('app') {
          sh '''
            python3 -m venv .venv
            . .venv/bin/activate
            pip install -q -r requirements-dev.txt
            flake8 --max-line-length 100 app.py test_app.py
            mkdir -p ../reports
            pytest -q --junitxml=../reports/pytest.xml
          '''
        }
      }
      post {
        always { junit 'reports/pytest.xml' }
      }
    }

    stage('Build the image') {
      steps {
        sh 'docker build --build-arg APP_VERSION="$IMAGE_TAG" -t "$IMAGE:$IMAGE_TAG" app'
      }
    }

    stage('Check the Terraform') {
      steps {
        sh 'scripts/tf-checks.sh'
      }
    }

    stage('Plan dev, post it on the pull request') {
      when { changeRequest() }
      steps {
        withCredentials([usernamePassword(credentialsId: 'github-token',
                                          usernameVariable: 'GH_USER',
                                          passwordVariable: 'GITHUB_TOKEN')]) {
          sh 'scripts/plan-comment.sh "$DEV_DIR"'
        }
      }
      post {
        always { archiveArtifacts artifacts: 'plan.txt', allowEmptyArchive: true }
      }
    }

    stage('Push the image') {
      when { branch 'main' }
      steps {
        // A push can fail on a network blip. Retrying is safe because the
        // step checks first: an immutable tag can only ever be pushed once.
        retry(3) {
          sh '''
            aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
            if aws ecr describe-images --repository-name quickcart/orders --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
              echo "$IMAGE:$IMAGE_TAG is already in ECR. Nothing to push."
            else
              docker push "$IMAGE:$IMAGE_TAG"
            fi
          '''
        }
      }
    }

    stage('Deploy to dev') {
      when { branch 'main' }
      steps {
        sh '''
          terraform -chdir="$DEV_DIR" init -input=false >/dev/null
          previous=$(terraform -chdir="$DEV_DIR" output -raw stable_image_tag)
          scripts/release.sh "$DEV_DIR" --stable "$IMAGE_TAG" --canary "$IMAGE_TAG" --weight 0
          aws ssm put-parameter --name /quickcart/dev/previous_stable --value "$previous" --type String --overwrite >/dev/null
        '''
      }
    }

    stage('Smoke test dev') {
      when { branch 'main' }
      steps {
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$DEV_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.IMAGE_TAG)
        }
      }
    }

    stage('Approve a production canary') {
      when { branch 'main' }
      steps {
        sh '''
          scripts/release.sh "$PROD_DIR" --canary "$IMAGE_TAG" --weight 10 --plan-file canary.tfplan
          terraform -chdir="$PROD_DIR" show -no-color canary.tfplan > prod-canary-plan.txt
        '''
        archiveArtifacts artifacts: 'prod-canary-plan.txt'
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Start a 10% canary of ${env.IMAGE_TAG} in production? Read prod-canary-plan.txt in this build's artifacts first.",
                ok: 'Start the canary'
        }
      }
    }

    stage('Canary in production') {
      when { branch 'main' }
      steps {
        // Apply exactly the plan that was approved — not a fresh one.
        sh 'terraform -chdir="$PROD_DIR" apply -input=false canary.tfplan'
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$PROD_DIR" output -raw alb_url').trim()
          try {
            sh "scripts/canary-check.sh '${url}' '${env.IMAGE_TAG}' 5 1"
          } catch (err) {
            sh 'scripts/release.sh "$PROD_DIR" --weight 0'
            error("Canary aborted: ${env.IMAGE_TAG} broke the criteria. Production is back on its previous version.")
          }
        }
      }
    }

    stage('Promote in production') {
      when { branch 'main' }
      steps {
        sh '''
          previous=$(terraform -chdir="$PROD_DIR" output -raw stable_image_tag)
          scripts/release.sh "$PROD_DIR" --stable "$IMAGE_TAG" --canary "$IMAGE_TAG" --weight 0
          aws ssm put-parameter --name /quickcart/prod/previous_stable --value "$previous" --type String --overwrite >/dev/null
        '''
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$PROD_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.IMAGE_TAG)
        }
      }
    }
  }

  post {
    success {
      sh 'aws sns publish --topic-arn "$TOPIC_ARN" --subject "QuickCart $BRANCH_NAME #$BUILD_NUMBER passed" --message "Commit $IMAGE_TAG. $BUILD_URL" >/dev/null || true'
    }
    failure {
      sh 'aws sns publish --topic-arn "$TOPIC_ARN" --subject "QuickCart $BRANCH_NAME #$BUILD_NUMBER FAILED" --message "Commit $IMAGE_TAG. Open the build: $BUILD_URL" >/dev/null || true'
    }
  }
}
```

| Runs on | Stages |
|---|---|
| Every change | Prepare → Test the app → Build the image → Check the Terraform |
| Pull requests | + Plan dev, post it on the pull request |
| `main` | + Push → Deploy to dev → Smoke test → Approve → Canary in production → Promote |

**`jobs/rollback.Jenkinsfile`**

```groovy
// One-click rollback. Default: go back to the version before the last release.

@Library('quickcart-lib') _

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['prod', 'dev'], description: 'Which environment to roll back')
    string(name: 'IMAGE_TAG', defaultValue: 'previous', description: '"previous" returns to the version before the last release. Or give a commit tag, like a1b2c3d.')
    string(name: 'REASON', defaultValue: '', description: 'Why. Required: it goes into the notification.')
  }

  environment {
    AWS_REGION       = 'us-east-1'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
  }

  stages {
    stage('Check the request') {
      steps {
        script {
          if (!params.REASON?.trim()) {
            error('REASON is required.')
          }
          env.ENV_DIR = "infra/envs/${params.ENVIRONMENT}/us-east-1"
          env.TARGET = params.IMAGE_TAG.trim() == 'previous'
            ? sh(returnStdout: true, script: 'aws ssm get-parameter --name "/quickcart/$ENVIRONMENT/previous_stable" --query Parameter.Value --output text').trim()
            : params.IMAGE_TAG.trim()
          sh 'terraform -chdir="$ENV_DIR" init -input=false >/dev/null'
          env.CURRENT = sh(returnStdout: true, script: 'terraform -chdir="$ENV_DIR" output -raw stable_image_tag').trim()
        }
        // Refuse a version that was never built, before touching anything.
        sh 'aws ecr describe-images --repository-name quickcart/orders --image-ids imageTag="$TARGET" >/dev/null'
        echo "Rolling ${params.ENVIRONMENT} back from ${env.CURRENT} to ${env.TARGET}"
      }
    }

    stage('Roll back') {
      steps {
        sh 'scripts/release.sh "$ENV_DIR" --stable "$TARGET" --canary "$TARGET" --weight 0'
      }
    }

    stage('Smoke test') {
      steps {
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$ENV_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.TARGET)
        }
      }
    }

    stage('Record it') {
      steps {
        // The version we left becomes "previous", so a second click undoes the rollback.
        sh 'aws ssm put-parameter --name "/quickcart/$ENVIRONMENT/previous_stable" --value "$CURRENT" --type String --overwrite >/dev/null'
      }
    }
  }

  post {
    always {
      sh '''
        topic="arn:aws:sns:$AWS_REGION:$(aws sts get-caller-identity --query Account --output text):quickcart-pipeline"
        aws sns publish --topic-arn "$topic" \
          --subject "QuickCart rollback of $ENVIRONMENT" \
          --message "Rolled back from $CURRENT to $TARGET. Reason: $REASON. $BUILD_URL" >/dev/null || true
      '''
    }
  }
}
```

**`jobs/safe-sql.Jenkinsfile`**

```groovy
// Run ONE SQL statement safely. Dry-run shows the effect and rolls back.
// Commit needs someone to approve it.

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Which database. Commits to either need an approval.')
    text(name: 'SQL', defaultValue: '', description: 'One statement. No semicolons inside it.')
    choice(name: 'MODE', choices: ['dry-run', 'commit'], description: 'dry-run runs it and then rolls it back, so you can see the effect safely')
    string(name: 'TICKET', defaultValue: '', description: 'Ticket number or reason. Required.')
    booleanParam(name: 'ALLOW_DDL', defaultValue: false, description: 'Allow CREATE and ALTER. These commit immediately and cannot be dry-run.')
  }

  environment {
    AWS_REGION       = 'us-east-1'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
  }

  stages {
    stage('Approve a commit') {
      when { expression { params.MODE == 'commit' } }
      steps {
        timeout(time: 15, unit: 'MINUTES') {
          input message: "Commit this SQL to ${params.ENVIRONMENT}? Ticket ${params.TICKET}:\n\n${params.SQL}",
                ok: 'Commit it'
        }
      }
    }

    stage('Run the SQL') {
      steps {
        sh 'ENV_DIR="infra/envs/$ENVIRONMENT/us-east-1" scripts/safe-sql.sh'
      }
    }
  }
}
```

**`jobs/extract-logs.Jenkinsfile`**

```groovy
// Pull an app's logs for a time window, and keep them as a build artifact.

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 15, unit: 'MINUTES')
  }

  parameters {
    choice(name: 'LOG_GROUP',
           choices: ['/ecs/qc-prod-use1-orders', '/ecs/qc-prod-use1-orders-canary', '/ecs/qc-prod-use1-ops-sql',
                     '/ecs/qc-dev-use1-orders', '/ecs/qc-dev-use1-orders-canary', '/ecs/qc-dev-use1-ops-sql'],
           description: 'Which service')
    string(name: 'START', defaultValue: '', description: 'UTC, for example 2026-09-29 14:00')
    string(name: 'END', defaultValue: '', description: 'UTC. At most 24 hours after START.')
    string(name: 'FILTER', defaultValue: '', description: 'Optional CloudWatch filter pattern, for example ERROR')
  }

  environment {
    AWS_REGION = 'us-east-1'
  }

  stages {
    stage('Extract') {
      steps {
        sh 'scripts/extract-logs.sh'
      }
    }
  }

  post {
    success {
      archiveArtifacts artifacts: 'logs-*.txt'
    }
  }
}
```

```bash
chmod +x scripts/*.sh && git add . && git commit -m "Delivery pipeline" && git push
```

### 18.3 Connect GitHub and Jenkins

- [ ] Done

In the `quickcart` folder: **New Item** → **Multibranch Pipeline**, named `quickcart-final`.

| Field | Enter |
|---|---|
| Branch Sources | GitHub, credentials `github-token`, URL `https://github.com/YOUR_GITHUB_USER/quickcart-final` |
| Build Configuration | by Jenkinsfile |

On GitHub: the repository → **Settings** → Webhooks → Add webhook:

| Field | Enter |
|---|---|
| Payload URL | the `webhook_url` output |
| Content type | `application/json` |
| Events | Let me select: **Pushes** and **Pull requests** |

Then three **Pipeline** jobs, each with *Pipeline script from SCM* → Git → the repository URL → credentials → branch `*/main`:

| Folder | Job name | Script Path |
|---|---|---|
| quickcart | `rollback` | `jobs/rollback.Jenkinsfile` |
| operations | `safe-sql` | `jobs/safe-sql.Jenkinsfile` |
| operations | `extract-logs` | `jobs/extract-logs.Jenkinsfile` |

> ⚠️ **The first run of each job fails — on purpose.** Jenkins only learns a job's parameters by running it once. Press **Build Now** on each; it fails on the empty inputs ("SQL is empty", "REASON is required"). After that, **Build with Parameters** appears.

---

<a id="stage-19"></a>

## Stage 19 — The first release

*A pull request with its plan, then a merge that travels to production with nobody touching the console.*

### 19.1 A pull request carries its plan

- [ ] Done

> 🔴 **The problem this solves.** A4's pull request needed you to paste the plan by hand. People forget, or paste an old one. Now it's automatic and always current.

```bash
git checkout -b dev-logs && sed -i '' 's/log_retention_days = 7/log_retention_days = 14/' infra/envs/dev/us-east-1/terraform.tfvars && git commit -am "dev: keep logs 14 days" && git push -u origin dev-logs
```

| Part | What it means |
|---|---|
| `sed -i ''` | edit the file in place (the empty quotes are needed on a Mac) |

Open the pull request on GitHub.

> ✅ **You should see:** Within a minute, Jenkins starts a build for `PR-1`. When it finishes, a comment appears on the pull request: **Plan: 0 to add, 2 to change, 0 to destroy**, with the full plan folded underneath.

### 19.2 Merge, and follow it to production

- [ ] Done

Merge the pull request. Jenkins builds `main`:

| Stage | What you see |
|---|---|
| Push the image | A new tag in ECR: the commit's first 7 characters |
| Deploy to dev | Terraform applies, and waits until the new tasks are stable |
| Smoke test dev | `Smoke test passed: https://orders.dev.YOUR_DOMAIN is serving a1b2c3d` |
| Approve a production canary | The build pauses. Open `prod-canary-plan.txt` in its artifacts, read it, then click **Start the canary** |
| Canary in production | 5 minutes of measurement, then `PASS` |
| Promote in production | Everyone on the new version; its smoke test passes |

```bash
curl https://orders.YOUR_DOMAIN/health
```

> ✅ **You should see:** The new commit's tag as `version`. You never opened the AWS console.

> 💡 **DORA, measured for free.** Jenkins now holds the Week 1 metrics: every build is a deployment with a time (**deployment frequency**), from commit to production (**lead time**), and every failed or aborted one counts toward **change failure rate**. The rollback in stage 21 is your **time to restore**.

---

<a id="stage-20"></a>

## Stage 20 — A bad release

*Ship a real bug on purpose, and watch two safety nets catch it.*

### 20.1 Ship the bug

- [ ] Done

> 🔴 **The problem this solves.** Every check so far passed because nothing was wrong. A safety net you've never seen catch anything is a guess.

On a new branch, change one line in `app/app.py` — 30% of orders requests will now fail:

```
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0.3"))
```

Commit, push, open a pull request, merge. The tests still pass (they set the rate to 0), and the smoke test passes too — it checks `/health`, which this bug doesn't touch. **That's realistic**: many real bugs get past tests.

### 20.2 Net 1: the dev alarm

- [ ] Done

While the pipeline waits at the approval, dev is running the bad version. Send it traffic:

```bash
for i in $(seq 1 300); do curl -s -o /dev/null -w "%{http_code}\n" https://orders.dev.YOUR_DOMAIN/orders; done | sort | uniq -c
```

| Part | What it means |
|---|---|
| `for i in $(seq 1 300)` | repeat 300 times |
| `-w "%{http_code}\n"` | print only each response's status |
| `sort \| uniq -c` | count each status |

> ✅ **You should see:** About 210 lines of `200` and about 90 of `500`.

> ✅ **You should see:** Within about 10 minutes, an email: **ALARM: qc-dev-use1-error-rate-above-slo**. 30% of requests failing is far past dev's 1% error budget.

### 20.3 Net 2: the production canary

- [ ] Done

Now approve the canary. The check sees the canary's errors:

> ✅ **You should see:** `ABORT: canary error rate 29.x% is above 1%.` The pipeline sets the weight back to 0, then fails the build. A failure email follows. **90% of production customers never saw the bug; the 10% saw it for five minutes.**

```bash
curl https://orders.YOUR_DOMAIN/health
```

> ✅ **You should see:** Still the previous, good version.

---

<a id="stage-21"></a>

## Stage 21 — Triage and roll back

*The 5xx runbook, for real: restore first, then find out why.*

### 21.1 Restore first: roll back dev

- [ ] Done

> 🔴 **The problem this solves.** dev is still failing 30% of requests. The first question in any incident is "did something just change?" — and it did. A rollback takes a minute; understanding the bug can take an hour.

> 🧭 Jenkins → `quickcart` → `rollback` → **Build with Parameters**

| Field | Enter |
|---|---|
| ENVIRONMENT | dev |
| IMAGE_TAG | `previous` |
| REASON | 30% of orders failing after the last release |

> ✅ **You should see:** `Rolling dev back from ... to ...`, a passing smoke test, a notification email — and a few minutes later, **OK: qc-dev-use1-error-rate-above-slo**. Time it: that's your time to restore.

### 21.2 Then investigate

- [ ] Done

Now, calmly, the evidence. The log-extraction job, for the window when the alarm fired:

> 🧭 Jenkins → `operations` → `extract-logs` → Build with Parameters: `/ecs/qc-dev-use1-orders`, the window in UTC, FILTER `ERROR`

> ✅ **You should see:** A file in the build's artifacts, full of `{"level": "ERROR", "event": "orders_failed", "version": "..."}` — with the bad version's tag in every line.

And the load balancer's own record of every request, in S3:

```bash
aws s3 ls s3://$(terraform -chdir=infra/envs/dev/us-east-1 output -raw alb_logs_bucket)/alb/AWSLogs/YOUR_ACCOUNT_ID/elasticloadbalancing/us-east-1/ --recursive | tail -3
```

> ✅ **You should see:** Compressed log files, one every 5 minutes. Each line is one request, with its status and timings.

### 21.3 Fix forward

- [ ] Done

Revert the bad change on GitHub — the merged pull request has a **Revert** button — and merge the revert. The pipeline releases the fix through dev, the canary and production like any other change.

> 💡 **Why not just leave the rollback?.** The rollback put the old version back, but `main` still contains the bug. The next unrelated release would ship it again. A rollback buys time; the revert is the actual fix.

---

<a id="stage-22"></a>

## Stage 22 — Change data safely

*The safe-SQL job: a dry run, guard rails, an approval, and no password in anyone's hands.*

### 22.1 A dry run, then a commit

- [ ] Done

> 🔴 **The problem this solves.** Data sometimes needs fixing by hand. Done by an engineer in a SQL client, one missing `WHERE` changes every row in production.

> 🧭 Jenkins → `operations` → `safe-sql` → Build with Parameters

| Field | Enter |
|---|---|
| ENVIRONMENT | dev |
| SQL | `UPDATE orders SET qty = 10 WHERE item = 'mouse'` |
| MODE | dry-run |
| TICKET | OPS-1 |

> ✅ **You should see:** `rows_affected: 1`, then `Finished: ROLLBACK`. `/orders` still shows 5 mice.

Run it again with **MODE: commit**. The build pauses for approval, showing the SQL. Approve it.

> ✅ **You should see:** `Finished: COMMIT`, and `curl https://orders.dev.YOUR_DOMAIN/orders` shows `"qty": 10` for the mouse.

### 22.2 Watch the guard rails refuse

- [ ] Done

| Try this SQL | The job says |
|---|---|
| `DELETE FROM orders` | `REFUSED: UPDATE and DELETE need a WHERE clause` |
| `DROP TABLE orders` | `REFUSED: DROP and TRUNCATE are never run from this job` |
| Two statements joined by `;` | `REFUSED: One statement per run` |

Each refusal happens before anything touches AWS. The statement runs inside the VPC as a short-lived ECS task, which receives the password from Secrets Manager — Jenkins never sees it.

---

<a id="stage-23"></a>

## Stage 23 — The runbook

*Every procedure you just did, written down with how long it really took.*

### 23.1 Write docs/runbook.md

- [ ] Done

> 🔴 **The problem this solves.** At 3am, with customers affected, nobody remembers commands. A runbook that's been executed and timed turns an incident into following steps.

One section per procedure, each with the same parts — when to use it, before you start, numbered steps, how you know it worked, what to do if it fails, and **last run: date, who, how long**:

| Procedure | You ran it in | Record |
|---|---|---|
| Deploy | stage 19 | Merge to approve to promoted |
| Rollback | stage 21 | Click to alarm OK |
| Log extraction | stage 21 | Parameters to file downloaded |
| Safe SQL | stage 22 | Dry run to committed |
| 5xx triage | stages 20–21 | Alarm email to service restored |
| Database access | stage 14 | Tunnel open to query answered |

For 5xx triage, write the order from the Week 5 notes: **1.** did something just change — if so, roll back first; **2.** load balancer errors or app errors; **3.** target health; **4.** app logs for the window; **5.** the database.

```bash
git add docs/runbook.md && git commit -m "Operations runbook" && git push
```

---

<a id="stage-24"></a>

## Stage 24 — Tear down

*In the right order — including the deliberate way to remove a protected database.*

### 24.1 Production's database is protected

- [ ] Done

> 🔴 **The problem this solves.** `db_deletion_protection = true` means a plain destroy of prod fails — by design. Removing production data must be a deliberate, separate act.

```bash
terraform -chdir=infra/envs/prod/us-east-1 apply -target=module.platform.module.database -var db_deletion_protection=false
```

| Part | What it means |
|---|---|
| `-target=module.platform.module.database` | change only the database. The Week 4 notes call -target a last resort — this is one of its rare right uses |
| `-var db_deletion_protection=false` | switch the protection off, for this one apply |

> ✅ **You should see:** A warning that `-target` is for exceptional cases, then `1 to change`. Type `yes`.

### 24.2 Destroy, newest first

- [ ] Done

```bash
terraform -chdir=infra/envs/prod/us-east-1 destroy && terraform -chdir=infra/envs/dev/us-east-1 destroy
```

> ✅ **You should see:** Each takes 10 to 15 minutes. The database, NAT gateway and load balancer are most of it.

```bash
terraform -chdir=infra/jenkins destroy
```

```bash
aws ssm delete-parameters --names /quickcart/dev/previous_stable /quickcart/prod/previous_stable
```

| Part | What it means |
|---|---|
| `delete-parameters` | remove the two values the pipeline created outside Terraform |

Keep `infra/shared` for now if you might rebuild — it holds your images and the audit trail, and costs cents. To remove it too: `terraform -chdir=infra/shared destroy`. Last of all, the state bucket, by hand.

> ⚠️ **The buckets and the image repository empty themselves.** The Jenkins backup bucket, the audit-trail bucket and the image repository are set to be deleted with their contents, so destroy doesn't stop halfway. Right for a lab; in production, each would be kept — they're evidence and history.

---

<a id="stage-25"></a>

## Stage 25 — Readiness review

*The definition of done, and your evidence for each part.*

### 25.1 What you can now show

- [ ] Done

| The plan asks for | Your evidence |
|---|---|
| AWS built by Terraform, nothing in the console | The repository; the clean second plans; the teardown |
| On pull request: format, validate, lint, scan, test, plan as a comment | The plan comment on your first pull request |
| On merge: build, push, dev, smoke test, approval, then the next environment | The first release's build, stage by stage |
| Canary with criteria written beforehand | `docs/canary-criteria.md`, and the aborted canary in stage 20 |
| A rollback used in anger | Stage 21: a real failure, rolled back, alarm cleared |
| Two operations jobs, safe for a colleague | safe-sql with its refusals; extract-logs with its artifact |
| A runbook, every procedure executed and timed | `docs/runbook.md` |
| A commit reaches production with nobody touching the console | Stage 19 |

And the questions to practise out loud — each answered somewhere in this guide:

| Question | Where the answer is |
|---|---|
| Why doesn't the health check touch the database? | Stage 02 |
| Why is the certificate ARN read from the validation resource? | Stage 05 |
| Why does the service ignore changes to its task count? | Stage 07 |
| How do you reach the database without a bastion, and who can see that you did? | Stages 09 and 14 |
| How is the SLO measured, and why a rate instead of a count? | Stage 10 |
| What stopped the bad release, and how many customers saw it? | Stage 20 |
| Why roll back and then also revert? | Stage 21 |
| What would you change for real production? | Multi-AZ database, two NAT gateways, split IAM roles for Jenkins, agents instead of builds on the controller, HTTPS in front of Jenkins, approval submitters |

---
