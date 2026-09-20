# shellcheck shell=bash
# qikehub — common helpers: logging, prompts, validation, state.

: "${HUB_ETC:=/etc/qikehub}"
: "${HUB_VAR:=/var/lib/qikehub}"
: "${HUB_LIBEXEC:=/usr/local/lib/qikehub}"
: "${HUB_OPT:=/opt/qikehub}"
: "${SWANCTL_DIR:=/etc/swanctl}"
: "${HUB_NONINTERACTIVE:=0}"
: "${HUB_VERBOSE:=0}"
HUB_CONF="$HUB_ETC/hub.conf"
HUB_PKI="$HUB_ETC/pki"
HUB_SECRETS="$HUB_ETC/secrets"
HUB_OUT="$HUB_VAR/out"

# Persisted state keys (hub.conf). Everything else is derived.
HUB_KEYS=(
  HUB_FQDN ID_DOMAIN WAN_IF PUBLIC_IP4
  PORT_MODE IKE_PORT
  OVERLAY4 POOL4 MGMT4 POOL6 IPV6_MODE
  PQ_MODE PQ_ACTIVE
  EGRESS HOME_ENABLED HOME_NAME HOME_LANS HOME_AUTH
  CLIENT_DNS APPLE_ONDEMAND
  SSH_BOOTSTRAP SNMP_ENABLED SNMP_USER NODE_EXPORTER HARDEN_SSH AUTO_UPDATES
)

if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_0=$'\e[0m'
else
  C_R='' C_G='' C_Y='' C_B='' C_0=''
fi

log()  { [[ $HUB_VERBOSE == 1 ]] || return 0; printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

require_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

# ask VAR "prompt" default [validator]
# Existing value of VAR (from hub.conf or env) becomes the default. Enter "-" to clear.
ask() {
  local _v=$1 _p=$2 _d=${3-} _chk=${4-} _a
  if [[ -n ${!_v-} ]]; then _d=${!_v}; fi
  if [[ $HUB_NONINTERACTIVE == 1 ]]; then
    _a=$_d
  else
    while :; do
      read -r -p "  $_p [${_d}]: " _a || die "aborted"
      _a=${_a:-$_d}
      if [[ $_a == "-" ]]; then _a=""; fi
      if [[ -z $_chk ]] || "$_chk" "$_a"; then break; fi
      warn "invalid value: '$_a'"
    done
  fi
  if [[ -n $_chk ]] && ! "$_chk" "$_a"; then die "invalid value for $_v: '$_a'"; fi
  printf -v "$_v" '%s' "$_a"
}

_CHOICES=""
_in_choices() { local c; for c in $_CHOICES; do [[ $1 == "$c" ]] && return 0; done; return 1; }
# ask_choice VAR "prompt" default "a b c"
ask_choice() { _CHOICES=$4; ask "$1" "$2 (${4// /|})" "$3" _in_choices; }

confirm() {
  [[ $HUB_NONINTERACTIVE == 1 ]] && return 0
  local a; read -r -p "  $1 [y/N]: " a || return 1
  [[ $a =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- validators -------------------------------------------------------------
is_fqdn() { [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }
is_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$ ]]; }
is_port() {
  [[ $1 =~ ^[0-9]{4,5}$ ]] || return 1
  (( 10#$1 >= 1024 && 10#$1 <= 65535 )) || return 1
  [[ $1 != 4500 && $1 != 1701 ]]
}
is_ifname() { [[ $1 =~ ^[a-zA-Z0-9._-]{1,15}$ ]] && ip link show "$1" >/dev/null 2>&1; }

# --- state ------------------------------------------------------------------
conf_save() {
  install -d -m 0700 "$HUB_ETC"
  local tmp k
  tmp=$(mktemp "$HUB_ETC/.hub.conf.XXXXXX")
  {
    printf '# qikehub state — %s. Change with: qikehub configure\n' "$(date -u +%FT%TZ)"
    for k in "${HUB_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k-}"; done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$HUB_CONF"
}

conf_load() {
  [[ -f $HUB_CONF ]] || return 1
  [[ $(stat -c '%u %a' "$HUB_CONF") == "0 600" ]] || die "$HUB_CONF must be root-owned, mode 0600"
  # shellcheck source=/dev/null
  . "$HUB_CONF"
}

# write_file PATH MODE < content  — atomic; sets WF_CHANGED=1 if content changed
WF_CHANGED=0
write_file() {
  local path=$1 mode=$2 dir tmp
  dir=$(dirname "$path")
  install -d "$dir"
  tmp=$(mktemp "$dir/.qikehub.XXXXXX")
  cat > "$tmp"
  chmod "$mode" "$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; chmod "$mode" "$path"
  else
    mv -f "$tmp" "$path"; WF_CHANGED=1
  fi
}

gen_secret() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-32}"; }
gen_uuid()   { tr '[:lower:]' '[:upper:]' < /proc/sys/kernel/random/uuid; }
rand_port()  { shuf -i 20000-60999 -n 1; }
