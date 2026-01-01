#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo -e "\n[ERROR] ${BASH_SOURCE[0]}:${LINENO} failed while executing: ${BASH_COMMAND}" >&2' ERR

APP="Homey Self-Hosted Server"
LXC_HOSTNAME="${LXC_HOSTNAME:-homey-shs}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE_FILE="${TEMPLATE_FILE:-debian-13-standard_13.1-2_amd64.tar.zst}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local}"
DISK_SIZE_GB="${DISK_SIZE_GB:-16}"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
BRIDGE="${BRIDGE:-vmbr0}"
PASSWORD="${PASSWORD:-homey}"
TAGS="${TAGS:-homey;docker}"
CTID="${CTID:-}"
TEMPLATE_PATH=""

msg_info() { echo -e "  [INFO] $*"; }
msg_ok() { echo -e "  [ OK ] $*"; }
msg_warn() { echo -e "  [WARN] $*"; }
msg_error() { echo -e "  [FAIL] $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Run this script as root on the Proxmox host."
    exit 1
  fi
  if ! command -v pct >/dev/null 2>&1; then
    msg_error "pct command not found. This script must run on Proxmox VE."
    exit 1
  fi
}

initialize_defaults() {
  local default_ctid
  default_ctid=$(pvesh get /cluster/nextid)
  CTID="${CTID:-$default_ctid}"
  TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"
}

ensure_template() {
  if pveam list "$TEMPLATE_STORAGE" | awk 'NR>2 {print $2}' | grep -Fxq "$TEMPLATE_FILE"; then
    msg_ok "Template ${TEMPLATE_FILE} already present in ${TEMPLATE_STORAGE}"
  else
    msg_info "Downloading ${TEMPLATE_FILE} to ${TEMPLATE_STORAGE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
    msg_ok "Template downloaded"
  fi
}

create_container() {
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_error "Container ID ${CTID} already exists. Set CTID to an unused value and retry."
    exit 1
  fi

  msg_info "Creating LXC ${CTID} (${APP})"
  pct create "$CTID" "$TEMPLATE_PATH" \
    -arch amd64 \
    -ostype debian \
    -hostname "$LXC_HOSTNAME" \
    -tags "$TAGS" \
    -onboot 1 \
    -cores "$CPU_CORES" \
    -memory "$RAM_MB" \
    -swap "$SWAP_MB" \
    -storage "$ROOTFS_STORAGE" \
    -rootfs "${ROOTFS_STORAGE}:${DISK_SIZE_GB}" \
    -password "$PASSWORD" \
    -net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,type=veth" \
    -unprivileged 1 \
    -features nesting=1 \
    -cmode console >/dev/null
  msg_ok "Container ${CTID} created (password: ${PASSWORD})"
}

start_container() {
  msg_info "Starting LXC ${CTID}"
  pct start "$CTID"
  for i in {1..20}; do
    sleep 3
    if pct exec "$CTID" -- bash -c "ping -c1 -W1 1.1.1.1 >/dev/null 2>&1"; then
      msg_ok "Network connectivity confirmed"
      return
    fi
  done
  msg_warn "Unable to verify outbound network connectivity. Continuing anyway."
}

configure_homey_shs() {
  msg_info "Installing Docker and Homey SHS inside the container"
  pct exec "$CTID" -- bash <<'IN_CONTAINER'
set -Eeuo pipefail
apt-get update
apt-get install -y curl sudo jq ca-certificates gnupg

mkdir -p /etc/docker
cat <<'DOCKER_JSON' >/etc/docker/daemon.json
{
  "log-driver": "journald"
}
DOCKER_JSON

sh <(curl -fsSL https://get.docker.com)

HOMEY_DATA_DIR="/root/.homey-shs"
DEPLOY_SCRIPT="/usr/local/bin/homey-shs.sh"
SERVICE_PATH="/etc/systemd/system/homey-shs.service"

mkdir -p "$HOMEY_DATA_DIR"
cat <<'DEPLOY_SCRIPT' >"$DEPLOY_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail
IMAGE="ghcr.io/athombv/homey-shs"
CONTAINER="homey-shs"
DATA_DIR="/root/.homey-shs"
mkdir -p "$DATA_DIR"
if ! docker pull "$IMAGE"; then
  echo "[homey-shs] Warning: docker pull failed; continuing with cached image if available" >&2
fi
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run \
  --name="$CONTAINER" \
  --network host \
  --privileged \
  --detach \
  --restart unless-stopped \
  --volume "$DATA_DIR":/homey/user/ \
  "$IMAGE"
DEPLOY_SCRIPT
chmod +x "$DEPLOY_SCRIPT"

cat <<SERVICE_UNIT >"$SERVICE_PATH"
[Unit]
Description=Homey Self-Hosted Server Container
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$DEPLOY_SCRIPT

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

systemctl daemon-reload
systemctl enable --now homey-shs.service
IN_CONTAINER
  msg_ok "Homey SHS deployment complete"
}

print_summary() {
  local ip_output ip_status ip_addr
  ip_output=$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>&1)
  ip_status=$?
  if [[ $ip_status -eq 0 ]]; then
    ip_addr=$(awk '{print $4}' <<<"$ip_output" | cut -d/ -f1)
  else
    ip_addr="unknown"
    msg_warn "Unable to read IP address (pct exec output: $ip_output)"
  fi

  echo -e "\n${APP} (${CTID}) is ready."
  echo -e "  Hostname.    : $LXC_HOSTNAME"
  echo -e "  IP           : ${ip_addr}"
  echo -e "  SSH Username : root"
  echo -e "  SSH Password : $PASSWORD"
  echo -e "  HTTP Address : http://${ip_addr}:4859"
}

require_root
initialize_defaults
ensure_template
create_container
start_container
configure_homey_shs
print_summary
