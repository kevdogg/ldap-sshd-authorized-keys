#!/usr/bin/env bash
set -euo pipefail

HELPER_USER="sshd-ldap"
HELPER_PATH="/usr/local/sbin/ldap-authorized-keys"
SECRET_PATH="/etc/ssh/ldap-authorized-keys.secret"
SSHD_SNIPPET="/etc/ssh/sshd_config.d/10-ldap-authkeys.conf"

LDAP_URI="ldaps://ldap-active.gohilton.com"
BASE_DN="ou=users,dc=ldap,dc=gohilton,dc=com"
BIND_DN="cn=ssh-key-reader,ou=services,dc=ldap,dc=gohilton,dc=com"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRET_SOURCE="${SCRIPT_DIR}/ldap-authorized-keys.secret"


if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root." >&2
  exit 1
fi

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
  useradd --system --no-create-home --shell /usr/bin/nologin "$HELPER_USER"
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

sshd -t
systemctl reload sshd

echo "Installed LDAP SSH authorized keys helper."
echo
echo "Active sshd AuthorizedKeys settings:"
sshd -T | grep -i authorizedkeys || true
echo
echo "Test with:"
echo "  sudo -u $HELPER_USER $HELPER_PATH kevdog"
