# Jenkins + GitHub Setup — What We Did, Step by Step

A record of how the QuickCart CI/CD pipeline was brought up: the Jenkins server, its connection to GitHub, every problem we hit, how each was investigated, and how it was fixed.

Read this together with [infrastructure-guide.md](infrastructure-guide.md), which explains the architecture and the Terraform code.

**Contents**

1. [The goal](#1-the-goal)
2. [Where we started](#2-where-we-started)
3. [Setup steps, in order](#3-setup-steps-in-order)
4. [How the pipeline behaves now](#4-how-the-pipeline-behaves-now)
5. [Problems we hit and how we fixed them](#5-problems-we-hit-and-how-we-fixed-them)
6. [Every investigation command, explained](#6-every-investigation-command-explained)
7. [Still to do](#7-still-to-do)

---

## 1. The goal

Every change pushed to GitHub should be tested, built and deployed automatically, with a human approval before production.

```
Developer ──git push──► GitHub ──webhook──► Jenkins (EC2)
                                              │
                    ┌─────────────────────────┴────────────────────────┐
                    │ test → build image → Terraform checks             │
                    │ PR:   post the Terraform plan on the pull request  │
                    │ main: push image → deploy dev → smoke test         │
                    │       → approve → 10% prod canary → promote        │
                    └───────────────────────────────────────────────────┘
                              │                         │
                       ECR (images)          Terraform state in S3
```

Pieces involved:

| Piece | Where | Purpose |
|---|---|---|
| `abir032/quickcart-final` | GitHub | App, Terraform, `Jenkinsfile`, scripts |
| `abir032/quickcart-jenkins-lib` | GitHub | Shared pipeline steps (`smokeTest`) |
| Jenkins server | EC2, built by `infra/jenkins` | Runs the pipeline |
| Webhook | GitHub repo settings | Tells Jenkins "something changed" |
| `github-token` | Jenkins credential | Lets Jenkins read the repos and comment on PRs |
| IAM role `qc-jenkins` | AWS | Lets Jenkins use AWS without stored keys |

---

## 2. Where we started

Before the Jenkins work began:

- `infra/shared` was applied — the ECR repository `quickcart/orders` existed.
- Image `v2` had been built and pushed by hand.
- `infra/envs/dev/us-east-1` was applied — dev was live at `https://orders.dev.codeemit.com`.
- Placeholders (`111122223333`, `example.com`, `you@example.com`) had been replaced with real values: state bucket `qc-tfstate-126052242757`, zone `codeemit.com`, a real email.

---

## 3. Setup steps, in order

### Step 1 — Configure the Jenkins stack

```bash
cd infra/jenkins
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` (git-ignored, because it contains your IP):

```hcl
my_ip_cidr    = "<your-public-ip>/32"   # from: curl https://checkip.amazonaws.com
alert_email   = "<your-email>"
instance_type = "c7i-flex.large"        # free-tier eligible; the default t3.medium is not
```

- **`my_ip_cidr`** — the only address allowed to open the Jenkins web page (port 8080). `/32` means exactly one address.
- **`instance_type`** — the account is on the AWS Free plan, which refuses non-eligible types. `c7i-flex.large` (2 vCPU, 4 GB, x86) is eligible and big enough for Jenkins + Docker + Terraform.

### Step 2 — Build the Jenkins server

```bash
terraform -chdir=infra/jenkins init
terraform -chdir=infra/jenkins apply
terraform -chdir=infra/jenkins output
```

Outputs used later: `jenkins_url`, `webhook_url`, `instance_id`, `sns_topic_arn`.

The first build of the server **did not work** — the boot script crashed (see [Problem 2](#problem-2--jenkins-never-started-boot-script-failed)). After fixing `user-data.sh`, `terraform apply` **replaced** the instance (because `user_data_replace_on_change = true`), and the new one got a new public IP.

### Step 3 — Get the first-login password

Jenkins prints a one-time password to a file on the server. We reach the server with **Session Manager** — no SSH key, no open port 22.

Install the plugin on the Mac once (see [Problem 3](#problem-3--sessionmanagerplugin-is-not-found)):

```bash
brew install --cask session-manager-plugin
```

Then:

```bash
aws ssm start-session --target <instance_id>
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
exit
```

Alternative without the plugin — the AWS Console: **EC2 → Instances → select Jenkins → Connect → Session Manager → Connect**.

### Step 4 — First-run wizard

1. Open `jenkins_url` in the browser, paste the password.
2. **Install suggested plugins.** They cover everything the pipelines use:

   | Used in the Jenkinsfile | Plugin |
   |---|---|
   | `pipeline {}`, `input`, `retry`, `timeout` | Pipeline |
   | Git checkout, multibranch, `changeRequest()` | Git, GitHub Branch Source |
   | `@Library('quickcart-lib')` | Pipeline: Groovy Libraries |
   | `timestamps()` | Timestamper |
   | `withCredentials` | Credentials Binding |
   | `junit` | JUnit (check it is installed) |

3. Create the admin user. Keep the suggested Jenkins URL.

### Step 5 — Label the built-in node `linux`

Every Jenkinsfile says `agent { label 'linux' }`. Without a node carrying that label, builds wait in the queue forever.

**Manage Jenkins → Nodes → Built-In Node → Configure → Labels: `linux`**, executors `2`, Save.

### Step 6 — Put both repositories on GitHub in the right layout

Jenkins reads `Jenkinsfile` from the **top** of the repository, and the scripts use paths like `app/`, `scripts/`, `infra/envs/dev/us-east-1`. Locally, the project sat one folder too deep, so the git root was moved.

**Shared library repo** (`vars/` must be at its top):

```bash
cd quickcart-jenkins-lib
git init -b main
printf '.DS_Store\n' > .gitignore
git add .gitignore vars
git commit -m "Add smokeTest shared pipeline step"
git remote add origin git@github-p:abir032/quickcart-jenkins-lib.git
git push -u origin main
```

**Main repo** (move the git root into the inner folder, keep history):

```bash
cd quickcart-final                       # the outer folder, which held .git
mv .git quickcart-final/.git             # the inner folder becomes the repo root
cd quickcart-final
# Jenkinsfile line 21: GH_REPO = 'abir032/quickcart-final'
printf '\n# macOS\n.DS_Store\n' >> .gitignore
git add -A
git status --short                       # review: no tfvars with your IP, no .terraform/, no state
git commit -m "Add QuickCart app, Terraform infrastructure and Jenkins pipelines"
git push origin main
```

What is deliberately committed and what is not:

| Committed | Why |
|---|---|
| `terraform.tfvars` for shared, dev, prod | Jenkins runs Terraform from the repo and needs the values. Nothing secret in them. |
| `.terraform.lock.hcl` files | Pins exact provider versions so Jenkins uses the same ones |

| Not committed (`.gitignore`) | Why |
|---|---|
| `infra/jenkins/terraform.tfvars` | Contains your IP |
| `.terraform/`, `*.tfstate`, `*.tfplan` | Local working files; state lives in S3 |

### Step 7 — GitHub token and Jenkins credential

**GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**

- Repository access: only `quickcart-final` and `quickcart-jenkins-lib`
- Repository permissions:

  | Permission | Level | Needed for |
  |---|---|---|
  | Contents | Read-only | Cloning the code and library |
  | Metadata | Read-only | Set automatically |
  | Pull requests | Read and write | Listing PRs, posting the plan comment |
  | Issues | Read and write | PR comments go through the Issues API |
  | Commit statuses | Read and write | The ✓/✗ next to commits and PRs |

**Jenkins → Manage Jenkins → Credentials → System → Global → Add Credentials**

| Field | Value |
|---|---|
| Kind | Username with password |
| Username | `abir032` |
| Password | the token |
| ID | `github-token` — exactly; the Jenkinsfile looks it up by this ID |

### Step 8 — Register the shared library

**Manage Jenkins → System → Global Trusted Pipeline Libraries → Add**

| Field | Value |
|---|---|
| Name | `quickcart-lib` — must match `@Library('quickcart-lib')` |
| Default version | `main` |
| Retrieval | Modern SCM → GitHub, credential `github-token`, repo `https://github.com/abir032/quickcart-jenkins-lib` |

Each file in the library's `vars/` becomes a pipeline step: `vars/smokeTest.groovy` → `smokeTest(url: ..., version: ...)`.

### Step 9 — Create the Multibranch Pipeline job

**Dashboard → + New Item → name `quickcart` → Multibranch Pipeline → OK**

- Branch Sources → Add source → **GitHub** → credential `github-token` → `https://github.com/abir032/quickcart-final` → **Validate**
- Build Configuration → by Jenkinsfile, Script Path `Jenkinsfile`
- Save

**Why Multibranch:** it creates a pipeline per branch and per pull request automatically. The Jenkinsfile depends on it: `when { branch 'main' }` and `when { changeRequest() }` only work in a Multibranch job.

Saving triggers a repository scan, which found `main` and started build #1.

### Step 10 — The webhook

**GitHub repo → Settings → Webhooks → Add webhook**

| Field | Value |
|---|---|
| Payload URL | `http://<jenkins-ip>:8080/github-webhook/` (trailing slash matters) |
| Content type | `application/json` |
| Events | Pushes, Pull requests |

GitHub's webhook servers are allowed through the Jenkins security group automatically: `infra/jenkins/main.tf` reads GitHub's published address ranges from `https://api.github.com/meta`.

---

## 4. How the pipeline behaves now

### Push (or merge) to `main`

```
1  Prepare                 IMAGE_TAG = short commit ID
2  Test the app            flake8 + pytest
3  Build the image         docker build ...:<commit>
4  Check the Terraform     fmt, validate, test (14 mocked scenarios), tflint, trivy
5  Push the image          to ECR (skipped if the tag is already there)
6  Deploy to dev           terraform apply with the new tag; ECS rolls with no downtime
7  Smoke test dev          /health must report the new version
8  Approve prod canary     PAUSES for a human, up to 30 minutes
9  Canary in production    10% of traffic on the new version, checked
10 Promote in production   100% on the new version
```

Build #2 proved steps 1–7 work: dev went from `v2` to `8ec8c5e` automatically. The approval was aborted because prod has not been built (approving would create the whole prod environment).

### Pull request

Steps 1–4, then **"Plan dev, post it on the pull request"** — Terraform plans dev and posts the plan as a PR comment. Nothing is pushed or deployed. Merging the PR starts the `main` flow.

### Things to know

- Only one build runs at a time (`disableConcurrentBuilds`). A build waiting at approval blocks the next one — abort it if you don't want prod.
- Every commit becomes a new, immutable image tag. That is what makes the rollback job possible.
- Success and failure emails come from the `quickcart-pipeline` SNS topic.

---

## 5. Problems we hit and how we fixed them

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Dev apply: `instance type is not eligible for Free Tier` | Free-plan account; ops instance was `t4g.nano` | `infra/modules/ops-access/main.tf`: `t4g.micro` (ARM, matches the ARM AMI) |
| 2 | Jenkins page didn't load | Boot script died: tflint install URL returned 404 | `user-data.sh`: download the tflint release zip; re-apply (instance replaced) |
| 3 | `SessionManagerPlugin is not found` | Plugin not installed on the Mac | `brew install --cask session-manager-plugin` |
| 4 | Build #1: `script returned exit code 126` | Scripts committed without the executable bit | `chmod +x scripts/*.sh`, commit, push |
| 5 | `Could not update commit status ... 403` | Token missing *Commit statuses* permission | Add the permission to the token |
| 6 | PR build: `app.py:48:1: E302 expected 2 blank lines` | PEP 8: two blank lines before a top-level function | Added the blank line |
| 7 | PR build: `curl: (22) ... error: 403` when posting the plan | Token missing *Issues* / *Pull requests* write | Add the permissions to the token |
| 8 | Not a build failure: `/orders/<id>` would return 500 | `repo.get_order` doesn't exist; no test covers it | Add `get_order` to both repository classes + tests |

### Problem 1 — Free Tier instance type

The account is on the AWS **Free plan**, which refuses to launch EC2 types outside the free-tier list. Terraform's apply is not all-or-nothing: everything created before the error stayed in state, so re-running `apply` only created what was missing.

### Problem 2 — Jenkins never started (boot script failed)

`infra/jenkins/user-data.sh` runs once on first boot with `set -e`, so the first failing command stops it. The log showed `curl: (22) ... 404` for `tflint/master/install_linux.sh` — the tflint project removed that script. Docker setup, the Jenkins start and the backup job never ran.

Fix in `user-data.sh`:

```bash
curl -fsSL -o /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_amd64.zip
unzip -o /tmp/tflint.zip -d /usr/local/bin
rm -f /tmp/tflint.zip
```

A boot script only runs on a new machine, so the fix is a replacement: `terraform -chdir=infra/jenkins apply`.

### Problem 3 — Session Manager plugin

`aws ssm start-session` only *asks* AWS to open a session; the plugin carries the interactive terminal. `aws ssm send-command` (run one command, read its output later) needs no plugin — that is what the investigation in section 6 uses.

### Problem 4 — Exit code 126

Exit code **126** means "found but cannot execute". Git stores the executable permission with each file: the scripts were `100644` (not executable); they need `100755`. Jenkins checks out files exactly as git stores them.

```bash
chmod +x scripts/*.sh
git add scripts
git commit -m "Make pipeline scripts executable"
git push origin main
```

### Problems 5 and 7 — Token permissions

Both are HTTP **403 Forbidden** from GitHub: the token was valid, but not allowed to do that action. PR comments use the Issues API (`/issues/<n>/comments`) because every PR is also an issue. Editing a fine-grained token's permissions keeps the same token value, so nothing changes in Jenkins.

### Problem 6 — flake8

The pipeline's style check failed, so pytest never ran. The long `junit ... No test report files were found` stack trace that followed is only a side effect — no report existed to collect.

### Problem 8 — A bug the pipeline cannot see

A green build only proves what the tests check. The new endpoint calls a method that doesn't exist, and no test calls the endpoint. Lesson: every new endpoint needs tests for its success and failure cases.

---

## 6. Every investigation command, explained

Commands are grouped by what we were trying to find out. Values like the instance ID changed when Jenkins was replaced; use `terraform output` to get current ones.

### 6.1 Understanding the project

```bash
find . -name "*.tf" -o -name "*.tfvars*" -o -name "*.hcl" | grep -v .terraform/
```
Lists every Terraform file in the project (skipping downloaded provider files) to see the folder structure.

```bash
grep -rnE "terraform (init|plan|apply|output|test)|-var |chdir" Jenkinsfile jobs scripts
```
Finds every place the pipeline calls Terraform — shows how Jenkins drives the infrastructure (`release.sh` passes `-var` image tags).

```bash
grep -hoE "\b(timestamps|junit|archiveArtifacts|input|withCredentials|...)\b" Jenkinsfile jobs/*.Jenkinsfile
```
Lists the pipeline steps used, to know which Jenkins plugins are required.

### 6.2 Checking the AWS account before applying

```bash
aws sts get-caller-identity --query Account --output text
```
"Who am I?" — confirms which AWS account the CLI is using (`126052242757`). Always the first check when something is denied.

```bash
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output text
```
Lists image repositories — confirmed `quickcart/orders` existed.

```bash
aws s3 ls
aws s3 ls s3://qc-tfstate-126052242757 --recursive
```
Lists buckets, then the state files inside the state bucket — showed shared and dev state already existed.

```bash
aws s3 cp s3://qc-tfstate-126052242757/shared/terraform.tfstate - \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print([r["type"]+"."+r["name"] for r in s["resources"]])'
```
Prints which resources a state file tracks (`-` means "write to the screen"). Showed shared held only ECR, and dev's state was empty.

```bash
aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text
```
Lists DNS zones you own — found `codeemit.com`, used for `zone_name`.

```bash
aws cloudtrail describe-trails --query 'trailList[].Name' --output text
aws budgets describe-budgets --account-id 126052242757 --query 'Budgets[].BudgetName' --output text
```
Checked whether the audit trail and budget from `shared` already existed (they didn't — the next shared apply would add them).

### 6.3 The Free Tier error

```bash
aws ec2 describe-instance-types --region us-east-1 \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].[InstanceType,ProcessorInfo.SupportedArchitectures[0]]' --output text
```
Asks AWS which instance types this account may launch, with their CPU architecture. Used to pick `t4g.micro` (ARM) for ops and `c7i-flex.large` (x86) for Jenkins.

```bash
grep -n "instance_type" infra/modules/ops-access/main.tf infra/jenkins/*.tf
```
Finds where instance sizes are set — hard-coded in ops-access, a variable in jenkins.

### 6.4 Your public IP

```bash
curl -s https://checkip.amazonaws.com
```
Prints the public IP the internet sees for your network — the value for `my_ip_cidr`.

```bash
whois 103.197.206.21 | grep -iE "^(netname|descr|country)"
```
Shows who owns an IP — your internet provider.

### 6.5 What is running and costing money

```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'length(NatGateways)'
aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus]' --output text
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
aws ec2 describe-instances --filters Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].[InstanceType,Tags[?Key==`Name`]|[0].Value]' --output text
aws ecs list-clusters --query clusterArns --output text
aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AssociationId!=`null`]' --output text
```
One line per billable resource type: NAT gateways, databases, load balancers, EC2 instances, ECS clusters, public IPs. Found an old database `w4-dev-db` from an earlier exercise still running. `--query` uses JMESPath to keep only the useful fields.

### 6.6 Is dev up? Is Jenkins reachable?

```bash
terraform -chdir=infra/envs/dev/us-east-1 output -raw alb_url
terraform -chdir=infra/jenkins output
```
Reads values saved in state — the site URL and Jenkins URL, webhook URL, instance ID.

```bash
curl -s -m 10 https://orders.dev.codeemit.com/health
```
Calls the app's health endpoint. `{"status":"ok","version":"v2"}` means DNS, certificate, load balancer, ECS and the app all work. `-m 10` gives up after 10 seconds.

```bash
curl -s -m 10 -o /dev/null -w "%{http_code}\n" http://<jenkins-ip>:8080/login
```
Prints only the HTTP status code. `000` = nothing answered (Jenkins down or blocked); `200` = up; `403` = up but needs login.

### 6.7 Why Jenkins wasn't answering

```bash
aws ec2 describe-instances --instance-ids <instance_id> \
  --query 'Reservations[0].Instances[0].[State.Name,LaunchTime]' --output text
```
Is the machine running, and since when?

```bash
aws ec2 describe-security-groups --filters Name=group-name,Values=qc-jenkins \
  --query 'SecurityGroups[0].IpPermissions[0].IpRanges[].CidrIp' --output text
```
Which IPs the firewall allows — confirmed your current IP was allowed, ruling out the firewall.

```bash
aws ssm describe-instance-information --filters Key=InstanceIds,Values=<instance_id> \
  --query 'InstanceInformationList[0].PingStatus' --output text
```
`Online` means the SSM agent is connected, so commands can be sent to the server.

```bash
id=$(aws ssm send-command --instance-ids <instance_id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl is-active jenkins","ss -ltnp | grep 8080 || echo no-listener","tail -n 15 /var/log/cloud-init-output.log"]' \
  --query Command.CommandId --output text)
sleep 6
aws ssm get-command-invocation --command-id "$id" --instance-id <instance_id> \
  --query '[Status,StandardOutputContent]' --output text
```
Runs commands **on the server** without SSH or the plugin, then reads the output:
- `systemctl is-active jenkins` — is the Jenkins service running? (`inactive`)
- `ss -ltnp | grep 8080` — is anything listening on port 8080? (no)
- `tail /var/log/cloud-init-output.log` — the boot script's log. Showed the tflint 404 and the script stopping.

`send-command` returns a command ID immediately; `get-command-invocation` fetches the result a few seconds later.

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh
curl -sIL -o /dev/null -w '%{http_code}\n' https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_amd64.zip
```
Checked the old install URL (404 — gone) and the replacement release download (200 — works) before changing `user-data.sh`. `-I` asks for headers only, `-L` follows redirects.

After the replacement, the same `send-command` pattern with `systemctl is-active jenkins` returned `active` and the log ended with `Jenkins setup finished`.

### 6.8 Session Manager plugin

```bash
uname -m                              # arm64 = Apple Silicon
which brew session-manager-plugin     # is Homebrew there? is the plugin installed?
```
Picked the right install method (`brew install --cask session-manager-plugin`).

### 6.9 Why DNS worked without touching the registrar

```bash
dig +short NS codeemit.com
```
Which name servers the internet uses for the domain — they were Route 53's.

```bash
aws route53 get-hosted-zone --id <zone-id> --query 'DelegationSet.NameServers' --output text
```
The name servers of your Route 53 zone — matched the `dig` result, so delegation was already done.

```bash
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --query 'ResourceRecordSets[].[Name,Type]' --output text
```
Records in the zone — showed the ACM validation CNAME and the `orders.dev` A record Terraform created.

```bash
whois codeemit.com | grep -iE "registrar:|name server"
```
Registrar (PublicDomainRegistry) and the name servers set there.

### 6.10 Preparing the repositories

```bash
git remote -v
git log --oneline --all
git ls-tree -r HEAD --name-only
git ls-remote origin
```
Where the repo pushes, its history, the files in the last commit, and what GitHub currently has. Showed GitHub held only the initial README commit.

```bash
git ls-remote git@github-p:abir032/quickcart-jenkins-lib.git
```
No output = the new library repo was empty and safe to push to.

```bash
git grep -nI --cached -e 111122223333 -e "you@example" -- ':!infra/modules'
git grep -nIE --cached "(AKIA[0-9A-Z]{16}|ghp_|github_pat_|BEGIN .*PRIVATE)"
```
Searched the **staged** files (`--cached`) before the first push: the first for leftover placeholders, the second for AWS keys, GitHub tokens and private keys. Neither found anything in real config.

### 6.11 Why build #1 failed

```bash
aws ecr describe-images --repository-name quickcart/orders \
  --query 'sort_by(imageDetails,&imagePushedAt)[].[imageTags[0],imagePushedAt]' --output text
```
Image tags in ECR, oldest first. No tag for the new commit = the build never reached "Push the image".

```bash
aws ecs describe-services --cluster qc-dev-use1-cluster --services qc-dev-use1-orders \
  --query 'services[0].[taskDefinition,deployments[0].rolloutState]' --output text
```
Which task definition revision dev runs and whether its rollout finished.

Build results and logs read on the server (same `send-command` pattern):

```bash
# result of every build of every branch
for d in /var/lib/jenkins/jobs/quickcart/branches/*/builds/*/; do
  grep -m1 -o "<result>[A-Z]*" "$d/build.xml" || echo RUNNING
done

# the readable part of a build log
sed -e "s/ha:[^[]*//" /var/lib/jenkins/jobs/quickcart/branches/main/builds/1/log | tail -40
```
Jenkins stores each build under `jobs/<job>/branches/<branch>/builds/<n>/`: `build.xml` holds the result, `log` the console output. The `sed` strips Jenkins's encoded annotations (`ha:////...`) to leave readable text. This showed `ERROR: script returned exit code 126` in "Check the Terraform".

```bash
git ls-files -s scripts
```
Shows each file's mode as stored in git — `100644` confirmed the scripts weren't executable.

```bash
terraform fmt -check -recursive infra
terraform -chdir=infra/modules/platform init -input=false -backend=false
terraform -chdir=infra/modules/platform test -no-color
```
Ran the pipeline's Terraform checks locally before pushing the fix, so the next build wouldn't fail at the following step. `-backend=false` doesn't touch the S3 state. Result: 14 passed.

### 6.12 Why the PR builds failed

```bash
git fetch origin
git diff origin/main...origin/api_added
```
Downloads the latest branches and shows what the PR changes (the three dots mean "changes on the branch since it left main").

```bash
grep -n "def " app/repository.py
```
Lists the repository's methods — no `get_order`, which revealed Problem 8.

Build logs (same pattern as 6.11, branch `PR-1`):
- Build #1: `app.py:48:1: E302 expected 2 blank lines`.
- Build #2: tests and Terraform checks passed; "Plan dev" printed `No changes`, then `curl: (22) ... 403` when posting the comment.

```bash
cat scripts/plan-comment.sh
```
Showed the comment is posted to `/repos/<repo>/issues/<n>/comments`, which explained which token permission was missing.

---

## 7. Still to do

1. **Token permissions:** Pull requests, Issues and Commit statuses → Read and write. Re-run PR-1.
2. **Finish the `/orders/<id>` feature:** add `get_order` to both classes in `app/repository.py`, add tests for found (200) and not found (404), run `flake8` and `pytest` locally, push to `api_added`.
3. **Merge PR-1** once green — the `main` build deploys to dev. Abort at the prod approval unless you want prod.
4. **Optional jobs:** create Pipeline jobs for `jobs/rollback.Jenkinsfile`, `jobs/safe-sql.Jenkinsfile`, `jobs/extract-logs.Jenkinsfile` (Pipeline script from SCM, same repo, matching Script Path).
5. **Cost:** when done for the day, `terraform -chdir=infra/envs/dev/us-east-1 destroy` and `terraform -chdir=infra/jenkins destroy`. Keep `shared`.
