## Context

See `proposal.md` for motivation. The constraints that shape the approach:

- The deploy runs as root on the staging host from a payload on stdin, under a lock, with `os.environ.clear()` and a fixed `PATH`. It accepts no command line release parameters and prints no credentials. Any new step has to fit that shape.
- Images are pulled inside a `tempfile.TemporaryDirectory` registry config, so the GHCR credential never lands in the root Docker config. Anything that needs the newly pulled images by digest has to run inside that block, or rely on the images already being in the local store afterwards.
- Every service in `compose.yaml` carries `restart: "no"`. Container lifecycle belongs to the systemd unit, which is why the deploy reached for `systemctl restart` in the first place.
- `/opt/opnform/deploy/stg` is not synced by the deploy workflow. The runner may only execute `/usr/bin/python3 -I /opt/opnform/deploy/stg/deploy.py`, per `sudoers.runner`. Changing any file in that directory is an administrator action over the management SSH path.
- `apps/clinic/deploy/lib/deploy.sh` already implements the target pattern for this organization: pull by digest, run schema work as a one-shot, then `up --detach --no-deps --force-recreate` per service with health waits, never `down`.

## Goals / Non-Goals

**Goals:**

- Staging deploys stop stopping the database, the cache, and the routing tier.
- Schema work happens at a point in the deploy where its cost is not also an outage.
- The deploy keeps its current failure posture: any failing step aborts before the next mutation, and the operator is told to inspect service health rather than shown secrets.
- The change is portable to `deploy/prod` without redesign, because the two directories are near-identical today and should stay that way.

**Non-Goals:**

- Eliminating the swap gap. Requests in flight while `api` and `ui` are replaced will see 502s through `ingress`.
- Trimming the remaining `api` startup work. Telemetry initialization, Passport key generation and `optimize` still run on every container start. They are seconds, not minutes, and removing migrations is what makes them the tail rather than the head.
- Changing how releases are built, pinned, verified, or dispatched. The GHCR digest flow is already correct and is untouched.

## Decisions

### Drive Compose from the deploy, not through the systemd unit

`deploy.py` issues the migration step and `docker compose up -d --wait --wait-timeout 240 --pull never` itself, replacing the `systemctl restart` call. Compose computes the delta: services whose image digest and configuration are unchanged are left alone, so `db`, `redis`, `ingress` and `api-internal` keep running.

Alternatives considered:

- *Add `ExecReload` and call `systemctl reload-or-restart`.* This keeps systemd as the only mutator, which is tidier. It was rejected as the primary mechanism because the migration step has to run between the pull and the swap, and a unit's `ExecReload` is the wrong place for a step that can legitimately fail and must abort the deploy. It also puts the whole deploy's success behind systemd's exit-code plumbing rather than the script's own.
- *Per-service `up --no-deps --force-recreate` in dependency order, as clinic does.* More explicit and more observable, and it is where this should end up if the swap ever needs ordering control. Rejected for now because `--force-recreate` would replace containers whose release content did not change, which contradicts the first requirement in the spec, and because a blanket `up -d --wait` already gets the delta right with far less code to maintain across two environment directories.

`ExecReload` is still added to `opnform-stg.service`, mirroring `ExecStart`. Not as the deploy path, but so that an operator who wants to converge a drifted host has a verb that is not `restart`. If `systemd-analyze verify` rejects `ExecReload` on a `Type=oneshot` unit, the fallback is to document the equivalent `docker compose` invocation in `deploy/stg/README.md` and drop the unit change. Either way the spec requirement is met; only the ergonomics differ.

### Keep routing pointed at the services it routes to

`ingress` and `api-internal` name their upstreams literally: `proxy_pass
http://ui:3000` and `fastcgi_pass api:9000`. nginx resolves a literal upstream
name once, when it loads its configuration, and caches the address for the life
of the process. That is invisible today because a deploy replaces every
container, this one included. Once the deploy stops replacing them, they keep
addresses that `api` and `ui` no longer hold, and Docker hands the replaced
containers whatever addresses were freed, in whatever order they are created.

Measured, not assumed. With four application services recreated under a proxy
that was not recreated, requests for `api` arrived at the `worker` container and
requests for `ui` arrived at `api`. Forcing the addresses to move, by pinning
placeholder containers to the ones `api` and `ui` had just released, the
unchanged configuration answered 502 on both routes.

Both files therefore resolve through a variable against Docker's embedded DNS:

```
resolver 127.0.0.11 valid=10s ipv6=off;
set $api_backend api:9000;
fastcgi_pass $api_backend;
```

nginx re-resolves per request, with `valid=10s` overriding the long TTL the
embedded resolver returns. The same forced move against this configuration
routed correctly on both the proxied and the FastCGI path.

Delivering it needs one more thing. `install-runner-host.sh` installs a fixed
list of files, and `nginx-internal.conf` was not on it, in either environment.
The file reached the staging host by hand, which is why staging runs. So a
reinstall would deliver the updated `nginx.conf` and leave the internal one
stale, fixing the public route and not the one server-side rendering uses. The
installer list is corrected alongside, and a test now asserts the installer
ships every file the compose file bind-mounts.

This was not in the original task list. It is load-bearing rather than
incidental: without it the first converging deploy either fails at `up --wait`,
because the ingress healthcheck proxies to a `ui` that has moved, or serves
cross-wired traffic. A second effect is welcome: nginx refuses to start when a
literal upstream does not resolve, which a variable avoids, so `ingress` no
longer depends on its upstreams existing at the moment it starts.

Alternatives considered:

- *Reload nginx after the swap.* `docker compose exec ingress nginx -s reload`
  re-resolves without replacing the container, so it satisfies the spec too.
  Rejected because it has to happen between the swap and the health wait, and
  `up -d --wait` is one command. Splitting it into `up -d`, two reloads, then a
  separate wait gives up the single convergence step for a step order that has
  to be maintained by hand.
- *Recreate `ingress` and `api-internal` every deploy.* Cheap, nginx starts in
  under a second. Rejected because the spec's first requirement names both as
  services a deploy must not recreate, and because it leaves the stale-address
  behavior in place for every replacement that is not a deploy.

### Move migrations out of container startup with a role, not an entrypoint override

The fork's `docker/php-fpm-entrypoint` already dispatches on the command string to pick a role. It gains a `migrate` role for commands containing `artisan migrate`, which runs PHP configuration and the existing database wait and then execs the command, and nothing else. Separately, the `api` role's migration call is placed behind `OPNFORM_RUN_MIGRATIONS`, defaulting to `true`.

Alternatives considered:

- *Override the entrypoint at run time (`--entrypoint bash`).* No fork change at all, which is attractive. Rejected because it skips `apply_php_configuration` and the database wait, so the migration runs under different PHP settings than the application and races a cold database. It also puts deployment knowledge into a Compose invocation rather than into the image, where the next person will not find it.
- *Leave migrations in the `api` role and accept them running twice.* `migrate --force` is idempotent, so this is safe, but it keeps `api` readiness gated on schema work, which is the whole problem.

The default of `true` matters: `docker-compose.yml`, `docker-compose.dev.yml`, `docker-compose.e2e.yml` and `docker-compose.codex.yml` are untouched and keep today's behavior, and so does anyone running the upstream image.

### Staging always migrates, and does not detect pending migrations

The deploy runs the migration step unconditionally. When nothing is pending it is a fast no-op.

Detection is only worth building where it gates something expensive. Staging has no pre-migration dump, so there is nothing to gate. Production does, and the follow-up change will need to answer how to detect pending migrations on Laravel v11.48.0 before it can make that dump conditional. Building the detection here, unused, would mean shipping an unverified mechanism into the environment that does not need it.

### Production keeps today's behavior, and its intended shape is recorded here

`deploy/prod` is untouched. The follow-up is expected to take a different shape than staging, and recording why here saves re-deriving it:

```
  prod deploy
      |
      +-- pending migrations?
              |                    |
             NO                   YES
              |                    |
              v                    v
        hot path              today's ceremony
        no dump               stop writers, pg_dump,
        no migration          migrate, swap
        converge only
```

The reasoning: this fork's own commits never carry migrations (branding, a redirect, a PDF footer, CI), so the hot path covers effectively all of its own deploys. Migrations arrive only with upstream merges, in batches, and roughly 12% of OpnForm's migrations perform a destructive or type-changing operation inside `up()`. An upstream merge is therefore both the longest exposure to a schema mismatch and the rarest deploy, which is the worst combination to serve with a newly written code path. Keeping the existing ceremony on that branch means the rare high-stakes deploy runs code that has been running all along.

Production's daily backup (`backup.py`, 03:47 UTC, `pg_dump --format custom` piped through `age` to R2) already dumps the live database without stopping any service, so a live dump is established practice on this host and is not a new risk for the hot path.

## Risks / Trade-offs

**Previous release's code runs against the migrated schema during the swap** → The window is the time for new `api` and `ui` containers to become healthy, roughly 15 to 40 seconds. Harmless for additive migrations, and this fork's own commits carry none. Contained to staging by this change, which is also what makes staging a useful rehearsal: if the window bites, it bites where nobody is filling in a form. The production follow-up avoids it entirely on the branch where it matters.

**A new container that never becomes healthy leaves the environment down** → Compose removes the old container before starting its replacement, so an unhealthy new `api` means an outage. This is not a regression, today's `down` then `up` has the same exposure, but it is no longer masked by the fact that everything was down anyway. Mitigation: `--wait` makes the deploy fail rather than report success, `release.env` is copied to `previous-release.env` before being overwritten, and recovery is to restore that file and converge again.

**Re-running `install-runner-host.sh` could not install anything** → The opposite of what this note first assumed. The script refused to run on a host that already had a runner, and it refused *after* installing the deployment files and *before* `systemctl daemon-reload`, so a re-install wrote a unit that systemd never loaded and exited 1 indistinguishably from failing early. It also demanded a registration token it had no use for. The refusal was right in spirit, a re-install must never silently re-register the runner, so it now skips registration rather than failing and reads a token only when there is something to register. There is still no lighter sanctioned path, since the runner's sudoers grant is pinned to that one script's output. Mitigation: treat it as one administrator step, and confirm the runner is online and the unit is loaded before the first deploy through it.

**`ExecReload` may not be accepted on a `Type=oneshot` unit** → It is. `systemd-analyze verify` flags unknown keys when given one, flagged nothing here, and registered a fourth exec command where the previous unit had three. The documentation fallback was not needed. Does not affect the deploy path.

## Migration Plan

1. Fork change merges first, through a PR against `OpenMedical-cz/OpnForm`, with `CUSTOMIZATIONS.md` updated in the same PR. Merging publishes new image digests automatically.
2. Deploy repo change merges second.
3. Host bundle is reinstalled, one administrator step, and the unit is reloaded.
4. First deploy is observed against a request loop on `stg-forms.venova.cz`, recording the outage duration for comparison.

Ordering is safe in either direction. An image built before step 1 ignores `OPNFORM_RUN_MIGRATIONS` and migrates on startup as it does today, and `migrate --force` is idempotent, so no interleaving of steps 1 and 2 can skip migrations.

Rollback for the deploy mechanism itself is to restore the previous `deploy.py`, `compose.yaml` and unit file on the host and reload, which returns to `systemctl restart` behavior. Rollback for a bad release is unchanged in principle and cheaper in practice: restore `previous-release.env` and converge, instead of a full restart.

## Open Questions

- How to detect pending migrations on Laravel v11.48.0, whether `migrate:status --pending` exists there and whether its exit code is usable as a gate. Deferrable: it is required only by the production follow-up, and staging's design does not depend on the answer.
- Whether the swap gap is small enough in practice to leave production on a hot path for migration-carrying releases too. Answerable only with staging numbers, which this change produces.
