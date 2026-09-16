## Why

Every OpnForm staging deploy takes the whole stack down, including Postgres and Redis, for minutes. The cause is `deploy/stg/deploy.py`, which finishes by calling `systemctl restart opnform-stg.service`. That unit is `Type=oneshot`, and its stop side is `docker compose down --timeout 60`, run twice. So a deploy destroys every container in the project and rebuilds it, then waits out the full healthcheck chain: `db`, `redis`, then `api` (whose entrypoint runs migrations, telemetry init, Passport key generation and `optimize` before php-fpm starts), then `ui` gated on `api`, then `ingress` gated on both.

None of that teardown is needed. CI already builds both images and pins them by digest, and the host already pulls them before the restart. The container replacement is the only part that has to happen, and Compose can do that in place. The teardown is an accident of using `systemctl restart` as the deploy verb on a unit whose stop side was written for real stops and reboots.

## What Changes

- The staging deploy converges the running project instead of restarting the systemd unit. `deploy.py` replaces `systemctl restart` with `docker compose up -d --wait`, so Compose recreates only the services whose image digest or configuration actually changed.
- `db`, `redis`, `ingress` and `api-internal` keep running across a deploy. Only `api`, `worker`, `scheduler` and `ui` are replaced.
- Database migrations move out of container startup into an explicit deploy step that runs while the previous release is still serving, instead of running inside the `api` container before it can accept traffic.
- The OpnForm fork's `docker/php-fpm-entrypoint` gains a `migrate` role, so an explicit migration run does not also execute the full API startup path, and an `OPNFORM_RUN_MIGRATIONS` flag that staging sets to `false`. The flag defaults to `true`, so upstream, development and Codex compose files are unaffected.
- `opnform-stg.service` gains an `ExecReload` that mirrors `ExecStart`, giving operators a non-destructive manual path. `ExecStop` and `ExecStopPost` are unchanged and continue to apply to real stops and reboots.
- `deploy/stg/tests/test_deploy.py` is updated: the ordering assertion currently anchored on `('systemctl', 'restart', 'opnform-stg.service')` is re-anchored, and cases are added asserting that no `down` and no `systemctl restart` is issued, and that the migration step precedes the container swap.

Accepted consequence: running migrations before the swap creates a window, roughly the time it takes the new `api` and `ui` containers to become healthy, in which the previous release's code runs against the already-migrated schema. Today that window does not exist because everything is down while migrations run. Around 12% of OpnForm's 120 migrations perform a destructive or type-changing operation in `up()`, all of them arriving from upstream rather than from this fork's own commits, so the window is harmless for this fork's own deploys and carries real risk only on an upstream merge. Staging is the right place to carry that risk and to measure how much it actually costs.

Not in scope:

- Production. `deploy/prod` keeps its current behavior, including the unconditional pre-migration `pg_dump` that stops all writer services first. A follow-up change will address it, informed by what staging shows.
- Blue/green or rolling replacement of `api` and `ui`. This change reduces the outage to the container swap, it does not eliminate it. Requests in flight during the swap will see brief 502s through `ingress`.
- Detecting whether a release contains pending migrations. Staging has no pre-migration dump to gate, so it can simply always run `migrate --force`, which is a fast no-op when nothing is pending. Detection is only needed for the production follow-up.

## Capabilities

### New Capabilities

- `opnform-deployment`: How a released OpnForm image reaches a running environment, and what must remain true while it does. Covers which services a deploy is allowed to disturb, where database migrations run relative to the container swap, and which lifecycle verb the deploy uses.

### Modified Capabilities

None. No existing capability under `openspec/specs/` describes OpnForm deployment.

## Impact

Two repositories, only one of which is inside this planning root:

- `apps/opnform` (fork, nested repo in this workspace): `docker/php-fpm-entrypoint`, `CUSTOMIZATIONS.md`. Merged through a PR against `OpenMedical-cz/OpnForm` per the fork's documented process. Publishing new image digests is automatic once merged, via the existing `.github/workflows/venova-staging.yml`.
- `OpenMedical-cz/venova-opnform-deploy` (private, not checked out in this workspace): `deploy/stg/deploy.py`, `deploy/stg/compose.yaml`, `deploy/stg/opnform-stg.service`, `deploy/stg/tests/test_deploy.py`. This repository sits outside `allowedEditRoots`, so implementation there is a separate checkout and a separate PR.

Host: `142.132.167.249`, shared with the website and its CI runner. `/opt/opnform/deploy/stg` is not synced by the deploy workflow, it is installed by `install-runner-host.sh`, which requires a runner registration token on stdin. Picking up the new `deploy.py`, `compose.yaml` and unit file therefore needs the documented bootstrap one-liner plus `systemctl daemon-reload`. That is a manual, administrator-only step over the management SSH path.

Ordering is safe in either direction. An image built before the entrypoint change ignores `OPNFORM_RUN_MIGRATIONS` and still migrates on startup, and `migrate --force` is idempotent, so a partially rolled out state cannot skip migrations.

Unrelated observation, not addressed here: `install-runner-host.sh` installs `compose.yaml nginx.conf check-volume.sh runtime.example smtp.example release.example deploy.py opnform-stg.service`, and does not install `nginx-internal.conf`, although `compose.yaml` bind-mounts that file read-only into `api-internal` with `create_host_path: false`. Staging runs today, so the file reached the host by some other route, but a rebuilt host would fail to start `api-internal`.
