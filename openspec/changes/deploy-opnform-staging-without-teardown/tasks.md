## 1. Fork: move migrations out of container startup

Repository: `apps/opnform` (nested in this workspace). Merged via PR against `OpenMedical-cz/OpnForm` per `CUSTOMIZATIONS.md`.

- [x] 1.1 Add a `migrate` role to `docker/php-fpm-entrypoint` for commands matching `*"artisan migrate"*`, running `apply_php_configuration` and `wait_for_db` and then `exec "$@"`, and verify with `bash -n docker/php-fpm-entrypoint` plus a local `docker compose -f docker-compose.dev.yml run --rm --no-deps api php artisan migrate --force` whose output reports `Determined role: migrate` and contains no telemetry, Passport or `optimize` lines.
- [x] 1.2 Gate the `api` role's `apply_db_migrations` call behind `OPNFORM_RUN_MIGRATIONS`, defaulting to `true`, and verify both paths on `docker-compose.dev.yml`: unset, the api container still applies migrations on start; set to `false`, it starts without applying them and the app still serves.
- [x] 1.3 Record both entries in `CUSTOMIZATIONS.md` under "Current differences", including what to re-check after an upstream update (that the role dispatch still covers `artisan migrate` and that upstream has not moved the migration call out of `apply_db_migrations`), and verify the file lists both changes with their paths.
- [x] 1.4 Register the `openspec/` directory itself in `CUSTOMIZATIONS.md` as a fork customization, noting that it holds this fork's change planning, that it was initialized with `--tools none` so no AI tool file and no upstream-owned `AGENTS.md` is modified, and that upstream owns no path under it so it needs no attention during an upstream merge. Verify `CUSTOMIZATIONS.md` names the directory.
- [ ] 1.5 Open the PR against `OpenMedical-cz/OpnForm` base `main`, and verify `ci-cd.yml` is green and that merging produces a `venova-staging.yml` run publishing `opnform-api` and `opnform-client` digests for the merge SHA.

## 2. Deploy repository: converge instead of restart

Repository: `OpenMedical-cz/venova-opnform-deploy` (private, outside this planning root). Requires a separate checkout and its own PR.

- [x] 2.1 Check out the repository on a branch and verify the baseline is green with `python3 -m unittest discover -s deploy/stg/tests -v` before changing anything.
- [x] 2.2 Add `OPNFORM_RUN_MIGRATIONS: "false"` to the `x-api` anchor's `environment` in `deploy/stg/compose.yaml`, and verify the anchor is inherited by `api`, `worker` and `scheduler` by rendering the file with `docker compose -f deploy/stg/compose.yaml --env-file <sample runtime> --env-file deploy/stg/release.example config` and reading the variable back on all three services.
- [x] 2.3 Replace the `systemctl restart opnform-stg.service` call in `deploy/stg/deploy.py` with a migration step followed by `docker compose ... up -d --wait --wait-timeout 240 --pull never`, keeping both inside the temporary registry config block so the pulled digests resolve, and verify the existing `curl` smoke check and Caddy validate-and-reload tail still run after it.
- [x] 2.4 Update `deploy/stg/tests/test_deploy.py`: re-anchor the ordering assertion at line 82 that currently uses `('systemctl', 'restart', 'opnform-stg.service')` onto the migration step, and add cases asserting that no `down` subcommand and no `systemctl restart` is issued, and that the migration step precedes the `up` call. Verify with `python3 -m unittest discover -s deploy/stg/tests -v`.
- [x] 2.5 Add a test asserting the deploy aborts without issuing `up` when the migration step fails, covering the spec's failed-migration requirement, and verify it fails against the pre-change script and passes after.
- [x] 2.6 Add `ExecReload=` mirroring `ExecStart` to `deploy/stg/opnform-stg.service`, and verify acceptance with `systemd-analyze verify deploy/stg/opnform-stg.service`. If `ExecReload` is rejected on a `Type=oneshot` unit, drop the unit change and instead document the equivalent `docker compose ... up -d --wait` operator command in `deploy/stg/README.md`.
- [x] 2.7 Document the new deploy sequence in `deploy/stg/README.md`, stating that a deploy no longer stops `db`, `redis`, `ingress` or `api-internal`, and that rollback is restoring `previous-release.env` and converging. Verify the README no longer describes a restart-based deploy.
- [x] 2.8 Make `deploy/stg/nginx.conf` and `deploy/stg/nginx-internal.conf` resolve their upstreams per request, through a variable and `resolver 127.0.0.11 valid=10s ipv6=off`, so `ingress` and `api-internal` keep reaching `api` and `ui` after those are replaced without them. Verify with `nginx -t` on both files, and end to end by forcing `api` and `ui` onto new addresses under an ingress that is not recreated: the pre-change configuration must answer 502 on both the proxied and the FastCGI route, and the changed one must route correctly.
- [ ] 2.9 Open the PR and verify the repository's `ci.yml` checks pass, including `actionlint` and all three `unittest discover` suites.

## 3. Host rollout

Single administrator action over the management SSH path to `142.132.167.249`. Requires a fresh runner registration token on stdin, which also re-registers the Actions runner.

- [ ] 3.1 Update the host's checkout at `/root/venova-opnform-deploy` to the merged commit and re-run `install-runner-host.sh` with a freshly minted registration token, then verify `/opt/opnform/deploy/stg/deploy.py` matches the merged version, `systemctl daemon-reload` has been run, and the unit shows the new `ExecReload` under `systemctl cat opnform-stg.service`.
- [ ] 3.2 Verify the self-hosted runner is back online for `venova-opnform-deploy` and that the environment is still serving, by requesting `https://stg-forms.venova.cz/login` before any deploy is triggered.

## 4. Verify against the specification

- [ ] 4.1 Record a baseline: note container IDs for `db`, `redis`, `ingress` and `api-internal`, then trigger a deploy of a release with changed application digests, and verify after it that those four IDs are unchanged while `api`, `worker`, `scheduler` and `ui` have new IDs.
- [ ] 4.2 Re-deploy the same release unchanged and verify no container is replaced and the deploy reports success, covering the idempotent-deploy scenario.
- [ ] 4.3 Measure the outage across a deploy with a one-second request loop against `https://stg-forms.venova.cz/login`, and record the count of failed requests and the gap duration for comparison against the current behavior. This is the number the production follow-up needs.
- [ ] 4.4 Verify the migration ordering by deploying a release that carries a pending migration and confirming from the deploy log that migrations completed before any application container was replaced, and that the previous release answered requests while they ran.
- [ ] 4.5 Verify an application container start no longer migrates, by restarting `api` alone and confirming its log shows no migration output.
- [ ] 4.6 Verify the failure posture by deploying a release whose migration cannot succeed, confirming the deploy reports failure, no application container was replaced, and the previous release is still serving. Use a disposable branch image, not a real release.
