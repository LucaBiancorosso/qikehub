# shellcheck shell=bash
# qikehub — PKI (strongSwan pki): ECDSA P-384 / SHA-384 throughout.
# Layout: $HUB_PKI/{private/ca.key,private/server.key,certs/ca.pem,issued/*.pem,crl/crl.pem,index.tsv}
# Client/site private keys exist only long enough to build the PKCS#12, then are shredded.

PKI_CA_DAYS=3650
PKI_SERVER_DAYS=825
PKI_CLIENT_DAYS=730

pki_ca_cn() { cat "$HUB_PKI/ca.cn"; }

# strongSwan's pki prints "plugin 'x': failed to load" for every optional plugin
# not installed; filter that noise, keep real errors and the exit status.
pki() {
  local err rc=0
  err=$(mktemp)
  command pki "$@" 2>"$err" || rc=$?
  grep -v "^plugin '.*': failed to load" "$err" >&2 || true
  rm -f "$err"
  return "$rc"
}

pki_init() {
  if [[ -f $HUB_PKI/certs/ca.pem ]]; then return 0; fi
  hdr "PKI"
  install -d -m 0700 "$HUB_PKI" "$HUB_PKI/private"
  install -d -m 0755 "$HUB_PKI/certs" "$HUB_PKI/issued" "$HUB_PKI/crl"
  local cn; cn="qikehub CA $(gen_secret 8)"
  ( umask 077; pki --gen --type ecdsa --size 384 --outform pem > "$HUB_PKI/private/ca.key" )
  pki --self --ca --lifetime "$PKI_CA_DAYS" --in "$HUB_PKI/private/ca.key" --type ecdsa \
      --digest sha384 --dn "O=qikehub, CN=$cn" --outform pem > "$HUB_PKI/certs/ca.pem"
  printf '%s\n' "$cn" > "$HUB_PKI/ca.cn"
  : > "$HUB_PKI/index.tsv"
  pki_crl_update
  log "CA created: CN=$cn (ECDSA P-384, ${PKI_CA_DAYS}d)"
}

# pki_issue BASE DN DAYS [pki --issue args...]  → $HUB_PKI/issued/BASE.pem, key in private/BASE.key
pki_issue() {
  local base=$1 dn=$2 days=$3; shift 3
  ( umask 077; pki --gen --type ecdsa --size 384 --outform pem > "$HUB_PKI/private/$base.key" )
  pki --pub --in "$HUB_PKI/private/$base.key" --type ecdsa \
    | pki --issue --lifetime "$days" --cacert "$HUB_PKI/certs/ca.pem" --cakey "$HUB_PKI/private/ca.key" \
          --digest sha384 --dn "$dn" "$@" --outform pem > "$HUB_PKI/issued/$base.pem"
}

pki_serial()   { openssl x509 -in "$1" -noout -serial | cut -d= -f2; }
pki_notafter() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }

pki_ensure_server() {
  local want="$HUB_FQDN|$PUBLIC_IP4" have="" cert="$HUB_PKI/issued/server.pem"
  [[ -f $HUB_PKI/server.meta ]] && have=$(<"$HUB_PKI/server.meta")
  if [[ -f $cert && $want == "$have" ]] && openssl x509 -in "$cert" -noout -checkend $((30*86400)) >/dev/null; then
    return 0
  fi
  pki_issue server "O=qikehub, CN=$HUB_FQDN" "$PKI_SERVER_DAYS" \
    --san "$HUB_FQDN" --san "$PUBLIC_IP4" --flag serverAuth --flag ikeIntermediate
  printf '%s\n' "$want" > "$HUB_PKI/server.meta"
  log "server certificate issued: $HUB_FQDN, $PUBLIC_IP4"
}

# pki_crl_update [CERT REASON]
pki_crl_update() {
  local args=(--signcrl --cacert "$HUB_PKI/certs/ca.pem" --cakey "$HUB_PKI/private/ca.key"
              --digest sha384 --lifetime "$PKI_CA_DAYS" --outform pem)
  if [[ -s $HUB_PKI/crl/crl.pem ]]; then args+=(--lastcrl "$HUB_PKI/crl/crl.pem"); fi
  if [[ -n ${1-} ]]; then args+=(--reason "${2:-superseded}" --cert "$1"); fi
  pki "${args[@]}" > "$HUB_PKI/crl/crl.pem.new"
  mv -f "$HUB_PKI/crl/crl.pem.new" "$HUB_PKI/crl/crl.pem"
}

# --- index: type name id serial notAfter status certfile ---------------------
pki_index_valid() { awk -F'\t' -v t="$1" -v n="$2" '$1==t && $2==n && $6=="valid"' "$HUB_PKI/index.tsv"; }

# pki_issue_entity TYPE(client|site) NAME ID  → sets PKI_CERT, PKI_KEY
pki_issue_entity() {
  local type=$1 name=$2 id=$3 ou base serial cert
  case $type in client) ou=clients ;; site) ou=sites ;; *) die "bad type $type" ;; esac
  base="$type-$name"
  pki_issue "$base" "O=qikehub, OU=$ou, CN=$id" "$PKI_CLIENT_DAYS" --san "$id" --flag clientAuth
  serial=$(pki_serial "$HUB_PKI/issued/$base.pem")
  cert="$HUB_PKI/issued/$base-$serial.pem"
  mv -f "$HUB_PKI/issued/$base.pem" "$cert"
  printf '%s\t%s\t%s\t%s\t%s\tvalid\t%s\n' "$type" "$name" "$id" "$serial" "$(pki_notafter "$cert")" "$cert" \
    >> "$HUB_PKI/index.tsv"
  PKI_CERT=$cert
  PKI_KEY="$HUB_PKI/private/$base.key"
}

pki_revoke_entity() { # TYPE NAME REASON → prints revoked id(s)
  local type=$1 name=$2 reason=${3:-superseded} row cert id tmp
  row=$(pki_index_valid "$type" "$name")
  [[ -n $row ]] || return 1
  cert=$(cut -f7 <<<"$row"); id=$(cut -f3 <<<"$row")
  pki_crl_update "$cert" "$reason"
  tmp=$(mktemp "$HUB_PKI/.index.XXXXXX")
  awk -F'\t' -v OFS='\t' -v t="$type" -v n="$name" '$1==t && $2==n && $6=="valid"{$6="revoked"}1' \
    "$HUB_PKI/index.tsv" > "$tmp"
  mv -f "$tmp" "$HUB_PKI/index.tsv"
  printf '%s\n' "$id"
}

# PKCS#12 with PBE-SHA1-3DES + SHA1 MAC: the only encoding iOS/macOS import reliably.
# The container is protected by a random 24-char password (~143 bits); the PBE choice
# is transport wrapping, not the tunnel crypto.
pki_export_p12() { # KEY CERT FRIENDLYNAME OUT   (password in $HUB_P12_PASS)
  openssl pkcs12 -export -inkey "$1" -in "$2" -name "$3" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout env:HUB_P12_PASS -out "$4"
  chmod 0600 "$4"
}

pki_destroy_key() { shred -u "$1" 2>/dev/null || rm -f "$1"; }
