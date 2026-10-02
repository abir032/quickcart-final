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
# tflint's install script was removed upstream; install the release binary directly.
curl -fsSL -o /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_amd64.zip
unzip -o /tmp/tflint.zip -d /usr/local/bin
rm -f /tmp/tflint.zip
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
