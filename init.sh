#!/bin/bash
# One-time init — connects as root on port 22, creates admin user, hardens SSH, changes port to 55022
ansible-playbook -i ansible/inventory.ini ansible/init.yml --ask-vault-pass "$@"
