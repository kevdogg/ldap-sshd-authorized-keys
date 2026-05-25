# LDAP SSH Authorized Keys

This project configures OpenSSH to retrieve SSH public keys from OpenLDAP using `AuthorizedKeysCommand`.

The implementation uses:

```text
sshd
  -> AuthorizedKeysCommand
      -> ldapsearch
          -> OpenLDAP sshPublicKey attribute
```

This allows centralized SSH public key management while preserving optional local fallback behavior when LDAP is unavailable.

---

# Tested Platforms

| Distribution | Status |
|---|---|
| Arch Linux | Working |
| Ubuntu Server | Working |

Validated Features:

- LDAPS connectivity
- Internal CA trust installation
- Automatic LDAP client installation
- SSH AuthorizedKeysCommand integration
- Multiple LDAP sshPublicKey values
- sshd_config.d Include insertion
- SSH certificate coexistence detection
- ssh.service / sshd.service detection
- Local authorized_keys fallback during LDAP failure

---

# LDAP Schema

This implementation assumes the OpenSSH LDAP schema is already loaded and users contain:

```text
objectClass: ldapPublicKey
sshPublicKey: ssh-ed25519 AAAA...
ssh -T git@github.com                                                                              99.7.1.104  ─╯
Hi kevdogg! You've successfully authenticated, but GitHub does not provide shell access.```

Example LDAP entry:

```ldif
dn: cn=kevdog,ou=users,dc=ldap,dc=gohilton,dc=com
objectClass: inetOrgPerson
objectClass: ldapPublicKey
cn: kevdog
sshPublicKey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
sshPublicKey: ssh-ed25519 AAAAC3NzaSecondKey...
```

---

# Files Installed

| File                                           | Purpose               |
| ---------------------------------------------- | --------------------- |
| `/usr/local/sbin/ldap-authorized-keys`         | OpenSSH LDAP helper   |
| `/etc/ssh/ldap-authorized-keys.secret`         | LDAP bind password    |
| `/etc/ssh/sshd_config.d/10-ldap-authkeys.conf` | OpenSSH configuration |

---

# SSH Authentication Behavior

The helper implements the following policy:

```text
LDAP reachable + LDAP key exists
    -> authenticate using LDAP key

LDAP reachable + no LDAP key
    -> deny public key auth

LDAP unavailable / timeout / bind failure
    -> fallback to ~/.ssh/authorized_keys
```

This avoids local file "racing" against LDAP while still preserving break-glass access during LDAP outages.

---

# Requirements

## Server Packages

Install:

### OpenSSH

Already present on most systems.

### Automatic LDAP Client Installation

If OpenLDAP client tools are missing, the installer will attempt to install them automatically.

| Distribution | Package Installed |
|---|---|
| Arch Linux | `openldap` |
| Ubuntu / Debian | `ldap-utils` |
| Rocky / RHEL / AlmaLinux / Fedora | `openldap-clients` |

The installer currently supports automatic LDAP client installation on:

- Arch Linux
- Ubuntu
- Debian
- Rocky Linux
- RHEL
- AlmaLinux
- Fedora

If automatic installation is unsupported or fails, install `ldapsearch` manually and rerun the installer.

---

# LDAP Service Account

Example bind account:

```ldif
dn: cn=ssh-key-reader,ou=services,dc=ldap,dc=gohilton,dc=com
objectClass: top
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: ssh-key-reader
description: LDAP bind account for OpenSSH authorized key lookup
userPassword: {SSHA}...
```

The account only requires LDAP read access to:

```text
cn
sshPublicKey
```

---

# Secret File

Create next to the installer script:

```bash
printf '%s' 'YOUR_BIND_PASSWORD' > ldap-authorized-keys.secret
```

Important:

```text
Do NOT use:
  echo 'password' > file

This adds a trailing newline which breaks ldapsearch -y.
```

Verify:

```bash
od -An -tx1 -c ldap-authorized-keys.secret
```

No trailing `0a` should exist.

---

# Installation

Run as root:

```bash
sudo bash install-ldap-authkeys.sh
```

The installer:

* Creates `sshd-ldap` service user
* Installs helper script
* Installs LDAP bind secret
* Configures sshd
* Validates sshd configuration
* Reloads sshd

---

# Installed SSH Configuration

The installer creates:

```sshconfig
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/sbin/ldap-authorized-keys %u
AuthorizedKeysCommandUser sshd-ldap
```

---

# Testing

## Test LDAP Helper

```bash
sudo -u sshd-ldap /usr/local/sbin/ldap-authorized-keys kevdog
```

Expected:

```text
ssh-ed25519 AAAA...
```

---

## Test Active SSH Configuration

```bash
sshd -T | grep -i authorizedkeys
```

Expected:

```text
authorizedkeyscommand /usr/local/sbin/ldap-authorized-keys %u
authorizedkeyscommanduser sshd-ldap
```

---

## Test SSH Login

```bash
ssh -vvv kevdog@server
```

---

# SSHD Logging

Example successful login:

```text
Accepted key ED25519 SHA256:...
found at /usr/local/sbin/ldap-authorized-keys %u:1

Accepted publickey for kevdog
```

---

# LDAP Logging

Recommended OpenLDAP log level:

```text
olcLogLevel: sync stats
```

Example LDAP query log:

```text
SRCH base="ou=users,dc=ldap,dc=gohilton,dc=com"
filter="(&(objectClass=ldapPublicKey)(cn=kevdog))"
attr=sshPublicKey
```

---

# High Availability

Multiple LDAP servers may be specified:

```sh
LDAP_URI="ldaps://ldap1.example.com ldaps://ldap2.example.com"
```

The OpenLDAP client library will attempt failover automatically.

The helper also uses:

```text
-o nettimeout=3
-l 3
```

to prevent long SSH hangs during LDAP outages.

---

# Security Notes

* Helper runs as low-privileged `sshd-ldap` user
* LDAP bind password readable only by root and helper group
* OpenSSH never executes LDAP helper as root
* Username input is sanitized before LDAP filter usage
* Local fallback only occurs when LDAP fails entirely

---

# TLS / CA Notes

This project assumes LDAPS with a private/internal CA.

The installer attempts to install `ldap-ca.crt` into the host trust store automatically.

## Debian / Ubuntu

The CA file must use the `.crt` extension or `update-ca-certificates` may ignore it.

Installed to:

```text
/usr/local/share/ca-certificates/ldap-ca.crt
```

Then:

```bash
update-ca-certificates
```

## Arch Linux

Installed to:

```text
/etc/ca-certificates/trust-source/anchors/ldap-ca.crt
```

Then:

```bash
trust extract-compat
```

---
# Recommended Operational Model

Recommended:

```text
LDAP:
  normal user keys

~/.ssh/authorized_keys:
  emergency break-glass keys only
```

This preserves centralized management while retaining recovery access during LDAP outages.

