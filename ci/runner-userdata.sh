#!/bin/bash
#
# ci/runner-userdata.sh — Hetzner VM cloud-init (user-data).
#
# Runs once on first boot. Installs the build toolchain, downloads the GitHub
# Actions runner, registers it as an EPHEMERAL self-hosted runner with a unique
# label, and starts it. Ephemeral => it runs exactly one job then deregisters
# and exits (the workflow's teardown job then deletes the whole VM).
#
# The workflow renders this file with envsubst, substituting:
#   ${REPO_URL}      https://github.com/<owner>/<repo>
#   ${RUNNER_TOKEN}  short-lived registration token (from the GitHub API)
#   ${RUNNER_LABEL}  unique label for this run (so the build job targets THIS vm)
#
set -eux
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y openjdk-21-jre-headless osmium-tool wget unzip python3 git curl jq tar

# The runner refuses to run as root, so use a dedicated user.
useradd -m -s /bin/bash runner || true

RUNNER_VERSION="$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
cd /home/runner
curl -sL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
mkdir -p actions-runner
tar xzf runner.tar.gz -C actions-runner
chown -R runner:runner /home/runner

sudo -u runner bash -c "cd /home/runner/actions-runner && \
  ./config.sh --unattended \
    --url '${REPO_URL}' \
    --token '${RUNNER_TOKEN}' \
    --labels '${RUNNER_LABEL}' \
    --name '${RUNNER_LABEL}' \
    --ephemeral"

# Install & start the runner as a systemd service (as user 'runner'). This is
# essential: a plain backgrounded ./run.sh would be killed when cloud-init's
# cloud-final.service exits (systemd KillMode=control-group). The service runs
# independently. --ephemeral => the runner processes one job then exits; the
# workflow's teardown then deletes the whole VM.
cd /home/runner/actions-runner
./svc.sh install runner
./svc.sh start
