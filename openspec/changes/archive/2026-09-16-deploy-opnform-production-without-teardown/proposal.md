## Why

Production deploys take `forms.venova.cz` down for minutes, and most of that outage buys nothing.

`deploy/prod/deploy.py` runs an unconditional pre-migration `pg_dump`. To take it, `capture_pre_migration_dump()` calls `compose stop` on `WRITER_SERVICES`, which is `ingress, ui, scheduler, worker, api`. Stopping `ingress` is the moment the site goes dark, and it happens *before* the images are pulled, so the outage also covers the pull. The deploy then finishes with `systemctl restart opnform-prod.service`, whose stop side is `docker compose down --timeout 60`, destroying Postgres, Redis and the routing tier and rebuilding the whole healthcheck chain.

The dump is worth having. Paying for it on every deploy is not. This fork's own commits carry branding, a redirect, a PDF footer and CI, never a migration, so on the overwhelming majority of production deploys the dump protects against a schema change that is not happening.

Staging now converges instead of tearing down, and the numbers are measured rather than hoped for: a release changing both image digests replaced only `api`, `worker`, `scheduler` and `ui` while `db`, `redis`, `ingress` and `api-internal` kept their container IDs, at a cost of 3 failed requests out of 79 sampled once a second. (Production later contradicted the proxy half of this: see `design.md`. `db` and `redis` do survive; `ingress` and `api-internal` are recreated as dependents of `api` and `ui`, at a cost of 14 failed requests out of 120.) Re-deploying an unchanged release replaced nothing and finished in 14 seconds, against 2m11s for the old teardown path. Production is the environment where that difference is worth money.

## What Changes

- **The pre-migration dump becomes conditional.** The deploy asks whether the release carries migrations the database has not applied. When it does not, no dump is taken, no writer service is stopped, and the deploy converges. When it does, today's ceremony runs unchanged: stop writers, dump, then proceed.
- **The deploy converges instead of restarting the unit,** as staging does. `systemctl restart opnform-prod.service` is replaced by an explicit migration step followed by `docker compose up --detach --wait`. `db`, `redis`, `ingress` and `api-internal` keep running on every deploy, including one that carries migrations.
- **Migrations still run, always.** Detection gates the expensive ceremony, not correctness. `php artisan migrate --force` runs on both paths; it is a verified no-op when nothing is pending, so a detection bug cannot leave the schema behind.
- **Detection failure is treated as pending.** `migrate:status --pending` exits 0 whether or not anything is pending, so its exit code cannot be the gate; it exits non-zero only when the command itself failed. The gate therefore reads the output, and any result that is not an unambiguous "nothing pending" takes the ceremony path.
- **The image pull moves before the gate.** Detection has to run against the release being deployed, so the pull can no longer sit after the dump.
- **`deploy/prod/nginx.conf` and `nginx-internal.conf` resolve upstreams per request,** as the staging files already do. Without this, leaving `ingress` and `api-internal` running across a deploy points them at addresses `api` and `ui` no longer hold.
- **`opnform-prod.service` gains an `ExecReload` mirroring `ExecStart`,** giving operators a converge verb that is not `restart`. `ExecStop` and `ExecStopPost` are unchanged.
- **`OPNFORM_RUN_MIGRATIONS=false` is set on the `x-api` anchor** in `deploy/prod/compose.yaml`, so application containers stop gating readiness on schema work.

Not in scope:

- Eliminating the swap gap. Requests in flight while `api` and `ui` are replaced will still see brief 502s.
- Changing what the dump contains, where it is kept, or how many generations are retained. `PRE_MIGRATION_KEEP`, the 5 GiB free-space floor and the pruning are untouched.
- The daily encrypted backup (`backup.py`, 03:47 UTC). It is independent of the deploy and is not affected.
- Blue/green or rolling replacement.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `opnform-deployment`: adds requirements covering the pre-release snapshot. The capability currently prohibits stopping services to deliver a release but says nothing about stopping them to protect data, which production legitimately does. This change states when a snapshot is required, that an environment may stop write traffic to take a consistent one, and that an environment which cannot determine whether the release changes the schema must assume it does.

## Impact

One repository, plus a host step:

- `OpenMedical-cz/venova-opnform-deploy` (private): `deploy/prod/deploy.py`, `deploy/prod/compose.yaml`, `deploy/prod/nginx.conf`, `deploy/prod/nginx-internal.conf`, `deploy/prod/opnform-prod.service`, `deploy/prod/tests/test_deploy.py`, `deploy/prod/README.md`.
- No fork change. `OPNFORM_RUN_MIGRATIONS` and the `migrate` role already ship in the image, delivered by the staging change. This is the ordering benefit of having done staging first.

Host: `89.167.33.175`, **shared with clinic production**. A mistake here reaches another team's live application, which is the single most important constraint on this change. The host has never had its deployment bundle reinstalled, so it is still running an `install-runner-host.sh` that refuses to run when a runner is configured, and that does not install `nginx-internal.conf`. Both are fixed in the repository already and arrive with the same install.

Two host facts carried over from the staging rollout, both of which cost time there:

- `/root/venova-opnform-deploy` is a transferred copy, not a git checkout, so bringing it to a merged commit is a re-transfer.
- A single-file bind mount pins a container to that file's inode. Changing `nginx.conf` on the host does not reach a running `ingress`, and Compose will not recreate it because its service definition has not changed. Both proxies need one deliberate recreate.
