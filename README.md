# server-config

Ansible-based VPS provisioning for:

- Traefik + Let's Encrypt
- Authelia (OIDC/SSO)
- Postgres
- Vikunja
- Basic host hardening (UFW, Fail2ban, SSH hardening, unattended upgrades)

Target OS: Ubuntu 24 (Contabo VPS).

## Repository layout

- `ansible/site.yml`: main playbook
- `ansible/inventory.ini`: target host inventory
- `ansible/group_vars/vps.yml`: non-secret settings
- `ansible/group_vars/vps.vault.yml`: encrypted secrets (Ansible Vault)
- `run.sh`: convenience command to run the playbook

## Prerequisites

- Ansible installed locally
- SSH key available locally (default: `~/.ssh/id_ed25519`)
- Vault file encrypted (`ansible-vault encrypt ansible/group_vars/vps.vault.yml`)
- Required collection installed:

```bash
cd ansible
ansible-galaxy collection install community.general
```

## Configuration

Edit:

- `ansible/inventory.ini` (`ansible_host`)
- `ansible/group_vars/vps.yml` (domain, user, ports, behavior flags)
- `ansible/group_vars/vps.vault.yml` (passwords/secrets only)

Important flags in `vps.yml`:

- `bootstrap`: first-run mode toggle
  - `true`: fresh VPS bootstrap (root/password via port 22)
  - `false`: hardened mode (admin user + key + `ssh_port`)
- `ssh_port`: target hardened SSH port (default in this repo: `55022`)

## Recommended run flow

### 1) Bootstrap

Run

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass \
  -e bootstrap=true
```

### 2) Transition to hardened mode

Verify:

```bash
ssh -p 55022 theo@YOUR_VPS_IP
```

Then

```bash
sh run.sh
```

## Vault and secrets

- Keep secrets only in `ansible/group_vars/vps.vault.yml`
- Encrypt file:

```bash
ansible-vault encrypt ansible/group_vars/vps.vault.yml
```

- Edit encrypted file:

```bash
ansible-vault edit ansible/group_vars/vps.vault.yml
```

