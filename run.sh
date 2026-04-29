#!/bin/bash
# Regular configuration run — connects as admin on port 55022
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass "$@"
