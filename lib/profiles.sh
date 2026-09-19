# shellcheck shell=bash
# ipsec-hub — client and site configuration artefacts.

b64_ca_der() { openssl x509 -in "$HUB_PKI/certs/ca.pem" -outform der | base64 -w0; }

# Apple iOS/iPadOS/macOS .mobileconfig (native IKEv2). No p12 password embedded:
# the device prompts for it at install time.
profile_apple() { # NAME ID P12
  local name=$1 id=$2 p12=$3 u_prof u_root u_p12 u_vpn ca_b64 p12_b64 ca_cn pq="" pq_fb="" od=""
  u_prof=$(gen_uuid); u_root=$(gen_uuid); u_p12=$(gen_uuid); u_vpn=$(gen_uuid)
  ca_b64=$(b64_ca_der); p12_b64=$(base64 -w0 < "$p12"); ca_cn=$(pki_ca_cn)
  local base_id="net.ipsec-hub.${HUB_FQDN}.${name}"

  if [[ $PQ_ACTIVE != off ]]; then
    pq='
            <key>PostQuantumKeyExchangeMethods</key>
            <array><integer>37</integer></array>'
    pq_fb="
        <key>AllowPostQuantumKeyExchangeFallback</key>
        <integer>$([[ $PQ_ACTIVE == prefer ]] && echo 1 || echo 0)</integer>"
  fi
  if [[ $APPLE_ONDEMAND == yes ]]; then
    od='
        <key>OnDemandEnabled</key>
        <integer>1</integer>
        <key>OnDemandRules</key>
        <array><dict><key>Action</key><string>Connect</string></dict></array>
        <key>IncludeAllNetworks</key>
        <integer>1</integer>
        <key>ExcludeLocalNetworks</key>
        <integer>1</integer>'
  fi

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadDisplayName</key><string>ipsec-hub ${HUB_FQDN} (${name})</string>
  <key>PayloadIdentifier</key><string>${base_id}</string>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadUUID</key><string>${u_prof}</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadIdentifier</key><string>${base_id}.ca</string>
      <key>PayloadUUID</key><string>${u_root}</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>${ca_cn}</string>
      <key>PayloadCertificateFileName</key><string>ipsec-hub-ca.cer</string>
      <key>PayloadContent</key><data>${ca_b64}</data>
    </dict>
    <dict>
      <key>PayloadType</key><string>com.apple.security.pkcs12</string>
      <key>PayloadIdentifier</key><string>${base_id}.identity</string>
      <key>PayloadUUID</key><string>${u_p12}</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>${id}</string>
      <key>PayloadCertificateFileName</key><string>${name}.p12</string>
      <key>PayloadContent</key><data>${p12_b64}</data>
    </dict>
    <dict>
      <key>PayloadType</key><string>com.apple.vpn.managed</string>
      <key>PayloadIdentifier</key><string>${base_id}.vpn</string>
      <key>PayloadUUID</key><string>${u_vpn}</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadDisplayName</key><string>ipsec-hub VPN</string>
      <key>UserDefinedName</key><string>ipsec-hub ${HUB_FQDN}</string>
      <key>VPNType</key><string>IKEv2</string>
      <key>IKEv2</key>
      <dict>
        <key>RemoteAddress</key><string>${HUB_FQDN}</string>
        <key>RemoteIdentifier</key><string>${HUB_FQDN}</string>
        <key>LocalIdentifier</key><string>${id}</string>
        <key>AuthenticationMethod</key><string>Certificate</string>
        <key>CertificateType</key><string>ECDSA384</string>
        <key>PayloadCertificateUUID</key><string>${u_p12}</string>
        <key>ServerCertificateIssuerCommonName</key><string>${ca_cn}</string>
        <key>ServerCertificateCommonName</key><string>${HUB_FQDN}</string>
        <key>ExtendedAuthEnabled</key><integer>0</integer>
        <key>EnablePFS</key><integer>1</integer>
        <key>EnforceStrictAlgorithmSelection</key><integer>1</integer>
        <key>EnableCertificateRevocationCheck</key><integer>0</integer>
        <key>DisableMOBIKE</key><integer>0</integer>
        <key>DisableRedirect</key><integer>1</integer>
        <key>DeadPeerDetectionRate</key><string>Medium</string>
        <key>NATKeepAliveOffloadEnable</key><integer>1</integer>
        <key>NATKeepAliveInterval</key><integer>20</integer>
        <key>UseConfigurationAttributeInternalIPSubnet</key><integer>0</integer>${od}${pq_fb}
        <key>IKESecurityAssociationParameters</key>
        <dict>
            <key>EncryptionAlgorithm</key><string>AES-256-GCM</string>
            <key>IntegrityAlgorithm</key><string>SHA2-384</string>
            <key>DiffieHellmanGroup</key><integer>20</integer>
            <key>LifeTimeInMinutes</key><integer>480</integer>${pq}
        </dict>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
            <key>EncryptionAlgorithm</key><string>AES-256-GCM</string>
            <key>IntegrityAlgorithm</key><string>SHA2-384</string>
            <key>DiffieHellmanGroup</key><integer>20</integer>
            <key>LifeTimeInMinutes</key><integer>60</integer>${pq}
        </dict>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF
}

# strongSwan Android app profile (.sswan) — supports the custom port natively.
profile_sswan() { # NAME ID P12
  local name=$1 id=$2 p12=$3
  cat <<EOF
{
  "uuid": "$(gen_uuid | tr '[:upper:]' '[:lower:]')",
  "name": "ipsec-hub ${HUB_FQDN} (${name})",
  "type": "ikev2-cert",
  "remote": {
    "addr": "${HUB_FQDN}",
    "port": ${IKE_PORT},
    "id": "${HUB_FQDN}",
    "cert": "$(b64_ca_der)"
  },
  "local": {
    "id": "${id}",
    "p12": "$(base64 -w0 < "$p12")"
  }
}
EOF
}

# swanctl.conf for strongSwan initiators (Linux; macOS via Homebrew) on the custom port.
profile_swanctl() { # NAME ID
  local name=$1 id=$2
  swan_set_proposals
  cat <<EOF
# ipsec-hub client '${name}' — strongSwan >= 6.0 (swanctl)
# Place files under your swanctl dir (Linux: /etc/swanctl, Homebrew: \$(brew --prefix)/etc/swanctl):
#   ipsec-hub-ca.pem -> x509ca/    ${name}.pem -> x509/    ${name}.p12 -> pkcs12/
# Load (prompts for the PKCS#12 password) and connect:
#   swanctl --load-all && swanctl --initiate --child ipsec-hub
connections {
    ipsec-hub {
        version = 2
        remote_addrs = ${HUB_FQDN}
        remote_port = ${IKE_PORT}
        vips = 0.0.0.0, ::
        proposals = ${IKE_RW}
        encap = yes
        mobike = yes
        local {
            auth = pubkey
            certs = ${name}.pem
            id = ${id}
        }
        remote {
            auth = pubkey
            id = ${HUB_FQDN}
            cacerts = ipsec-hub-ca.pem
        }
        children {
            ipsec-hub {
                remote_ts = 0.0.0.0/0, ::/0
                esp_proposals = ${ESP_RW}
                dpd_action = restart
                close_action = restart
            }
        }
    }
}
EOF
}

# RouterOS 7 initiator (home behind CGNAT). Policy-based on the RouterOS side.
profile_routeros() { # CERTNAME_HINT
  local id lan src_list pool=$POOL4 auth_line
  id=$(site_id)
  if [[ $EGRESS == home ]]; then src_list="0.0.0.0/0"; else src_list=$HOME_LANS; fi
  if [[ $HOME_AUTH == cert ]]; then
    auth_line="auth-method=digital-signature certificate=${HOME_NAME}.p12_0"
  else
    auth_line="auth-method=pre-shared-key secret=\"$(<"$HUB_SECRETS/site.psk")\""
  fi

  printf "# ipsec-hub site '%s' — RouterOS 7 — generated %s\n#\n" "$HOME_NAME" "$(date -u +%FT%TZ)"
  if [[ $HOME_AUTH == cert ]]; then
    cat <<EOF
# BEFORE importing:
#   1. Upload ipsec-hub-ca.pem and ${HOME_NAME}.p12 to Files
#   2. /certificate import file-name=ipsec-hub-ca.pem passphrase=""
#      /certificate import file-name=${HOME_NAME}.p12 passphrase="<p12 password>"
#   3. /certificate print — if the names differ from ipsec-hub-ca.pem_0 / ${HOME_NAME}.p12_0, edit below
EOF
  else
    printf '# Contains the site PSK — delete this file from the router after import.\n'
  fi
  cat <<EOF
# Import: /import file-name=${HOME_NAME}.rsc
# Verify: /ip ipsec active-peers print ; /ip ipsec installed-sa print
#         (README: "RouterOS on a custom port")
EOF
  if [[ $HOME_AUTH == cert ]]; then
    printf '/certificate set [find name="ipsec-hub-ca.pem_0"] trusted=yes\n'
  fi
  cat <<EOF

/ip ipsec profile add name=ipsec-hub enc-algorithm=aes-256 hash-algorithm=sha384 prf-algorithm=sha384 dh-group=ecp384 nat-traversal=yes dpd-interval=30s dpd-maximum-failures=3
/ip ipsec proposal add name=ipsec-hub enc-algorithms=aes-256-gcm auth-algorithms=sha512 pfs-group=ecp384 lifetime=1h
/ip ipsec peer add name=ipsec-hub address=${PUBLIC_IP4}/32 port=${IKE_PORT} exchange-mode=ike2 profile=ipsec-hub send-initial-contact=yes comment="ipsec-hub ${HUB_FQDN}"
/ip ipsec identity add peer=ipsec-hub ${auth_line} my-id="fqdn:${id}" remote-id="fqdn:${HUB_FQDN}" match-by=remote-id generate-policy=no
EOF
  for lan in ${src_list//,/ }; do
    printf '/ip ipsec policy add peer=ipsec-hub tunnel=yes src-address=%s dst-address=%s proposal=ipsec-hub action=encrypt level=unique comment="ipsec-hub"\n' "$lan" "$OVERLAY4"
  done
  cat <<EOF

# keep IPsec flows out of fasttrack, and never NAT traffic heading into the tunnel
/ip firewall filter add chain=forward action=accept ipsec-policy=in,ipsec comment="ipsec-hub: decrypted in" place-before=0
/ip firewall filter add chain=forward action=accept ipsec-policy=out,ipsec comment="ipsec-hub: to be encrypted" place-before=0
/ip firewall nat add chain=srcnat action=accept dst-address=${OVERLAY4} comment="ipsec-hub: no NAT into tunnel" place-before=0
EOF
  if [[ $EGRESS == home ]]; then
    cat <<EOF

# EGRESS=home: clients browse via this router; allow them to resolve DNS here
/ip firewall nat add chain=srcnat action=masquerade src-address=${pool} out-interface-list=WAN comment="ipsec-hub: client egress"
/ip firewall filter add chain=input action=accept ipsec-policy=in,ipsec src-address=${pool} protocol=udp dst-port=53 comment="ipsec-hub: client DNS" place-before=0
/ip firewall filter add chain=input action=accept ipsec-policy=in,ipsec src-address=${pool} protocol=tcp dst-port=53 comment="ipsec-hub: client DNS" place-before=0
EOF
  fi
  cat <<EOF

# NOTE (VRFs): RouterOS IPsec policies live in the main table. LANs inside VRFs need
# route leaking to/from ${OVERLAY4} for this to work.
EOF
}
