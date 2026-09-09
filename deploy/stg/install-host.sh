#!/usr/bin/env bash
# Administrator-only installation. Never called by the deployment workflow.
set -euo pipefail
[[ "$EUID" == 0 && "$#" == 1 ]] || { printf 'Run as root with a deployment public-key file.\n' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
public_key=$1
ssh-keygen -l -f "$public_key" >/dev/null
bash "$source_dir/check-volume.sh"

if ! id opnform-deploy >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/opnform-deploy --shell /bin/sh opnform-deploy
fi
# Refuse an existing account with any supplementary group membership.
[[ "$(id -Gn opnform-deploy)" == opnform-deploy ]] || { printf 'Unexpected deploy-user groups.\n' >&2; exit 1; }
install -d -o root -g root -m 0755 /var/lib/opnform-deploy
install -d -o root -g root -m 0755 /opt/opnform /opt/opnform/deploy /opt/opnform/deploy/stg
for file in compose.yaml nginx.conf check-volume.sh runtime.example deploy.py opnform-stg.service; do
    install -o root -g root -m 0644 "$source_dir/$file" "/opt/opnform/deploy/stg/$file"
done
install -d -o root -g root -m 0755 /usr/local/libexec /etc/ssh/authorized_keys
install -d -o root -g root -m 0755 /etc/caddy/sites-enabled
install -o root -g root -m 0755 "$source_dir/ssh-command.sh" /usr/local/libexec/opnform-stg-ssh-command
install -o root -g root -m 0644 "$public_key" /etc/ssh/authorized_keys/opnform-deploy
visudo -cf "$source_dir/sudoers"
install -o root -g root -m 0440 "$source_dir/sudoers" /etc/sudoers.d/opnform-stg
install -o root -g root -m 0644 "$source_dir/sshd.conf" /etc/ssh/sshd_config.d/90-opnform-deploy.conf
if ! /usr/sbin/sshd -t; then
    # Undo only this new drop-in; never reload an invalid SSH configuration.
    mv /etc/ssh/sshd_config.d/90-opnform-deploy.conf /etc/ssh/sshd_config.d/90-opnform-deploy.conf.failed
    exit 1
fi
install -o root -g root -m 0644 "$source_dir/opnform-stg.service" /etc/systemd/system/opnform-stg.service

caddy_import='import /etc/caddy/sites-enabled/*'
if ! grep -Fqx "$caddy_import" /etc/caddy/Caddyfile; then
    caddy_candidate=$(mktemp /etc/caddy/Caddyfile.opnform.XXXXXX)
    caddy_backup="/etc/caddy/Caddyfile.bak-opnform-$(date -u +%Y%m%dT%H%M%SZ)"
    cp /etc/caddy/Caddyfile "$caddy_candidate"
    printf '\n%s\n' "$caddy_import" >> "$caddy_candidate"
    caddy validate --config "$caddy_candidate" --adapter caddyfile >/dev/null
    cp -a /etc/caddy/Caddyfile "$caddy_backup"
    install -o root -g root -m 0644 "$caddy_candidate" /etc/caddy/Caddyfile
    rm -f "$caddy_candidate"
    systemctl reload caddy
fi
systemctl daemon-reload
systemctl enable opnform-stg.service
systemctl reload ssh
printf 'Restricted deployment access installed. Application not started.\n'
