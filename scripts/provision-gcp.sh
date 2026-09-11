#!/usr/bin/env bash
# provision-gcp — build the Clearcote arm64 Chromium on an ephemeral GCP x86-64 VM.
#
# This is the end-to-end, "just do it" driver for docs/BUILD-ARM64.md. It provisions a native
# x86-64 (NOT arm) spot VM, builds the x64 build image NATIVELY (no --platform — that is the
# whole Rosetta fix), runs scripts/fresh-arm64.sh in a container, then you fetch the artifact
# and tear the VM down.
#
# The single hard requirement (see docs/BUILD-ARM64.md): the x64 HOST TOOLS must run on real
# x86-64 silicon. A GCP n2/c2 VM is exactly that. Budget: ~1–2 h, ~$2–6 on spot.
#
# Subcommands:
#   provision   (default)  create the VM; its startup script does the whole build unattended,
#                          teeing to /root/clearcote-gcp-build.log and copying the artifact to /root/dist.
#   status                   show VM status + the build status marker + log tail
#   fetch                    scp the tar.xz + SHA256SUMS.txt to ./dist (on this machine)
#   teardown                 delete the VM (stops billing) — do this when done
#
# Configuration (env or flags):
#   PROJECT   GCP project id            (default: `gcloud config get-value project`)
#   ZONE      e.g. us-central1-b        (default: us-central1-b; us-central1-a/c had no n2
#                                        standard-32/64 stock as of Sep 2026)
#   MACHINE   machine type              (default: n2-standard-32 = 32 vCPU / 128 GB)
#   SPOT      1=spot(preemptible)       (default: 1; set 0 for on-demand, ~3x, no preemption)
#   DISK_GB   boot disk size            (default: 300)
#   REPO_URL  fork to clone             (default: this project's fork, arm64 branch)
#
# Requires: gcloud CLI with an authenticated account + the compute API enabled.
#
# Note (macOS gcloud): if `gcloud compute ssh`/`scp` die with a compute.ssh plugin error,
# point gcloud at a newer interpreter: export CLOUDSDK_PYTHON=/path/to/python3.9+.
#
# NOTE: a spot VM that gets preempted mid-build STOPS (termination-action=STOP); re-provision
# fresh (the volume is on the boot disk and dies with it) — on 32 cores a rerun is cheap.
set -euo pipefail

VM="${VM:-clearcote-build}"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-b}"
MACHINE="${MACHINE:-n2-standard-32}"
SPOT="${SPOT:-1}"
DISK_GB="${DISK_GB:-300}"
REPO_BRANCH="${REPO_BRANCH:-arm64}"
REPO_URL="${REPO_URL:-https://github.com/ramicaza/clearcote-browser.git}"
command="${1:-provision}"

die(){ echo "FATAL: $*" >&2; exit 1; }
[ -n "$PROJECT" ] || die "no PROJECT (set PROJECT=... or \`gcloud config set project ...\`)"

# The VM-side startup script template. __REPO_URL__ / __REPO_BRANCH__ are substituted with the
# real values below (the VM's bash must not be the one expanding them).
startup_template(){
cat <<'EOF'
#! /bin/bash
set -uo pipefail
exec > /var/log/clearcote-startup.log 2>&1
echo "[$(date -u)] startup: host=$(uname -m) — MUST be x86_64"
[ "$(uname -m)" = "x86_64" ] || { echo "ABORT: host is not x86_64"; echo "FAILED_ARCH" > /var/run/cc_status; exit 1; }

apt-get update -y
apt-get install -y docker.io git python3 python3-pip zstd xz-utils unzip ca-certificates
systemctl enable --now docker
echo "docker: $(docker version --format '{{.Server.Version}}' 2>&1)"

git clone --branch __REPO_BRANCH__ __REPO_URL__ /root/cc || { echo "clone failed"; echo "FAILED_CLONE" > /var/run/cc_status; exit 1; }
cd /root/cc
# NATIVE x86-64 image build — NO --platform. (On an arm64 Mac this would be --platform
# linux/amd64 = Rosetta = the V8 snapshot corruption. Here the host IS x86-64.)
docker build -t clearcote-build-x64 . || { echo "docker build failed"; echo "FAILED_IMAGE" > /var/run/cc_status; exit 1; }
docker volume create clearcote-work

mkdir -p /root/dist
echo "[$(date -u)] running fresh-arm64.sh (the multi-hour build)..."
docker run --rm \
  -v clearcote-work:/clearcote-build \
  -v /root/cc:/clearcote:ro \
  --entrypoint bash clearcote-build-x64 \
  /clearcote/scripts/fresh-arm64.sh > /root/clearcote-gcp-build.log 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "BUILD FAILED rc=$rc — see /root/clearcote-gcp-build.log"; echo "FAILED_BUILD" > /var/run/cc_status; exit 1
fi
docker run --rm -v clearcote-work:/clearcote-build -v /root/dist:/out clearcote-build-x64 \
  bash -c 'cp -a /clearcote-build/dist/clearcote-*-linux-arm64.tar.xz /out/ 2>/dev/null; cp -a /clearcote-build/dist/SHA256SUMS.txt /out/ 2>/dev/null; true'
echo "[$(date -u)] done: $(ls -la /root/dist/ 2>&1)"
echo "OK" > /var/run/cc_status
EOF
}

case "$command" in
  provision)
    echo "### provisioning $VM ($MACHINE, $ZONE, spot=$SPOT) in project $PROJECT"
    TF=$(mktemp /tmp/cc-startup-XXXX.sh)
    startup_template > "$TF"
    python3 - "$TF" "$REPO_URL" "$REPO_BRANCH" <<'PYEOF'
import sys
path, url, branch = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
t = t.replace("__REPO_URL__", url).replace("__REPO_BRANCH__", branch)
open(path, "w").write(t)
PYEOF
    EXTRA=""
    if [ "$SPOT" = "1" ]; then EXTRA="--provisioning-model=SPOT --instance-termination-action=STOP"; fi
    gcloud compute instances create "$VM" \
      --project="$PROJECT" --zone="$ZONE" --machine-type="$MACHINE" \
      $EXTRA \
      --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
      --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-ssd \
      --scopes=cloud-platform \
      --metadata=startup-script="file://$TF"
    rm -f "$TF"
    echo
    echo "VM created. It now builds unattended (~1-2h). Track with:"
    echo "  $0 status"
    echo "  $0 fetch       # once the status marker says OK"
    echo "  $0 teardown    # when done (stops billing)"
    ;;
  status)
    echo "### VM status:"; gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT" \
      --format="value(name,status,zone)" 2>&1 | sed 's/^/  /' || true
    echo "### build status marker:"
    gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --command='cat /var/run/cc_status 2>/dev/null || echo in-progress' 2>/dev/null | sed 's/^/  /' || echo "  (not ready / ssh not up yet)"
    echo "### build log tail (last 15):"
    gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --command='tail -15 /root/clearcote-gcp-build.log 2>/dev/null || echo "  (build log not started yet)"' 2>/dev/null | sed 's/^/  /'
    ;;
  fetch)
    mkdir -p ./dist
    echo "### fetching artifact -> ./dist/"
    gcloud compute scp "$VM:/root/dist/clearcote-"*-linux-arm64.tar.xz ./dist/ --zone="$ZONE" --project="$PROJECT"
    gcloud compute scp "$VM:/root/dist/SHA256SUMS.txt" ./dist/ --zone="$ZONE" --project="$PROJECT" 2>/dev/null || true
    ls -la ./dist/
    echo "verify:  (cd dist && sha256sum -c SHA256SUMS.txt)"
    ;;
  teardown)
    echo "### tearing down $VM (stops billing)"
    gcloud compute instances delete "$VM" --zone="$ZONE" --project="$PROJECT" --quiet
    gcloud compute disks delete "$VM" --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || true
    echo "done."
    ;;
  *)
    echo "usage: $0 {provision|status|fetch|teardown}" >&2; exit 2 ;;
esac
