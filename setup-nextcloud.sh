#!/usr/bin/env bash
#
# Copyright (C) 2026 Morphius.inc — All rights reserved.
# Developed by Morphius.inc
#
# setup-nextcloud.sh
#
# One-shot bring-up of a Nextcloud AIO server on a fresh Ubuntu 22.04/24.04 VM.
# Interactive: asks config questions up front. Re-runnable: already-done phases
# are skipped automatically.
#
# Phases:
#   1. Base tidy        apt upgrade, ufw/fail2ban/unattended-upgrades/qemu-guest-agent,
#                       hostname, timezone, MOTD cleanup, journald caps.
#   2. Storage          Adapts to the disks present (1-N HDDs and/or SSDs).
#                       HDDs -> data tier (/mnt/storage, xfs).
#                       SSDs -> hot tier (/var/lib/docker, ext4).
#                       RAID level picked per tier: 1->single, 2->RAID1, 3->RAID5, 4+->RAID6.
#                       If only one kind present, hot tier shares the data tier filesystem.
#                       DESTRUCTIVE for non-OS disks. Requires interactive 'NUKE' confirm.
#   3. Docker CE        Official Docker repo, daemon.json with log rotation + live-restore.
#   4. Nextcloud AIO    Mastercontainer in reverse-proxy mode; UFW gated to LAN + proxy IP.
#
# Modes:
#   - internet (default for most users): fronted by an existing reverse proxy at $PROXY_IP
#     that terminates TLS for $DOMAIN. UFW allows 11000/tcp from $PROXY_IP only,
#     8080/tcp from the detected LAN only.
#   - lan: the server is reachable only on your LAN, no external proxy. AIO is told to
#     skip domain validation; you'll hit it at https://<ip>:8080 and configure a local
#     hostname yourself.
#
# Run as:
#   sudo bash setup-nextcloud.sh
#
# Non-interactive (scripted) usage — set env vars to skip prompts:
#   MODE=internet|lan
#   HOSTNAME_SHORT=nextcloud
#   HOSTNAME_FQDN=nextcloud.home.lan
#   TIMEZONE=Europe/Amsterdam
#   LAN_CIDR=192.168.1.0/24
#   DOMAIN=cloud.example.com               (internet mode)
#   PROXY_IP=192.168.1.10                  (internet mode)
#   DOCKER_USER=alice
#   CONFIRM_NUKE=yes                       (bypass 'NUKE' prompt for storage phase)
#   AUTO_YES=1                             (bypass the summary confirmation prompt)

set -euo pipefail
shopt -s nullglob

# ============================================================================
# Helpers — colours, logging, progress bar, run_patient
# ============================================================================

if [[ -t 1 ]]; then
  C_CY=$'\033[1;36m'; C_YE=$'\033[1;33m'; C_RD=$'\033[1;31m'; C_GR=$'\033[1;32m'
  C_MA=$'\033[1;35m'; C_NO=$'\033[0m'
else
  C_CY=''; C_YE=''; C_RD=''; C_GR=''; C_MA=''; C_NO=''
fi

banner()  { printf '\n%s================================================%s\n' "$C_MA" "$C_NO"
            printf '%s %s %s\n'                                           "$C_MA" "$1" "$C_NO"
            printf '%s================================================%s\n' "$C_MA" "$C_NO"; }
section() { printf '\n%s== %s ==%s\n' "$C_CY" "$1" "$C_NO"; }
info()    { printf '%s[info]%s %s\n' "$C_GR" "$C_NO" "$*"; }
warn()    { printf '%s[warn]%s %s\n' "$C_YE" "$C_NO" "$*" >&2; }
die()     { printf '%s[abort]%s %s\n' "$C_RD" "$C_NO" "$*" >&2; exit 1; }

fmt_sec() {
  local s=$1
  if (( s < 60 )); then printf '%ds' "$s"
  else printf '%dm%02ds' $((s / 60)) $((s % 60))
  fi
}

# Time-based progress bar (tool has no real % — we estimate).
draw_bar() {
  local elapsed=$1 est=$2
  local width=30
  local pct=$(( est > 0 ? elapsed * 100 / est : 0 ))
  (( pct > 100 )) && pct=100
  local fill=$(( pct * width / 100 ))
  local done_part empty_part
  done_part=$(printf '%*s' "$fill" '' | tr ' ' '=')
  empty_part=$(printf '%*s' $((width - fill)) '' | tr ' ' '.')
  if (( elapsed <= est )); then
    printf '[%s%s] %3d%%  %s / est %s' \
      "$done_part" "$empty_part" "$pct" "$(fmt_sec "$elapsed")" "$(fmt_sec "$est")"
  else
    printf '[%s%s] >100%% elapsed %s (est was %s — running long)' \
      "$done_part" "$empty_part" "$(fmt_sec "$elapsed")" "$(fmt_sec "$est")"
  fi
}

# run_patient <label> <est_seconds> -- <cmd>...
run_patient() {
  local label="$1" est="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  info "Starting: $label (est $(fmt_sec "$est"))."
  local start pid tick elapsed rc total print_every
  start=$(date +%s)
  "$@" &
  pid=$!
  tick=0
  if   (( est < 30 ));  then print_every=5
  elif (( est < 180 )); then print_every=10
  else                       print_every=20
  fi
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    tick=$((tick + 2))
    if (( tick % print_every == 0 )); then
      elapsed=$(($(date +%s) - start))
      info "  $(draw_bar "$elapsed" "$est")  ($label)"
    fi
  done
  if ! wait "$pid"; then rc=$?; else rc=0; fi
  total=$(($(date +%s) - start))
  info "Finished: $label in $(fmt_sec "$total") (exit $rc)"
  return $rc
}

ask() {
  # ask <var_name> <prompt> <default>
  local var="$1" prompt="$2" default="${3:-}"
  local existing="${!var:-}"
  if [[ -n $existing ]]; then
    info "$var = $existing  (from env)"
    return 0
  fi
  local shown="$prompt"
  [[ -n $default ]] && shown="$prompt [$default]"
  local answer
  read -r -p "$shown: " answer
  [[ -z $answer && -n $default ]] && answer="$default"
  [[ -z $answer ]] && die "$var is required."
  printf -v "$var" '%s' "$answer"
}

# ============================================================================
# Privilege + logging
# ============================================================================

[[ $EUID -eq 0 ]] || die "Run with: sudo bash $0"
LOG_FILE="/var/log/setup-nextcloud-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'die "Error on line $LINENO (exit $?). See $LOG_FILE"' ERR

banner "Nextcloud AIO setup"
info "Log: $LOG_FILE"
info "Started: $(date -Is)"

# ============================================================================
# State detection — figure out what's already done
# ============================================================================

section "Detecting current state"

STATE_TIDY_DONE=0
STATE_STORAGE_DONE=0
STATE_DOCKER_DONE=0
STATE_AIO_DONE=0

if dpkg -l qemu-guest-agent ufw fail2ban unattended-upgrades 2>/dev/null | grep -qE '^ii +qemu-guest-agent'; then
  STATE_TIDY_DONE=1
fi
# Storage is "done" if /mnt/storage is mounted, regardless of RAID level or whether a
# separate hot tier exists. Docker data-root is detected separately below.
if findmnt -n /mnt/storage >/dev/null 2>&1; then
  STATE_STORAGE_DONE=1
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  STATE_DOCKER_DONE=1
fi
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx nextcloud-aio-mastercontainer; then
  STATE_AIO_DONE=1
fi

# Where Docker's data-root lives (or should live, if storage hasn't run yet).
# phase_storage may override this; phase_docker reads it to write daemon.json.
if findmnt -n /var/lib/docker >/dev/null 2>&1; then
  DOCK_DATA_ROOT="/var/lib/docker"
elif [[ -d /mnt/storage/docker ]]; then
  DOCK_DATA_ROOT="/mnt/storage/docker"
else
  DOCK_DATA_ROOT="/var/lib/docker"
fi

info "Phase 1 (base tidy)    : $((( STATE_TIDY_DONE    == 1 )) && echo 'already done, will skip' || echo 'will run')"
info "Phase 2 (storage)      : $((( STATE_STORAGE_DONE == 1 )) && echo 'already done, will skip' || echo 'will run (DESTRUCTIVE)')"
info "Phase 3 (Docker CE)    : $((( STATE_DOCKER_DONE  == 1 )) && echo 'already done, will skip' || echo 'will run')"
info "Phase 4 (Nextcloud AIO): $((( STATE_AIO_DONE     == 1 )) && echo 'already done, will skip' || echo 'will run')"

# ============================================================================
# Interactive config
# ============================================================================

section "Configuration"

# Mode
if [[ -z "${MODE:-}" ]]; then
  echo
  echo "Access mode:"
  echo "  1) internet  - reachable at a public domain via an existing reverse proxy"
  echo "  2) lan       - LAN-only, no external proxy, skip domain validation"
  read -r -p "Choose [1/2]: " answer
  case "$answer" in
    1|internet) MODE=internet ;;
    2|lan)      MODE=lan ;;
    *)          die "Invalid choice." ;;
  esac
fi
info "MODE=$MODE"

# --- Auto-detect defaults from the running system; user confirms each one. ---

# Hostname: from `hostname`
CURRENT_HOST=$(hostname)

# FQDN: prefer the /etc/hosts 127.0.1.1 line (Ubuntu's convention), fall back to `hostname -f`.
# If all we can get is the short name or 'localhost', synthesize a sane local domain.
CURRENT_FQDN=$(awk '$1=="127.0.1.1"{for(i=2;i<=NF;i++) if ($i ~ /\./){print $i; exit}}' /etc/hosts 2>/dev/null || true)
[[ -z $CURRENT_FQDN ]] && CURRENT_FQDN=$(hostname -f 2>/dev/null || true)
if [[ -z $CURRENT_FQDN || "$CURRENT_FQDN" == "localhost" || "$CURRENT_FQDN" == "$CURRENT_HOST" ]]; then
  CURRENT_FQDN="$CURRENT_HOST.local"
fi

# Timezone: from systemd-timedated (already set on most Ubuntu images)
CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Europe/Amsterdam")
[[ -z $CURRENT_TZ || "$CURRENT_TZ" == "Etc/UTC" ]] && CURRENT_TZ="Europe/Amsterdam"

# LAN CIDR: derive from the default-route interface's IPv4.
# Example `ip route` line: "default via 192.168.1.1 dev eth0 ..."  -> iface, then get IP/mask.
CURRENT_LAN_CIDR=""
_default_iface=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [[ -n $_default_iface ]]; then
  # Example `ip addr` output: "inet 192.168.1.50/24 brd ..." -> "192.168.1.50/24"
  _ip_cidr=$(ip -4 -o addr show dev "$_default_iface" 2>/dev/null | awk '{print $4; exit}')
  if [[ $_ip_cidr =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
    # Compute network base for the mask (handles /24, /16, /8 cleanly; others best-effort).
    _a=${BASH_REMATCH[1]} _b=${BASH_REMATCH[2]} _c=${BASH_REMATCH[3]} _d=${BASH_REMATCH[4]} _m=${BASH_REMATCH[5]}
    case "$_m" in
      24) CURRENT_LAN_CIDR="$_a.$_b.$_c.0/24" ;;
      16) CURRENT_LAN_CIDR="$_a.$_b.0.0/16"   ;;
      8)  CURRENT_LAN_CIDR="$_a.0.0.0/8"      ;;
      *)  CURRENT_LAN_CIDR="$_a.$_b.$_c.$_d/$_m" ;;
    esac
  fi
fi
[[ -z $CURRENT_LAN_CIDR ]] && CURRENT_LAN_CIDR="192.168.1.0/24"

echo
info "Detected from this system (press Enter at each prompt to accept):"
info "  hostname : $CURRENT_HOST"
info "  fqdn     : $CURRENT_FQDN"
info "  timezone : $CURRENT_TZ"
info "  LAN CIDR : $CURRENT_LAN_CIDR  (via $_default_iface)"
echo

ask HOSTNAME_SHORT "Short hostname"                           "$CURRENT_HOST"
ask HOSTNAME_FQDN  "FQDN / local name"                        "$CURRENT_FQDN"
ask TIMEZONE       "Timezone"                                 "$CURRENT_TZ"
ask LAN_CIDR       "LAN CIDR (allowed for admin UI)"          "$CURRENT_LAN_CIDR"
ask DOCKER_USER    "Non-root user to add to 'docker' group"   "${SUDO_USER:-}"

# Internet-specific
if [[ "$MODE" == "internet" ]]; then
  ask DOMAIN   "Public domain for Nextcloud (e.g. cloud.example.com)" ""
  ask PROXY_IP "Reverse proxy LAN IP (e.g. 192.168.1.10, upstream allowed on port 11000)" ""
else
  DOMAIN="${DOMAIN:-$HOSTNAME_FQDN}"
  PROXY_IP="${PROXY_IP:-}"
  info "DOMAIN=$DOMAIN (LAN hostname)"
  info "Domain validation will be SKIPPED in AIO."
fi

echo
banner "Summary — will use these values"
printf '  Mode             : %s\n' "$MODE"
printf '  Hostname         : %s (%s)\n' "$HOSTNAME_SHORT" "$HOSTNAME_FQDN"
printf '  Timezone         : %s\n' "$TIMEZONE"
printf '  LAN CIDR         : %s\n' "$LAN_CIDR"
printf '  Docker user      : %s\n' "$DOCKER_USER"
printf '  Domain           : %s\n' "$DOMAIN"
[[ "$MODE" == "internet" ]] && printf '  Proxy IP         : %s\n' "$PROXY_IP"
echo

if [[ -z "${AUTO_YES:-}" ]]; then
  read -r -p "Proceed with these values? [y/N]: " go
  [[ "$go" =~ ^[Yy] ]] || die "Cancelled by user."
fi

# ============================================================================
# Phase 1 — Base tidy
# ============================================================================

phase_tidy() {
  banner "Phase 1/4 — Base tidy"

  section "Update, upgrade, install base packages"
  info "This installs: ufw, fail2ban, unattended-upgrades, qemu-guest-agent."
  info "Apt upgrade can take 2-15 min depending on how current the image is."
  export DEBIAN_FRONTEND=noninteractive
  if [[ -f /etc/needrestart/needrestart.conf ]]; then
    sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
  fi
  run_patient "apt update"   30 -- apt-get update
  run_patient "apt upgrade" 600 -- apt-get -y upgrade
  run_patient "install base packages" 180 -- \
    apt-get -y install ufw fail2ban unattended-upgrades qemu-guest-agent
  systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
  apt-get -y autoremove

  section "Hostname"
  hostnamectl set-hostname "$HOSTNAME_SHORT"
  sed -i '/^127\.0\.1\.1/d' /etc/hosts
  echo "127.0.1.1  $HOSTNAME_FQDN $HOSTNAME_SHORT" >> /etc/hosts
  info "Hostname now: $(hostname)  FQDN: $(hostname -f 2>/dev/null || echo $HOSTNAME_FQDN)"

  section "Timezone & NTP"
  timedatectl set-timezone "$TIMEZONE"
  timedatectl set-ntp true
  systemctl restart systemd-timesyncd
  info "$(timedatectl | head -3)"

  section "MOTD cleanup"
  for f in 10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status 91-release-upgrade; do
    [[ -f /etc/update-motd.d/$f ]] && chmod -x "/etc/update-motd.d/$f" && info "disabled: $f"
  done
  systemctl disable --now motd-news.timer 2>/dev/null || true
  [[ -f /etc/default/motd-news ]] && sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news

  section "Journald size caps"
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-size-caps.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=2week
Compress=yes
ForwardToSyslog=no
EOF
  systemctl restart systemd-journald
  info "Journal usage: $(journalctl --disk-usage 2>&1 | tr -d '\n')"

  section "Unattended security upgrades"
  # Non-interactive way to set up 20auto-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  info "unattended-upgrades enabled via 20auto-upgrades."
}

# ============================================================================
# Phase 2 — Storage (destructive, flexible layout)
# ============================================================================
#
# Adapts to whatever disks are attached:
#   - Classifies each disk as HDD or SSD via /sys/block/<dev>/queue/rotational
#   - Picks RAID level based on per-tier disk count:
#       1 disk   -> no RAID (single device)
#       2 disks  -> RAID1
#       3 disks  -> RAID5
#       4+ disks -> RAID6
#   - SSDs go to the "hot tier" (/var/lib/docker, ext4)
#     HDDs go to the "data tier" (/mnt/storage, xfs)
#   - If one tier is missing:
#       no SSDs -> Docker's data-root is /mnt/storage/docker (shared with HDD tier)
#       no HDDs -> Nextcloud data lives on SSD tier instead
#       no extra disks -> phase is skipped, both on the root FS (warning issued)

# Decide RAID level string from member count
raid_level() {
  case "$1" in
    1) echo single ;;
    2) echo raid1  ;;
    3) echo raid5  ;;
    *) echo raid6  ;;
  esac
}

# Human description of a RAID layout
raid_desc() {
  local level=$1 n=$2
  case "$level" in
    single) echo "single disk (no RAID, no fault tolerance)" ;;
    raid1)  echo "RAID1 mirror (1× capacity, survives 1 disk loss)" ;;
    raid5)  echo "RAID5 (${n}-1 = $((n-1))× capacity, survives 1 disk loss)" ;;
    raid6)  echo "RAID6 (${n}-2 = $((n-2))× capacity, survives 2 disk losses)" ;;
  esac
}

# build_raid <md_dev> <level> <members...>
# Creates the array (or returns the single device unchanged). Prints nothing
# on stdout — caller passes in the destination device path.
build_raid() {
  local md="$1" level="$2"; shift 2
  local -a members=("$@")
  case "$level" in
    single)
      info "Single-disk tier: using ${members[0]} directly (no mdadm array)."
      ;;
    raid1)
      ( set +o pipefail; yes | mdadm --create "$md" \
          --level=1 --raid-devices=${#members[@]} \
          --bitmap=internal "${members[@]}" )
      ;;
    raid5)
      ( set +o pipefail; yes | mdadm --create "$md" \
          --level=5 --raid-devices=${#members[@]} \
          --chunk=512 --bitmap=internal "${members[@]}" )
      ;;
    raid6)
      ( set +o pipefail; yes | mdadm --create "$md" \
          --level=6 --raid-devices=${#members[@]} \
          --chunk=512 --bitmap=internal "${members[@]}" )
      ;;
    *) die "Unsupported RAID level: $level" ;;
  esac
  udevadm settle
}

phase_storage() {
  banner "Phase 2/4 — Storage (DESTRUCTIVE, flexible layout)"

  section "Discover non-root disks (≥50 GB)"
  local root_src root_parent
  root_src=$(findmnt -n -o SOURCE /)
  root_parent=$(lsblk -no pkname "$root_src" 2>/dev/null | head -n1)
  [[ -n "$root_parent" ]] || root_parent=$(echo "$root_src" | sed 's|/dev/||; s/p\?[0-9]*$//')
  info "Root disk: /dev/$root_parent — will not be touched."

  local -a HDDS=() SSDS=()
  local name type size dev bytes rot
  while read -r name type size; do
    [[ "$type" == "disk" ]] || continue
    [[ "$name" == "$root_parent" ]] && continue
    dev="/dev/$name"
    bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    (( bytes < 50 * 1024 * 1024 * 1024 )) && continue
    rot=$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 1)
    if (( rot == 0 )); then SSDS+=("$dev"); else HDDS+=("$dev"); fi
  done < <(lsblk -dno NAME,TYPE,SIZE)

  # Sort each tier by size descending (biggest disks first) for deterministic ordering
  sort_by_size_desc() {
    local -a arr=("$@")
    (( ${#arr[@]} == 0 )) && return
    for d in "${arr[@]}"; do printf '%s %s\n' "$(blockdev --getsize64 "$d")" "$d"; done \
      | sort -rn | awk '{print $2}'
  }
  mapfile -t HDDS < <(sort_by_size_desc "${HDDS[@]}")
  mapfile -t SSDS < <(sort_by_size_desc "${SSDS[@]}")

  info "HDDs detected (${#HDDS[@]}): ${HDDS[*]:-none}"
  info "SSDs detected (${#SSDS[@]}): ${SSDS[*]:-none}"

  # -------- Plan the layout --------
  section "Plan layout"

  local -a data_pool=() hot_pool=()
  local share_tier=0 data_tier_label hot_tier_label

  if (( ${#HDDS[@]} > 0 && ${#SSDS[@]} > 0 )); then
    # The common case: HDDs for data, SSDs for hot tier (separate mount)
    data_pool=("${HDDS[@]}"); data_tier_label="HDD"
    hot_pool=("${SSDS[@]}");  hot_tier_label="SSD"
  elif (( ${#HDDS[@]} > 0 )); then
    # Only HDDs: data on HDDs, Docker data-root shares the HDD tier
    warn "No SSDs detected. Docker's DB/cache will live on the HDD tier (slower)."
    data_pool=("${HDDS[@]}"); data_tier_label="HDD"
    share_tier=1
  elif (( ${#SSDS[@]} > 0 )); then
    # Only SSDs: data on SSDs, Docker shares the SSD tier
    warn "No HDDs detected. Nextcloud data will live on the SSD tier (limited capacity)."
    data_pool=("${SSDS[@]}"); data_tier_label="SSD"
    share_tier=1
  else
    warn "No extra disks ≥50 GB found. Skipping storage phase entirely."
    warn "Docker + Nextcloud data will live on the root filesystem."
    DOCK_DATA_ROOT="/var/lib/docker"
    return 0
  fi

  local data_level dock_level=""
  data_level=$(raid_level "${#data_pool[@]}")
  if (( share_tier == 0 )); then
    dock_level=$(raid_level "${#hot_pool[@]}")
  fi

  printf '\n  Data tier (%s-based, Nextcloud files):\n' "$data_tier_label"
  printf '    Layout  : %s\n' "$(raid_desc "$data_level" "${#data_pool[@]}")"
  printf '    Members : %s\n' "${data_pool[*]}"
  printf '    Mount   : /mnt/storage (xfs)\n'
  if (( share_tier )); then
    printf '\n  Hot tier (Docker engine, DB, Redis, cache):\n'
    printf '    SHARED with data tier — Docker data-root = /mnt/storage/docker\n'
  else
    printf '\n  Hot tier (%s-based, Docker engine, DB, Redis, cache):\n' "$hot_tier_label"
    printf '    Layout  : %s\n' "$(raid_desc "$dock_level" "${#hot_pool[@]}")"
    printf '    Members : %s\n' "${hot_pool[*]}"
    printf '    Mount   : /var/lib/docker (ext4)\n'
  fi
  echo

  # -------- Destructive confirmation --------
  local -a all_targets=("${data_pool[@]}")
  (( share_tier == 0 )) && all_targets+=("${hot_pool[@]}")

  echo "About to PERMANENTLY DESTROY all data on:"
  for d in "${all_targets[@]}"; do
    local sz model
    sz=$(blockdev --getsize64 "$d")
    model=$(lsblk -no MODEL "$d" 2>/dev/null | head -n1 | sed 's/ *$//')
    printf '  %-14s %-30s %6.1f GiB\n' "$d" "${model:-unknown}" "$(awk "BEGIN{print $sz/1024/1024/1024}")"
  done
  echo

  if [[ "${CONFIRM_NUKE:-}" != "yes" ]]; then
    local typed
    read -r -p "Type exactly 'NUKE' to proceed: " typed
    [[ "$typed" == "NUKE" ]] || die "Storage phase aborted."
  else
    info "CONFIRM_NUKE=yes — skipping interactive prompt."
  fi

  # -------- Install tools --------
  section "Install storage tools"
  export DEBIAN_FRONTEND=noninteractive
  run_patient "apt-get install mdadm xfsprogs" 120 -- \
    apt-get install -y mdadm xfsprogs bc

  # -------- Stop any ghost md arrays --------
  section "Stop any ghost md arrays"
  for md in /dev/md/*  /dev/md[0-9]*; do
    [[ -b $md ]] || continue
    info "Stopping $md"
    mdadm --stop "$md" || true
  done

  # -------- Wipe target disks --------
  section "Wipe ${#all_targets[@]} target disks"
  for d in "${all_targets[@]}"; do
    info "Wiping $d"
    for p in "${d}"?*; do
      [[ -b $p ]] || continue
      wipefs -a "$p" || true
      mdadm --zero-superblock "$p" 2>/dev/null || true
    done
    wipefs -a "$d" || true
    mdadm --zero-superblock "$d" 2>/dev/null || true
    sgdisk --zap-all "$d" || true
  done
  partprobe || true
  udevadm settle; sleep 2

  # -------- Build arrays --------
  local DATA_DEV DOCK_DEV=""
  section "Build data tier ($data_level on ${#data_pool[@]} disks)"
  build_raid /dev/md0 "$data_level" "${data_pool[@]}"
  if [[ "$data_level" == "single" ]]; then
    DATA_DEV="${data_pool[0]}"
  else
    DATA_DEV="/dev/md0"
  fi

  if (( share_tier == 0 )); then
    section "Build hot tier ($dock_level on ${#hot_pool[@]} disks)"
    build_raid /dev/md1 "$dock_level" "${hot_pool[@]}"
    if [[ "$dock_level" == "single" ]]; then
      DOCK_DEV="${hot_pool[0]}"
    else
      DOCK_DEV="/dev/md1"
    fi
  fi

  # -------- Tuning for parity-RAID --------
  if [[ "$data_level" == "raid5" || "$data_level" == "raid6" ]] && [[ -f /sys/block/md0/md/stripe_cache_size ]]; then
    section "Tune /dev/md0 stripe cache"
    echo 32768 > /sys/block/md0/md/stripe_cache_size
    cat > /etc/udev/rules.d/60-md0-tune.rules <<'EOF'
SUBSYSTEM=="block", KERNEL=="md0", ACTION=="change|add", ATTR{md/stripe_cache_size}="32768"
EOF
    echo 200000 > /proc/sys/dev/raid/speed_limit_max || true
  fi

  # -------- Format --------
  section "Format filesystems"
  info "mkfs.xfs on big arrays can take 2-5 min during initial resync."
  run_patient "mkfs.xfs $DATA_DEV" 180 -- mkfs.xfs -f -L ncdata "$DATA_DEV"

  if [[ -n "$DOCK_DEV" ]]; then
    info "mkfs.ext4 on the hot tier — can take 1-3 min if the data tier is still resyncing."
    run_patient "mkfs.ext4 $DOCK_DEV" 120 -- mkfs.ext4 -F -L docker "$DOCK_DEV"
  fi

  # -------- Persist mdadm config (only if any md device was created) --------
  if mdadm --detail --scan | grep -q ARRAY; then
    section "Persist mdadm config"
    mkdir -p /etc/mdadm
    sed -i '/^ARRAY /d' /etc/mdadm/mdadm.conf 2>/dev/null || true
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    run_patient "update-initramfs -u" 90 -- update-initramfs -u
  else
    info "No md arrays were created (single-disk tiers) — skipping mdadm.conf update."
  fi

  # -------- fstab + mounts --------
  section "Mountpoints + fstab"
  mkdir -p /mnt/storage
  local UUID_DATA UUID_DOCK=""
  UUID_DATA=$(blkid -s UUID -o value "$DATA_DEV")
  sed -i '\|[[:space:]]/mnt/storage[[:space:]]|d' /etc/fstab
  echo "UUID=$UUID_DATA  /mnt/storage       xfs   defaults,noatime                     0 2" >> /etc/fstab

  if [[ -n "$DOCK_DEV" ]]; then
    mkdir -p /var/lib/docker
    UUID_DOCK=$(blkid -s UUID -o value "$DOCK_DEV")
    sed -i '\|[[:space:]]/var/lib/docker[[:space:]]|d' /etc/fstab
    echo "UUID=$UUID_DOCK  /var/lib/docker    ext4  defaults,noatime,errors=remount-ro   0 2" >> /etc/fstab
    DOCK_DATA_ROOT="/var/lib/docker"
  else
    # Shared tier: Docker stores data inside /mnt/storage/docker
    DOCK_DATA_ROOT="/mnt/storage/docker"
  fi

  systemctl daemon-reload
  mount -a
  findmnt -n /mnt/storage >/dev/null || die "/mnt/storage did not mount."
  if [[ -n "$DOCK_DEV" ]]; then
    findmnt -n /var/lib/docker >/dev/null || die "/var/lib/docker did not mount."
  else
    mkdir -p "$DOCK_DATA_ROOT"
  fi

  # -------- Subfolders --------
  section "Nextcloud subfolders"
  mkdir -p /mnt/storage/ncdata /mnt/storage/backup /mnt/storage/external
  chown root:root /mnt/storage/{ncdata,backup,external}
  chmod 750 /mnt/storage/{ncdata,backup}
  chmod 755 /mnt/storage/external

  # -------- Recovery info --------
  section "Recovery info"
  {
    echo "Generated $(date -Is)"
    echo
    echo "Data tier ($data_tier_label, $data_level):"
    echo "  device : $DATA_DEV"
    echo "  members: ${data_pool[*]}"
    echo "  uuid   : $UUID_DATA"
    echo "  mount  : /mnt/storage (xfs)"
    if [[ -n "$DOCK_DEV" ]]; then
      echo
      echo "Hot tier ($hot_tier_label, $dock_level):"
      echo "  device : $DOCK_DEV"
      echo "  members: ${hot_pool[*]}"
      echo "  uuid   : $UUID_DOCK"
      echo "  mount  : /var/lib/docker (ext4)"
    else
      echo
      echo "Hot tier: SHARED with data tier -> Docker data-root = $DOCK_DATA_ROOT"
    fi
    echo
    echo "Subfolders on /mnt/storage:"
    echo "  /mnt/storage/ncdata    -> Nextcloud AIO NEXTCLOUD_DATADIR"
    echo "  /mnt/storage/backup    -> AIO BorgBackup destination"
    echo "  /mnt/storage/external  -> External Storage app mounts"
    echo
    echo "If the VM is rebuilt: reinstall mdadm + xfsprogs, attach disks,"
    echo "run 'mdadm --assemble --scan' (or manually against the members), then mount by UUID."
  } > /root/nextcloud-storage-info.txt
  chmod 600 /root/nextcloud-storage-info.txt
  info "Recovery info saved to /root/nextcloud-storage-info.txt"

  # -------- Summary + resync status --------
  section "Storage summary"
  if [[ -n "$DOCK_DEV" ]]; then
    df -hT /mnt/storage /var/lib/docker
  else
    df -hT /mnt/storage
    info "Docker data-root will be $DOCK_DATA_ROOT (shared with data tier)."
  fi
  if grep -q resync /proc/mdstat 2>/dev/null; then
    local pct finish speed
    pct=$(grep -oP '\d+\.\d+%' /proc/mdstat    | head -n1 || true)
    finish=$(grep -oP 'finish=\S+' /proc/mdstat | head -n1 | sed 's/finish=//' || true)
    speed=$(grep -oP 'speed=\S+'  /proc/mdstat | head -n1 | sed 's/speed=//' || true)
    warn "RAID resync in progress: ${pct:-?}  ETA ${finish:-?}  Speed ${speed:-?}"
    info "Arrays are usable during resync. Monitor: watch -n 10 cat /proc/mdstat"
  fi
}

# ============================================================================
# Phase 3 — Docker CE
# ============================================================================

phase_docker() {
  banner "Phase 3/4 — Docker CE install"

  # Ubuntu codename for Docker's apt source
  . /etc/os-release
  [[ "$ID" == "ubuntu" ]] || die "Docker phase expects Ubuntu. Found: $ID"

  section "Remove conflicting distro packages"
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      info "Removing $pkg"
      apt-get -y remove "$pkg" || true
    fi
  done

  section "Prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y install ca-certificates curl gnupg

  section "Docker GPG key + apt source"
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local arch
  arch=$(dpkg --print-architecture)
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update

  section "Install Docker Engine + Compose plugin"
  info "Pulling ~300 MB of packages. Heartbeat while it runs."
  run_patient "apt-get install docker-ce et al." 180 -- \
    apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  section "daemon.json"
  mkdir -p /etc/docker
  # If the storage phase put the hot tier on a non-default path (shared with data tier
  # because there were no SSDs), write that path into daemon.json as data-root so Docker
  # stores all its volumes/images/containers there instead of /var/lib/docker.
  if [[ -n "${DOCK_DATA_ROOT:-}" && "$DOCK_DATA_ROOT" != "/var/lib/docker" ]]; then
    mkdir -p "$DOCK_DATA_ROOT"
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCK_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "default-address-pools": [ { "base": "172.20.0.0/16", "size": 24 } ]
}
EOF
    info "daemon.json written with data-root=$DOCK_DATA_ROOT (hot tier shared with data tier)."
  else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "default-address-pools": [ { "base": "172.20.0.0/16", "size": 24 } ]
}
EOF
    info "daemon.json written (log rotation 10m x3, live-restore, custom bridge pool)."
  fi

  section "Start Docker"
  systemctl enable docker.service containerd.service
  systemctl restart docker.service
  sleep 2
  info "Data root: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  info "Storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null)"

  section "Docker group membership for $DOCKER_USER"
  id -u "$DOCKER_USER" >/dev/null 2>&1 || die "User $DOCKER_USER does not exist."
  if id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx docker; then
    info "$DOCKER_USER already in docker group."
  else
    usermod -aG docker "$DOCKER_USER"
    warn "$DOCKER_USER added to docker group — must log out/in for it to apply."
  fi

  section "Verify with hello-world"
  run_patient "docker run hello-world" 30 -- docker run --rm hello-world
}

# ============================================================================
# Phase 4 — Nextcloud AIO
# ============================================================================

phase_aio() {
  banner "Phase 4/4 — Nextcloud AIO"

  local NCDATA=/mnt/storage/ncdata
  local NCEXTRA_MOUNT=/mnt/storage/external
  local AIO_CONTAINER=nextcloud-aio-mastercontainer
  local AIO_IMAGE=nextcloud/all-in-one:latest

  section "Preflight"
  [[ -d $NCDATA ]] || die "$NCDATA missing (storage phase failed?)."
  if [[ -n "$(ls -A "$NCDATA" 2>/dev/null || true)" ]]; then
    die "$NCDATA not empty. AIO demands an empty datadir."
  fi
  mkdir -p "$NCEXTRA_MOUNT"
  if docker ps -a --format '{{.Names}}' | grep -qx "$AIO_CONTAINER"; then
    die "$AIO_CONTAINER already exists. Remove it first: docker stop $AIO_CONTAINER && docker rm $AIO_CONTAINER"
  fi

  section "UFW rules"
  if ufw status | head -n1 | grep -q active; then
    ufw allow from "$LAN_CIDR" to any port 8080 proto tcp comment 'Nextcloud AIO admin UI' || true
    if [[ "$MODE" == "internet" && -n "$PROXY_IP" ]]; then
      ufw allow from "$PROXY_IP" to any port 11000 proto tcp comment 'Nextcloud AIO apache <- nginx proxy' || true
    else
      warn "LAN mode: port 11000 not opened by default."
      warn "If a reverse proxy on the LAN needs to hit it, open it manually:"
      warn "  sudo ufw allow from <proxy_ip> to any port 11000 proto tcp"
    fi
    ufw reload || true
  else
    warn "UFW inactive — skipping firewall rules."
  fi

  section "Pull AIO image"
  info "~800 MB for the mastercontainer. Other containers (apache/postgres/redis/etc.)"
  info "get pulled later after the first-run wizard (~3-4 GB total)."
  run_patient "docker pull $AIO_IMAGE" 120 -- docker pull "$AIO_IMAGE"

  section "Deploy $AIO_CONTAINER"
  local extra_env=()
  if [[ "$MODE" == "lan" ]]; then
    extra_env+=(--env SKIP_DOMAIN_VALIDATION=true)
    info "LAN mode: SKIP_DOMAIN_VALIDATION=true"
  fi

  docker run -d \
    --init \
    --sig-proxy=false \
    --name "$AIO_CONTAINER" \
    --restart always \
    --publish 8080:8080 \
    --env APACHE_PORT=11000 \
    --env APACHE_IP_BINDING=0.0.0.0 \
    --env NEXTCLOUD_DATADIR="$NCDATA" \
    --env NEXTCLOUD_MOUNT="$NCEXTRA_MOUNT" \
    "${extra_env[@]}" \
    --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
    --volume /var/run/docker.sock:/var/run/docker.sock:ro \
    "$AIO_IMAGE"

  section "Wait for admin UI"
  info "Polling https://127.0.0.1:8080/ until the mastercontainer is up (est 60s, max 4 min)."
  local start_ts=$(date +%s) tick=0 ui_up=0
  local ui_est=60 ui_max=240
  while (( $(date +%s) - start_ts < ui_max )); do
    if curl -ksSf -m 2 https://127.0.0.1:8080/ >/dev/null 2>&1; then
      info "Admin UI up after $(fmt_sec $(($(date +%s) - start_ts)))."
      ui_up=1
      break
    fi
    tick=$((tick + 2))
    if (( tick % 10 == 0 )); then
      info "  $(draw_bar $(($(date +%s) - start_ts)) "$ui_est")  (admin UI boot)"
    fi
    sleep 2
  done
  (( ui_up )) || warn "Admin UI didn't answer within 4 min. Check: docker logs -f $AIO_CONTAINER"
}

# ============================================================================
# Main
# ============================================================================

(( STATE_TIDY_DONE    )) || phase_tidy
(( STATE_STORAGE_DONE )) || phase_storage
(( STATE_DOCKER_DONE  )) || phase_docker
(( STATE_AIO_DONE     )) || phase_aio

# ============================================================================
# Final summary
# ============================================================================

banner "All phases complete"

section "Next steps"
if [[ "$MODE" == "internet" ]]; then
  cat <<EOF
1. Make sure DNS for $DOMAIN resolves to your public IP (Cloudflare A record).
2. Make sure your router forwards 80/443 to the proxy VM at $PROXY_IP (skip if already done).
3. Make sure the nginx site for $DOMAIN on the proxy:
     - upstream to http://$(hostname -I | awk '{print $1}'):11000
     - terminates TLS (Cloudflare Origin cert, Let's Encrypt, or similar)
4. Open https://$(hostname -I | awk '{print $1}'):8080 from your LAN.
5. Copy the one-time passphrase AIO shows you. Enter it.
6. Enter the domain: $DOMAIN
7. Pick optional containers (Office/Talk/Imaginary recommended), click Start.
8. When all containers are green, browse https://$DOMAIN and log in with the
   initial admin credentials AIO shows you.
EOF
else
  cat <<EOF
1. Open https://$(hostname -I | awk '{print $1}'):8080 from your LAN.
2. Copy the one-time passphrase AIO shows you. Enter it.
3. Enter the domain:  $DOMAIN
4. AIO will NOT attempt to validate the domain (SKIP_DOMAIN_VALIDATION=true).
5. To reach it by name, add to /etc/hosts on each client OR your LAN DNS:
     $(hostname -I | awk '{print $1}')   $DOMAIN
6. You'll still need a way for clients to accept the cert. AIO's Caddy will try to
   get a real cert, which won't work LAN-only. For pure LAN + HTTPS:
     - install a local CA like mkcert and replace AIO's cert, OR
     - run with a reverse proxy on your LAN (nginx/Caddy) with a local cert.
EOF
fi

echo
info "Log: $LOG_FILE"
info "Storage info (if phase 2 ran): /root/nextcloud-storage-info.txt"
