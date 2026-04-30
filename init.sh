#!/bin/bash
# One-time init — connects as root on port 22, creates admin user, hardens SSH, installs fail2ban/UFW.
# SSH stays on port 22 (default). Supports both SSH key and password authentication.
# If vps_ssh_private_key_file is set in group_vars/vps.yml, the key will be used.
# Otherwise, falls back to vps_initial_ssh_password from the vault.
ansible-playbook -i ansible/inventory.ini ansible/init.yml --ask-vault-pass "$@"
