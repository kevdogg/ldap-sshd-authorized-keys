#!/usr/bin/env bash
set -euo pipefail

# constants /config
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

# functions

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

install_ldap_client_tools() {
  local os_id="$1"

  if command -v ldapsearch >/dev/null 2>&1; then
    return 0
  fi

  echo "LDAP client tools not found; attempting installation..."

  case "$os_id" in
    arch)
      pacman -S --needed --noconfirm openldap
      ;;

    ubuntu|debian)
      apt-get update
      DEBIAN_FRONTEND=noninteractive \
        apt-get install -y ldap-utils
      ;;

    rocky|rhel|almalinux|fedora)
      dnf install -y openldap-clients
      ;;

    *)
      echo "ERROR: Unsupported OS for automatic LDAP client installation: ${os_id}" >&2
      echo "Install ldapsearch manually and rerun." >&2
      exit 1
      ;;
  esac

  if ! command -v ldapsearch >/dev/null 2>&1; then
    echo "ERROR: ldapsearch still not found after package installation." >&2
    exit 1
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

# main 

main() {
  local os_id
  local nologin_shell
  local sshd_service
  local trusted_user_ca

  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root." >&2
    exit 1
  fi
  
  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/ssh
  install -d -m 0755 /etc/ssh/sshd_config.d
  
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
  
  nologin_shell="$(detect_nologin_shell)"
  sshd_service="$(detect_sshd_service)"
  
  if [[ ! -f "$SECRET_SOURCE" ]]; then
    echo "ERROR: Missing ${SECRET_SOURCE}" >&2
    echo "Create it from ldap-authorized-keys.secret.example and do not commit it." >&2
    exit 1
  fi
  
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    os_id="${ID,,}"
  else
    echo "ERROR: Cannot determine operating system." >&2
    exit 1
  fi
  
  install_ldap_client_tools "$os_id"
  
  if ! command -v sshd >/dev/null 2>&1; then
    echo "ERROR: sshd not found." >&2
    exit 1
  fi
  
  if ! id "$HELPER_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell "$nologin_shell" "$HELPER_USER"
  fi
  
  
  # Install secret, stripping CR/LF so ldapsearch -y does not receive a bad password.
  tr -d '\r\n' < "$SECRET_SOURCE" > "$SECRET_PATH"
  chown root:"$HELPER_USER" "$SECRET_PATH"
  chmod 0640 "$SECRET_PATH"
  
cat > "$HELPER_PATH" <<EOF
#!/bin/sh
set -eu

user="\$1"

if [ -f /etc/ssh/ldap-authorized-keys.debug ]; then
  logger -t ldap-authorized-keys \
    "lookup user=$user from=${SSH_CONNECTION:-unknown}"
fi

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
  
  sshd_test_output="$(mktemp)"
  if ! sshd -t 2>"$sshd_test_output"; then
    cat "$sshd_test_output" >&2
    rm -f "$sshd_test_output"
    echo "ERROR: sshd config validation failed. Not reloading SSH." >&2
    exit 1
  fi
  
  if [[ -s "$sshd_test_output" ]]; then
    cat "$sshd_test_output" >&2
    rm -f "$sshd_test_output"
    echo "ERROR: sshd config validation produced stderr output. Not reloading SSH." >&2
    exit 1
  fi
  
  rm -f "$sshd_test_output"
  
  trusted_user_ca="$(sshd -G 2>/dev/null | sed -n 's/^trustedusercakeys[[:space:]]\+//Ip' | head -n1 || true)"
  
  if [[ -n "$trusted_user_ca" ]]; then
    echo "INFO: SSH user certificate trust is configured: TrustedUserCAKeys ${trusted_user_ca}"
    echo "INFO: Certificate settings are unchanged."
  fi
  
  if [[ -n "$sshd_service" ]]; then
    echo "Reloading ${sshd_service}..."
    if ! systemctl reload "$sshd_service"; then
      echo "ERROR: Failed to reload ${sshd_service}." >&2
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
}

# execution
main "$@"
