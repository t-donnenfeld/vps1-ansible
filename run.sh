#!/bin/bash
# Regular configuration run — connects as admin on port 22 (default SSH)
# To run an initial backup after deployment: ansible-playbook -i ansible/inventory.ini ansible/initial-backup.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass "$@"
