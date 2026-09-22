#!/usr/bin/env bash
# imd-node.sh — set up and manage IdentityMD worker nodes on a fresh Linux VPS.
#
# Unofficial helper that automates the steps in README.md. Run it as root on the
# server. One unprivileged user per NFT ("seat"): seat 1 = user imd1, seat 2 = imd2 …
#
#   imd-node.sh setup   [--seats N] [--runtime codex|claude] [--no-foundry]
#                       [--harden-ssh] [--no-firewall] [--no-userns-fix]
#   imd-node.sh login   <seat>                 sign the seat's CLI in to your subscription
#   imd-node.sh check   <seat>                 prove the sandbox can run commands, then imd doctor
#   imd-node.sh pair    <seat>                 start the worker in the foreground to pair the NFT
#   imd-node.sh service <seat> [--concurrency N] [--no-auto-update]
#   imd-node.sh status                         every seat at a glance
#   imd-node.sh logs    <seat>                 follow a seat's log (Ctrl-C exits the viewer only)
#
# The wallet never touches this server: pairing and the ERC-8004 registration are
# signed in a browser on your own computer.

set -euo pipefail

CONF=/etc/imd-node.conf
DIST_ROOT=/opt/imd-node/dist
USER_PREFIX="${IMD_USER_PREFIX:-imd}"
RELEASES="https://github.com/Identity-md/worker/releases/latest/download"

# ---------------------------------------------------------------- helpers

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run this as root (sudo -i first)"; }

load_conf() {
  SEATS=1; RUNTIME=codex
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
  return 0
}

save_conf() {
  cat >"$CONF" <<EOF
# written by imd-node.sh
SEATS=$SEATS
RUNTIME=$RUNTIME
EOF
  chmod 644 "$CONF"
}

seat_user() {
  local seat="${1:-}"
  [[ "$seat" =~ ^[0-9]+$ ]] && [ "$seat" -ge 1 ] || die "seat must be a number like 1 or 2"
  local u="${USER_PREFIX}${seat}"
  id "$u" >/dev/null 2>&1 || die "user $u does not exist; run: imd-node.sh setup --seats $seat"
  printf '%s' "$u"
}

# run a command as a seat user in a login shell, with its systemd user session reachable
as_user() {
  local u="$1"; shift
  local uid; uid="$(id -u "$u")"
  runuser -l "$u" -c "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus; $*"
}

# the NFT a seat is paired to, read from its config (never prints the device key)
seat_token() {
  as_user "$1" 'node -e "try{const c=require(process.env.HOME+\"/.identitymd/config.json\");process.stdout.write(c.tokenId?String(c.tokenId):\"\")}catch(e){}"' 2>/dev/null || true
}

all_seats() {
  getent passwd | awk -F: -v p="^${USER_PREFIX}[0-9]+$" '$1 ~ p {print $1}' | sort -V
}

# ---------------------------------------------------------------- setup steps

check_os() {
  [ -r /etc/os-release ] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ok "$PRETTY_NAME" ;;
    *) warn "untested OS ($PRETTY_NAME); continuing, but expect differences" ;;
  esac
  command -v systemctl >/dev/null || die "systemd is required"
  local mem_mb; mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  local disk_gb; disk_gb=$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')
  ok "RAM ${mem_mb} MB, free disk ${disk_gb} GB"
  [ "$mem_mb" -ge 1800 ] || warn "under 2 GB RAM: Foundry builds may run out of memory"
  [ "$disk_gb" -ge 10 ] || warn "under 10 GB free disk: task workspaces need room"
}

install_packages() {
  say "System packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  NEEDRESTART_MODE=a apt-get install -y -qq ca-certificates curl git build-essential ufw unattended-upgrades >/dev/null 2>&1
  ok "git $(git --version | awk '{print $3}'), curl, build tools, ufw"
}

setup_swap() {
  local swap_kb; swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
  if [ "${swap_kb:-0}" -gt 0 ]; then ok "swap already present"; return; fi
  say "Swap (4 GB) so Foundry builds do not get OOM-killed"
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  ok "4 GB swap enabled"
}

setup_firewall() {
  say "Firewall: nothing inbound except SSH (the worker only dials out)"
  local port; port=$( (sshd -T 2>/dev/null || true) | awk '/^port / && !seen {print $2; seen=1}')
  port="${port:-22}"
  ufw allow "${port}/tcp" >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  ok "ufw active, SSH port ${port} allowed"
}

harden_ssh() {
  say "SSH: keys only"
  if ! [ -s /root/.ssh/authorized_keys ]; then
    warn "/root/.ssh/authorized_keys is empty; not disabling passwords (you would lock yourself out)"
    return
  fi
  cat >/etc/ssh/sshd_config.d/10-imd-node.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    ok "password login disabled"
  else
    rm -f /etc/ssh/sshd_config.d/10-imd-node.conf
    warn "sshd rejected the config; left SSH unchanged"
  fi
}

fix_userns() {
  local key=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
  if [ ! -r "$key" ]; then ok "no AppArmor user-namespace restriction on this kernel"; return; fi
  if [ "$(cat "$key")" = "0" ]; then ok "user namespaces already allowed (sandbox can run)"; return; fi
  say "Allowing unprivileged user namespaces (Codex's bwrap sandbox needs them)"
  echo 'kernel.apparmor_restrict_unprivileged_userns = 0' >/etc/sysctl.d/60-imd-userns.conf
  sysctl -q --system
  ok "kernel.apparmor_restrict_unprivileged_userns = $(cat "$key")"
}

install_node() {
  local major=0
  command -v node >/dev/null && major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "$major" -ge 22 ]; then ok "node $(node -v)"; return; fi
  say "Node.js 24 (NodeSource)"
  local tmp; tmp=$(mktemp)
  curl -fsSL https://deb.nodesource.com/setup_24.x -o "$tmp"
  bash "$tmp" >/dev/null 2>&1
  rm -f "$tmp"
  NEEDRESTART_MODE=a apt-get install -y -qq nodejs >/dev/null 2>&1
  ok "node $(node -v), npm $(npm -v)"
}

fetch_worker() {
  say "Worker release (checksum-verified)"
  local tag; tag=$( (curl -fsSL "$RELEASES/build.json" || true) | grep -o '"daemonVersion": *"[^"]*"' | cut -d'"' -f4 || true)
  [ -n "$tag" ] || die "could not read the latest release from GitHub"
  WORKER_DIR="$DIST_ROOT/$tag"
  if [ -f "$WORKER_DIR/.verified" ]; then ok "worker $tag already downloaded"; return; fi
  rm -rf "$WORKER_DIR" && mkdir -p "$WORKER_DIR"
  (cd "$WORKER_DIR" \
    && curl -fsSLO "$RELEASES/identitymd-worker.tgz" -O "$RELEASES/SHA256SUMS" \
    && sha256sum -c SHA256SUMS >/dev/null) || die "worker checksum did not verify; nothing installed"
  touch "$WORKER_DIR/.verified"
  chmod -R a+rX "$DIST_ROOT"
  ok "worker $tag, SHA-256 OK"
}

create_seat() {
  local u="$1"
  if id "$u" >/dev/null 2>&1; then
    ok "user $u exists"
  else
    adduser --disabled-password --gecos "" "$u" >/dev/null
    ok "created user $u (no sudo)"
  fi
  chmod 700 "/home/$u"
  loginctl enable-linger "$u"

  local path_line='export PATH="$HOME/.npm-global/bin:$HOME/.foundry/bin:$HOME/.local/bin:$PATH"'
  for f in .profile .bashrc; do
    local file="/home/$u/$f"
    touch "$file"; chown "$u:$u" "$file"
    grep -qF '.npm-global/bin' "$file" && continue
    if [ -s "$file" ]; then sed -i "1i $path_line" "$file"; else printf '%s\n' "$path_line" >"$file"; fi
  done

  local runtime_pkg="@openai/codex"
  [ "$RUNTIME" = claude ] && runtime_pkg="@anthropic-ai/claude-code"
  as_user "$u" "npm config set prefix \$HOME/.npm-global \
    && npm install --global --ignore-scripts --no-audit --no-fund '$WORKER_DIR/identitymd-worker.tgz' >/dev/null 2>&1 \
    && npm install --global --no-audit --no-fund $runtime_pkg >/dev/null 2>&1" \
    || die "npm install failed for $u"
  ok "$u: $(as_user "$u" 'imd help 2>/dev/null | head -1')"
  ok "$u: $RUNTIME $(as_user "$u" "$RUNTIME --version 2>/dev/null | head -1")"

  if [ "$WITH_FOUNDRY" = 1 ]; then
    if as_user "$u" 'command -v forge' >/dev/null 2>&1; then
      ok "$u: $(as_user "$u" 'forge --version | head -1')"
    else
      as_user "$u" 'curl -fsSL https://foundry.paradigm.xyz | bash >/dev/null 2>&1 && ~/.foundry/bin/foundryup >/dev/null 2>&1' \
        || warn "$u: Foundry install failed; contract skills will not be offered"
      as_user "$u" 'command -v forge' >/dev/null 2>&1 && ok "$u: $(as_user "$u" 'forge --version | head -1')"
    fi
  fi
}

install_cleanup() {
  cat >/etc/cron.daily/imd-clean <<EOF
#!/bin/sh
# imd-node.sh: the worker never deletes finished task workspaces; prune ones older than 2 days
for h in /home/${USER_PREFIX}[0-9]*; do
  [ -d "\$h/.identitymd/work" ] && find "\$h/.identitymd/work" -mindepth 1 -maxdepth 1 -type d -mtime +2 -exec rm -rf {} +
done
exit 0
EOF
  chmod 755 /etc/cron.daily/imd-clean
  ok "daily cleanup of old task workspaces (/etc/cron.daily/imd-clean)"
}

cmd_setup() {
  need_root; load_conf
  local harden=0 firewall=1 userns=1
  WITH_FOUNDRY=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --seats) SEATS="${2:-}"; shift ;;
      --runtime) RUNTIME="${2:-}"; shift ;;
      --no-foundry) WITH_FOUNDRY=0 ;;
      --harden-ssh) harden=1 ;;
      --no-firewall) firewall=0 ;;
      --no-userns-fix) userns=0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ "$SEATS" =~ ^[0-9]+$ ]] && [ "$SEATS" -ge 1 ] && [ "$SEATS" -le 16 ] || die "--seats must be 1..16"
  case "$RUNTIME" in codex|claude) ;; *) die "--runtime must be codex or claude" ;; esac

  say "Checking the machine"; check_os
  install_packages
  setup_swap
  [ "$firewall" = 1 ] && setup_firewall
  [ "$harden" = 1 ] && harden_ssh
  [ "$userns" = 1 ] && fix_userns
  install_node
  fetch_worker
  say "Seats: $SEATS × $RUNTIME"
  local i
  for i in $(seq 1 "$SEATS"); do create_seat "${USER_PREFIX}${i}"; done
  install_cleanup
  save_conf

  cat <<EOF

Setup done. For each seat, in this order:

  1. imd-node.sh login 1      sign the CLI in (a code you confirm in your own browser)
  2. imd-node.sh check 1      prove the sandbox can run commands
  3. imd-node.sh pair 1       pair the NFT in your browser, register it, then Ctrl-C
  4. imd-node.sh service 1    run it in the background, at boot, with auto-update

Seats can share one subscription account; each seat needs its own NFT.
EOF
}

# ---------------------------------------------------------------- per-seat commands

cmd_login() {
  need_root; load_conf
  local u; u=$(seat_user "${1:-}")
  if [ "$RUNTIME" = codex ]; then
    say "$u: Codex device login. Open the printed link on your computer and enter the code."
    as_user "$u" 'codex login --device-auth'
    as_user "$u" 'codex login status'
  else
    say "$u: starting Claude Code. Type /login, finish in your browser, then /exit."
    as_user "$u" 'claude'
  fi
}

cmd_check() {
  need_root; load_conf
  local u; u=$(seat_user "${1:-}")
  say "$u: sandbox smoke test (spends a few thousand tokens)"
  local out rc=0
  if [ "$RUNTIME" = codex ]; then
    out=$(as_user "$u" 'd=$(mktemp -d "$HOME/.imd-node-check.XXXX") && cd "$d" \
      && timeout 180 codex exec --skip-git-repo-check --sandbox workspace-write \
         "Run this exact shell command and nothing else: echo imd-sandbox-ok > probe.txt. Then reply DONE." </dev/null >out.log 2>&1; \
      cat probe.txt 2>/dev/null; echo "---"; tail -20 out.log; cd; rm -rf "$d"') || rc=$?
  else
    out=$(as_user "$u" 'd=$(mktemp -d "$HOME/.imd-node-check.XXXX") && cd "$d" \
      && timeout 180 claude -p "Run this exact shell command and nothing else: echo imd-sandbox-ok > probe.txt. Then reply DONE." \
         --permission-mode acceptEdits --allowedTools "Bash(echo:*)" </dev/null >out.log 2>&1; \
      cat probe.txt 2>/dev/null; echo "---"; tail -20 out.log; cd; rm -rf "$d"') || rc=$?
  fi
  if [ "$(head -n 1 <<<"$out")" = "imd-sandbox-ok" ]; then
    ok "the agent ran a shell command and wrote a file"
  else
    printf '%s\n' "$out" | sed -n '/^---$/,$p' | tail -n +2 | sed 's/^/    /'
    if grep -q 'setting up uid map' <<<"$out"; then
      die "sandbox blocked by AppArmor. Fix: imd-node.sh setup --seats $SEATS (it applies the userns fix), then check again"
    elif grep -qi -E 'not logged in|login|unauthori' <<<"$out"; then
      die "the CLI is not signed in. Run: imd-node.sh login ${1}"
    elif grep -qi -E 'usage limit|rate limit' <<<"$out"; then
      die "the subscription is at its usage limit; try again after it resets"
    fi
    die "the agent could not run a command (exit $rc). Do not start the worker until this passes"
  fi
  say "$u: imd doctor"
  as_user "$u" "imd doctor --runtime $RUNTIME" || true
}

cmd_pair() {
  need_root; load_conf
  local u; u=$(seat_user "${1:-}")
  cat <<EOF
==> $u: starting the worker in the foreground.
    1. Open the api.imd.fun/pair link it prints, on YOUR computer, with the wallet that holds the NFT.
    2. Pick the NFT for this seat and sign. If it asks, send the ERC-8004 register transaction
       (0 ETH, gas only; the recipient should be the IdentityMD adapter shown on the page).
    3. When the log says "admitted", press Ctrl-C and run: imd-node.sh service ${1}
EOF
  as_user "$u" "imd start --runtime $RUNTIME --concurrency 1" || true
}

cmd_service() {
  need_root; load_conf
  local seat="${1:-}"; shift || true
  local u; u=$(seat_user "$seat")
  local conc=1 auto="--auto-update"
  while [ $# -gt 0 ]; do
    case "$1" in
      --concurrency) conc="${2:-}"; shift ;;
      --no-auto-update) auto="" ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ "$conc" =~ ^[1-4]$ ]] || die "--concurrency must be 1..4"
  [ -n "$(seat_token "$u")" ] || die "$u is not paired yet. Run: imd-node.sh pair $seat"
  say "$u: installing the background service (concurrency $conc${auto:+, auto-update})"
  as_user "$u" "imd service uninstall >/dev/null 2>&1; imd service install --boot $auto --runtime $RUNTIME --concurrency $conc"
  sleep 20
  as_user "$u" 'journalctl --user -u identitymd-worker --since "-1min" --no-pager -o cat | grep -E "admitted|refus|error|unregistered" | tail -3' || true
}

cmd_status() {
  need_root; load_conf
  local u any=0
  for u in $(all_seats); do
    any=1
    local token active version alive
    token=$(seat_token "$u")
    active=$(as_user "$u" 'systemctl --user is-active identitymd-worker 2>/dev/null' || true)
    version=$( (as_user "$u" 'imd help 2>/dev/null | head -1' || true) | grep -o 'v[0-9][^)]*' || true)
    alive=$( (as_user "$u" 'journalctl --user -u identitymd-worker --no-pager -o cat 2>/dev/null | grep " alive " | tail -1' || true) | sed 's/^[^ ]* //')
    printf '%-6s token %-5s %-9s %-18s %s\n' "$u" "${token:--}" "${active:-inactive}" "${version:--}" "${alive:-}"
  done
  [ "$any" = 1 ] || echo "no seats yet. Run: imd-node.sh setup --seats 1"
}

cmd_logs() {
  need_root
  local u; u=$(seat_user "${1:-}")
  as_user "$u" 'journalctl --user -u identitymd-worker -f -o cat'
}

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    setup) cmd_setup "$@" ;;
    login) cmd_login "$@" ;;
    check) cmd_check "$@" ;;
    pair) cmd_pair "$@" ;;
    service) cmd_service "$@" ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $cmd (see: imd-node.sh help)" ;;
  esac
}

main "$@"
