#!/usr/bin/env bash
set -euo pipefail

detect_nologin_shell() {
  if [[ -x /usr/sbin/nologin ]]; then
    echo /usr/sbin/nologin
  elif [[ -x /sbin/nologin ]]; then
    echo /sbin/nologin
  elif [[ -x /usr/bin/nologin ]]; then
    echo /usr/bin/nologin
  else
    echo /bin/false
  fi
}

detect_sshd_service() {
  if systemctl list-unit-files --type=service --no-legend sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
    echo sshd.service
  elif systemctl list-unit-files --type=service --no-legend ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
    echo ssh.service
  else
    echo ""
  fi
}

install_ldap_ca() {
  local ca_source="${SCRIPT_DIR}/ldap-ca.crt"

  if [[ ! -f "$ca_source" ]]; then
    echo "WARNING: Missing ${ca_source}; skipping LDAP CA installation." >&2
    return 0
  fi

  if command -v update-ca-certificates >/dev/null 2>&1; then
    echo "Installing LDAP CA using update-ca-certificates..."
    install -o root -g root -m 0644 "$ca_source" \
      /usr/local/share/ca-certificates/ldap-ca.crt
    update-ca-certificates

  elif command -v trust >/dev/null 2>&1; then
    echo "Installing LDAP CA using p11-kit trust..."
    install -d -o root -g root -m 0755 \
      /etc/ca-certificates/trust-source/anchors
    install -o root -g root -m 0644 "$ca_source" \
      /etc/ca-certificates/trust-source/anchors/ldap-ca.crt
    trust extract-compat

  elif command -v update-ca-trust >/dev/null 2>&1; then
    echo "Installing LDAP CA using update-ca-trust..."
    install -d -o root -g root -m 0755 \
      /etc/pki/ca-trust/source/anchors
    install -o root -g root -m 0644 "$ca_source" \
      /etc/pki/ca-trust/source/anchors/ldap-ca.crt
    update-ca-trust

  else
    echo "WARNING: Could not detect CA trust update tool." >&2
    echo "Install ${ca_source} manually into this system's trust store." >&2
  fi
}

HELPER_USER="sshd-ldap"
HELPER_PATH="/usr/local/sbin/ldap-authorized-keys"
SECRET_PATH="/etc/ssh/ldap-authorized-keys.secret"
SSHD_SNIPPET="/etc/ssh/sshd_config.d/10-ldap-authkeys.conf"

# ldap-active.gohilton.com represents a HA DNS lookup tweak where technitium will return the active ldap server
# ldap servers within the dns lookup are:
#    ldap-prospect.gohilton.com
#    ldap-quincy.gohilton.com

LDAP_URI="ldaps://ldap-active.gohilton.com"
BASE_DN="ou=users,dc=ldap,dc=gohilton,dc=com"
BIND_DN="cn=ssh-key-reader,ou=services,dc=ldap,dc=gohilton,dc=com"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRET_SOURCE="${SCRIPT_DIR}/ldap-authorized-keys.secret"

SSHD_CONFIG="/etc/ssh/sshd_config"
INCLUDE_DIRECTIVE="Include /etc/ssh/sshd_config.d/*.conf"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$SSHD_CONFIG"; then
  echo "Adding sshd_config.d Include directive to ${SSHD_CONFIG}..."

  cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

  {
    echo "$INCLUDE_DIRECTIVE"
    echo
    cat "$SSHD_CONFIG"
  } > "${SSHD_CONFIG}.new"

  mv "${SSHD_CONFIG}.new" "$SSHD_CONFIG"
fi

NOLOGIN_SHELL="$(detect_nologin_shell)"
SSHD_SERVICE="$(detect_sshd_service)"

if [[ ! -f "$SECRET_SOURCE" ]]; then
  echo "ERROR: Missing ${SECRET_SOURCE}" >&2
  echo "Create it from ldap-authorized-keys.secret.example and do not commit it." >&2
  exit 1
fi

if ! command -v ldapsearch >/dev/null 2>&1; then
  echo "ERROR: ldapsearch not found. Install OpenLDAP client tools first." >&2
  exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
  echo "ERROR: sshd not found." >&2
  exit 1
fi

if ! id "$HELPER_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell "$NOLOGIN_SHELL" "$HELPER_USER"
fi

install -d -m 0755 /usr/local/sbin
install -d -m 0755 /etc/ssh
install -d -m 0755 /etc/ssh/sshd_config.d

# Install secret, stripping CR/LF so ldapsearch -y does not receive a bad password.
tr -d '\r\n' < "$SECRET_SOURCE" > "$SECRET_PATH"
chown root:"$HELPER_USER" "$SECRET_PATH"
chmod 0640 "$SECRET_PATH"

cat > "$HELPER_PATH" <<EOF
#!/bin/sh
set -eu

user="\$1"

case "\$user" in
  *[!a-zA-Z0-9._-]*|'')
    exit 0
    ;;
esac

LDAP_URI="$LDAP_URI"
BASE_DN="$BASE_DN"
BIND_DN="$BIND_DN"
BIND_PW_FILE="$SECRET_PATH"

ldap_output="\$(
  ldapsearch \\
    -LLL \\
    -o ldif-wrap=no \\
    -o nettimeout=3 \\
    -l 3 \\
    -H "\$LDAP_URI" \\
    -D "\$BIND_DN" \\
    -y "\$BIND_PW_FILE" \\
    -b "\$BASE_DN" \\
    "(&(objectClass=ldapPublicKey)(cn=\$user))" \\
    sshPublicKey 2>/dev/null
)" && {
  printf '%s\n' "\$ldap_output" | sed -n 's/^sshPublicKey: //p'
  exit 0
}

home="\$(getent passwd "\$user" | awk -F: '{print \$6}')"

if [ -n "\$home" ] && [ -r "\$home/.ssh/authorized_keys" ]; then
  cat "\$home/.ssh/authorized_keys"
fi
EOF

chown root:root "$HELPER_PATH"
chmod 0755 "$HELPER_PATH"

cat > "$SSHD_SNIPPET" <<EOF
AuthorizedKeysFile none
AuthorizedKeysCommand $HELPER_PATH %u
AuthorizedKeysCommandUser $HELPER_USER
EOF

install_ldap_ca

echo "Validating sshd configuration..."
if ! sshd -t; then
  echo "ERROR: sshd config validation failed. Not reloading SSH." >&2
  exit 1
fi

if sshd -T | grep -qi '^trustedusercakeys '; then
  echo "INFO: SSH user certificate trust is configured; leaving certificate settings untouched."
fi

if [[ -n "$SSHD_SERVICE" ]]; then
  echo "Reloading ${SSHD_SERVICE}..."
  if ! systemctl reload "$SSHD_SERVICE"; then
    echo "ERROR: Failed to reload ${SSHD_SERVICE}." >&2
    exit 1
  fi
else
  echo "WARNING: Could not detect ssh/sshd systemd unit. Config validated, but sshd was not reloaded." >&2
fi

echo "Installed LDAP SSH authorized keys helper."
echo
echo "Active sshd AuthorizedKeys settings:"
sshd -T | grep -i authorizedkeys || true
echo
echo "Test with:"
echo "  sudo -u $HELPER_USER $HELPER_PATH kevdog"
