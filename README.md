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
- `run.sh`: convenience command to run the hardened provisioning
- `run_bootstrap.sh`: helper that only enforces the bootstrap SSH port before rerunning on the new port

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
  - `true`: minimal run that enforces the configured `ssh_port`, creates the admin user, and keeps SSH open on the bootstrap port until the hardened port is ready
  - `false`: full provisioning run over the hardened port (admin user + key)
- `ssh_port`: target hardened SSH port (default in this repo: `3322`)

## Recommended run flow

### 1) Bootstrap

Run

```bash
sh run_bootstrap.sh
```

That script runs the same playbook with `bootstrap=true` but skips long provisioning steps so it only reconfigures SSH and creates the admin user before you reconnect on the hardened port.

If UFW is already active on the host, the bootstrap run also opens the bootstrap and hardened ports so the new port becomes reachable before you rerun the full playbook.

### 2) Transition to hardened mode

Verify you can reach the server as the admin user over `ssh_port` (default `3322`) and then

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

## Selective Task Runs

You can choose which role imports to execute by using Ansible tags.
We’ve tagged the main tasks as follows:

- `common`: creates the bootstrap admin user when `bootstrap=true` and installs base packages/updates when `bootstrap=false`
- `security_bootstrap`: enforces the bootstrap SSH port when `bootstrap=true` and applies the full security hardening when `bootstrap=false`
- `docker`: Docker installation tasks (hardened provisioning only)
- `deploy_stack`: application stack deployment tasks (hardened provisioning only)
- `security_post_bootstrap`: cleanup tasks that trim the temporary bootstrap rules and restart SSH/BPF when `bootstrap=false`

To run only specific roles:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml \
  --tags docker,deploy_stack --ask-vault-pass
```

For an interactive prompt, add this at the top of `ansible/site.yml`:

```yaml
vars_prompt:
  - name: selected_tags
    prompt: "Enter comma-separated tags to run (e.g. common,docker)"
    private: no
```

Then run:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml \
  --tags "{{ selected_tags }}" --ask-vault-pass
```
