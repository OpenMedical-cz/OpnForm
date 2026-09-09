#!/bin/sh
set -eu
if [ "${SSH_ORIGINAL_COMMAND:-}" != 'deploy-opnform' ]; then
    printf 'Only deploy-opnform is allowed.\n' >&2
    exit 126
fi
exec /usr/bin/sudo -n /usr/bin/python3 -I /opt/opnform/deploy/stg/deploy.py
