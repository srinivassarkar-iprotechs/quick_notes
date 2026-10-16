#!/usr/bin/env bash
#
# setup-remote-access.sh
# ---------------------------------------------------------------------------
# One-shot, Tailscale-free permanent access setup for the GPU box ("practice").
#
# Run it ON THE BOX, from the attached monitor/keyboard, as root:
#
#   git clone https://github.com/srinivassarkar-iprotechs/quick_notes.git
#   sudo bash quick_notes/setup-remote-access.sh --user gpu
#
# What it does (all idempotent):
#   1. installs + enables an SSH server (openssh) and mDNS (avahi)
#   2. installs your public key  -> password-free login
#   3. opens the local firewall for SSH (ufw / firewalld)
#   4. installs a self-healing reverse SSH tunnel to the relay (off-site reach)
#   5. prints exactly how to connect (LAN, and off-site)
#
# No Tailscale involved anywhere.
# ---------------------------------------------------------------------------
set -euo pipefail

# --------------------------------- config ----------------------------------
SSH_USER="gpu"                                                              # login user on THIS box
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNzuwl2Bwcjk++w+LhiCt4w8A3FhnU23YcYys7h3xBp mac-access"
RELAY_USER="ubuntu"                                                         # user on the always-on relay
RELAY_HOST="13.233.237.182"                                                 # relay public IP (pp-demo)
RELAY_PORT="2222"                                                           # port on the relay -> this box:22
INSTALL_TUNNEL="yes"
CREATE_USER="no"
RELAY_IDENTITY=""

# --------------------------------- helpers ---------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo bash setup-remote-access.sh [options]

  --user <name>        Login user on this box                (default: $SSH_USER)
  --create-user        Create the user if it does not exist   (default: no)
  --relay <user@host>  Always-on relay for off-site access    (default: $RELAY_USER@$RELAY_HOST)
  --port <n>           Relay port mapped to this box:22       (default: $RELAY_PORT)
  --relay-key <path>   Private key to auto-authorise the tunnel on the relay
  --no-tunnel          Skip the reverse tunnel (LAN access only)
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user)        SSH_USER="$2"; shift 2 ;;
    --create-user) CREATE_USER="yes"; shift ;;
    --relay)       RELAY_USER="${2%@*}"; RELAY_HOST="${2#*@}"; shift 2 ;;
    --port)        RELAY_PORT="$2"; shift 2 ;;
    --relay-key)   RELAY_IDENTITY="$2"; shift 2 ;;
    --no-tunnel)   INSTALL_TUNNEL="no"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash $0 ..."
command -v systemctl >/dev/null 2>&1 || die "systemd is required."

# ------------------------------ package manager ----------------------------
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
elif command -v apk     >/dev/null 2>&1; then PM=apk
else die "No supported package manager found (apt/dnf/yum/apk)."
fi

pkg_install() {
  log "Installing: $*"
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null && \
         DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}

SSHD_PKG="openssh-server"
[ "$PM" = apt ] && SSH_UNIT="ssh" || SSH_UNIT="sshd"

# ------------------------------- 1. packages -------------------------------
pkg_install "$SSHD_PKG"
[ "$PM" = apk ] && pkg_install avahi || pkg_install avahi-daemon 2>/dev/null || pkg_install avahi
if [ "$INSTALL_TUNNEL" = yes ]; then
  pkg_install autossh || warn "autossh unavailable; will fall back to plain ssh + systemd restart."
fi

# ---------------------------- 2. ssh server up -----------------------------
log "Enabling SSH server ($SSH_UNIT)"
systemctl enable --now "$SSH_UNIT" 2>/dev/null || systemctl restart "$SSH_UNIT"

# ------------------------------- 3. the user -------------------------------
if ! id "$SSH_USER" >/dev/null 2>&1; then
  if [ "$CREATE_USER" = yes ]; then
    log "Creating user '$SSH_USER'"
    useradd -m -s /bin/bash "$SSH_USER"
  else
    die "User '$SSH_USER' does not exist. Re-run with --create-user to create it."
  fi
fi
HOME_DIR="$(getent passwd "$SSH_USER" | cut -d: -f6)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "Cannot resolve home dir for '$SSH_USER'."

# --------------------------- 4. install the key ----------------------------
log "Installing your public key for '$SSH_USER'"
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$HOME_DIR/.ssh"
AUTH="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH"
grep -qF "$PUBKEY" "$AUTH" || echo "$PUBKEY" >> "$AUTH"
chown "$SSH_USER:$SSH_USER" "$AUTH"
chmod 600 "$AUTH"
chmod 700 "$HOME_DIR/.ssh"

# ------------------------------ 5. firewall --------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q active; then
  log "Opening SSH in ufw"; ufw allow 22/tcp >/dev/null || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  log "Opening SSH in firewalld"; firewall-cmd --permanent --add-service=ssh >/dev/null || true
  firewall-cmd --reload >/dev/null || true
fi

# ------------------------------- 6. mDNS -----------------------------------
systemctl enable --now avahi-daemon 2>/dev/null || systemctl enable --now avahi 2>/dev/null || true

# -------------------------- 7. reverse tunnel ------------------------------
TUNNEL_PUB=""
TUNNEL_KEY="$HOME_DIR/.ssh/relay_tunnel_ed25519"
if [ "$INSTALL_TUNNEL" = yes ]; then
  if [ ! -f "$TUNNEL_KEY" ]; then
    log "Generating tunnel key: $TUNNEL_KEY"
    ssh-keygen -t ed25519 -N "" -f "$TUNNEL_KEY" -C "box-tunnel@$(hostname)" >/dev/null
  fi
  chown "$SSH_USER:$SSH_USER" "$TUNNEL_KEY" "$TUNNEL_KEY.pub"
  chmod 600 "$TUNNEL_KEY"; chmod 644 "$TUNNEL_KEY.pub"
  TUNNEL_PUB="$(cat "$TUNNEL_KEY.pub")"

  TUNNEL_BIN="$(command -v autossh || command -v ssh)"
  log "Installing self-healing tunnel service (-> ${RELAY_USER}@${RELAY_HOST}:${RELAY_PORT})"
  cat >/etc/systemd/system/box-reverse-tunnel.service <<EOF
[Unit]
Description=Reverse SSH tunnel to relay ${RELAY_HOST}
After=network-online.target
Wants=network-online.target

[Service]
User=${SSH_USER}
Environment=AUTOSSH_GATETIME=0
ExecStart=${TUNNEL_BIN} -M 0 -NT -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i ${TUNNEL_KEY} -R ${RELAY_PORT}:localhost:22 ${RELAY_USER}@${RELAY_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now box-reverse-tunnel.service || true

  if [ -n "$RELAY_IDENTITY" ] && [ -f "$RELAY_IDENTITY" ]; then
    log "Authorising tunnel key on the relay with $RELAY_IDENTITY"
    ssh-copy-id -i "$TUNNEL_KEY.pub" -o IdentityFile="$RELAY_IDENTITY" \
      -o StrictHostKeyChecking=accept-new "${RELAY_USER}@${RELAY_HOST}" || \
      warn "Auto-authorise failed; add the key on the relay manually (see below)."
    systemctl restart box-reverse-tunnel.service || true
  fi
fi

# ------------------------------- summary -----------------------------------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOSTNAME_FQDN="$(hostname)"
MACADDR="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^$' | head -1)"

cat <<EOF

======================= DONE — access is set up =======================

  hostname : ${HOSTNAME_FQDN}
  LAN IP   : ${LAN_IP:-<unknown>}     MAC: ${MACADDR:-<unknown>}
  login    : ${SSH_USER}

  ON THE SAME WI-FI (no Tailscale needed):
      ssh ${SSH_USER}@${HOSTNAME_FQDN}.local
      ssh ${SSH_USER}@${LAN_IP}

  FROM ANYWHERE (off-site, via relay):
      ssh -J ${RELAY_USER}@${RELAY_HOST} -p ${RELAY_PORT} ${SSH_USER}@127.0.0.1
EOF

if [ "$INSTALL_TUNNEL" = yes ] && [ -z "$RELAY_IDENTITY" ]; then
  cat <<EOF

  ONE LAST STEP — authorise this box on the relay (run once, on
  ${RELAY_USER}@${RELAY_HOST}):

      echo '${TUNNEL_PUB}' >> ~/.ssh/authorized_keys
      chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys

  Re-run this script with --relay-key <path> to do that part automatically.
EOF
fi

cat <<EOF

  TIP: lock the LAN IP in your router (DHCP -> Address Reservation) using
       the MAC above so it never changes.

  Verify the tunnel:   systemctl status box-reverse-tunnel
=======================================================================
EOF
