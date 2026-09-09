# Staging configuration

Owner: OpenMedical. Scope: OpnForm on the existing shared staging VM. See [deployment policy](../../DEPLOYMENT.md).

## Layout

- `compose.yaml`: isolated `opnform-stg` project; PostgreSQL and Redis have no published ports and use an internal network.
- `nginx.conf`: application ingress at `127.0.0.1:3080`, behind the existing Caddy. API services have outbound access for mail and integrations.
- `check-volume.sh`: verifies the actual mounted device, writable ext4 filesystem, and data directories.
- `opnform-stg.service`: guarded startup after Docker and the Volume mount; stops the stack if systemd deactivates the mount.
- `runtime.example`: placeholders for an external root-owned runtime configuration. Never store completed secrets in this directory.
- `deploy.py`: receives deployment credentials over SSH stdin, creates application keys only on first deployment, installs the SMTP secret separately, pulls the exact images, and restarts the guarded service.

## GitHub delivery configuration

The prepared workflow uses GitHub-hosted runners for checks and image builds, then restricted SSH for deployment. It has not been published or run yet. The deploy account cannot open a shell, transfer files, forward connections, use the Docker group, or run arbitrary `sudo` commands. An administrator installs root-owned deployment code separately from the workflow.

In the repository's `staging` Environment, configure `SMTP_PASSWORD`, `STAGING_HTTP_PASSWORD`, and `STAGING_SSH_KEY` as secrets, and `STAGING_KNOWN_HOSTS` as a variable containing the independently verified SSH host-key entry for `142.132.167.249`. The HTTP password must be unique and at least 16 characters. The username is `venova`. The matching deployment public key must be authorized on the server. SMTP and restricted SSH delivery access are configured; the HTTP password is still required.

`runtime.env` holds persistent generated application keys. `smtp.env` receives `MAIL_PASSWORD` from GitHub on each deployment. Both are root-only files under `/etc/opnform/stg`. The non-secret `release.env` in the deployment directory records the image digests, and `previous-release.env` retains the preceding manifest. No secret values are stored in release manifests or artifacts.

## Prepare before first start

1. Install this directory at `/opt/opnform/deploy/stg`. Verify that port 3080 is available before using the configured binding.
2. With `/mnt/HC_Volume_106834335` mounted from `/dev/disk/by-id/scsi-0HC_Volume_106834335`, create `opnform/postgres`, `opnform/redis`, and `opnform/storage` beneath it. Never create these paths while the Volume is absent. The upstream container entrypoints set data ownership on initialization.
3. The deployment script provisions `/etc/opnform/stg/runtime.env` and `/etc/opnform/stg/smtp.env` with directory mode 0700 and file mode 0600. For manual provisioning use `runtime.example`, `smtp.example`, and `release.example` as schemas. Preserve application keys across deployments. R2 credentials are not required for staging.
4. Validate without printing resolved secrets:

   ```bash
   cd /opt/opnform/deploy/stg
   bash check-volume.sh
   docker compose --env-file /etc/opnform/stg/runtime.env --env-file ./release.env config --quiet
   docker compose --env-file /etc/opnform/stg/runtime.env --env-file ./release.env pull
   ```

5. Install `opnform-stg.service` into `/etc/systemd/system/`, run `systemctl daemon-reload`, then `systemctl enable --now opnform-stg.service`. Startup waits for container health and removes this project's containers if startup fails. The API applies upstream database migrations before workers start.
6. The administrator-installed Caddy import allows the fixed deploy command to install the `stg-forms.venova.cz` route. The route requires Basic Auth, adds `X-Robots-Tag: noindex, nofollow, noarchive`, and proxies to `127.0.0.1:3080`. The deploy command validates the complete shared Caddy configuration before reload and restores the previous site fragment on validation failure. The ingress assumes HTTPS terminates at Caddy; never expose port 3080 publicly.
7. Check HTTPS and manually create, publish, and submit a synthetic form. Verify a file upload and authorized download, and verify that an expired or modified download signature is rejected. Runtime validation is required before calling this deployment ready.

## File storage

Staging uses the upstream `local` filesystem with private visibility. Uploads and locally generated files reside under `/mnt/HC_Volume_106834335/opnform/storage/app` on the same Volume as PostgreSQL and Redis, in a separate directory. The API, worker, and scheduler share this storage mount.

The ingress does not expose the storage directory as static files. OpnForm generates signed temporary URLs for local downloads; verify access through the application during first-run checks. Local staging storage does not validate the production R2 integration.

## Lifecycle

Use `systemctl restart opnform-stg.service` for a guarded restart and `systemctl stop opnform-stg.service` to stop the stack. Pull the approved release images before restarting. Do not use direct Compose startup, Docker restart, or container restart policies: those bypass the mount guard. All containers deliberately use `restart: "no"`.

The oneshot unit checks health at startup; it does not continuously monitor or automatically recover unhealthy or exited containers. An operator must investigate and restart the unit after a runtime failure. A storage I/O failure is not necessarily a systemd mount deactivation and needs separate monitoring. Continuous health monitoring will be addressed with deployment operations.

Staging uses disposable synthetic data. No scheduled backups or pre-deployment backups are configured or required. A rollback changes application images only and does not undo migrations.
