## Context

See `proposal.md` for motivation. The constraints that shape the approach:

- **The host is shared with clinic production** (`89.167.33.175`). Anything that fills its root disk or destabilizes Docker reaches another team's live application. `ensure_pre_migration_disk_space()` already refuses to deploy below a 5 GiB floor for exactly this reason, and that check stays.
- The deploy runs as root from a payload on stdin, under a lock, with `os.environ.clear()` and a fixed `PATH`. It accepts no command line release parameters and prints no credentials. Any new step has to fit that shape.
- Images are pulled inside a `tempfile.TemporaryDirectory` registry config so the GHCR credential never lands in the root Docker config.
- Every service in `compose.yaml` carries `restart: "no"`.
- `/opt/opnform/deploy/prod` is installed by `install-runner-host.sh` over the management SSH path. The runner may only execute `/usr/bin/python3 -I /opt/opnform/deploy/prod/deploy.py`.
- The staging change (`2026-09-16-deploy-opnform-staging-without-teardown`) already delivered the entrypoint's `migrate` role and `OPNFORM_RUN_MIGRATIONS` into the image, and already fixed the shared installer so it ships `nginx-internal.conf` and runs on a host that has a runner.

## Goals / Non-Goals

**Goals:**

- A production deploy that carries no schema change costs no dump and no stopped service.
- A production deploy that does carry one keeps today's protection, unchanged.
- `db`, `redis`, `ingress` and `api-internal` survive every deploy, including one with migrations.

  **Measured on production, 2026-09-16: only `db` and `redis` do.** `ingress` and
  `api-internal` are recreated on any deploy that replaces `api` or `ui`, because
  Compose recreates a service's dependents and both declare `depends_on` on them.
  `deploy/stg/compose.yaml` declares identical `depends_on`, so the staging numbers
  quoted in `proposal.md` cannot have been measured the way they are described.
  The proxies surviving needs `depends_on` removed, which the nginx change makes
  possible (variable upstreams no longer have to resolve at configuration load) but
  which is not in this change. Tracked separately.
- The failure posture does not weaken anywhere: every failing step aborts before the next mutation.

**Non-Goals:**

- Eliminating the swap gap for `api` and `ui`.
- Changing what the dump contains, where it lives, or its retention.
- Touching the daily encrypted backup.
- Making the clinic application's deploy converge. Different code, different change.

## Decisions

### Gate the dump, not the migration

The detection result decides whether to take a snapshot. It does **not** decide whether to migrate. `php artisan migrate --force` runs on both paths.

This deviates from the sketch recorded in the staging change, which showed the hot path as "no dump, no migration, converge only". The reason for the deviation is that the two decisions have wildly different failure costs. Skipping a dump that was not needed costs nothing. Skipping a migration that *was* needed leaves production running new code against an old schema, and the detection is the only thing standing between those two outcomes.

Since `migrate --force` is a verified no-op when nothing is pending, running it unconditionally costs a couple of seconds and removes detection correctness from the critical path entirely. Detection then only has to be right about an expensive convenience, not about correctness.

```
  prod deploy
      |
      +-- pull new images
      |
      +-- pending migrations?  (three-way)
      |        |            |              |
      |     NO (proven)   YES          UNREADABLE
      |        |            |              |
      |        |            +------+-------+
      |        |                   |
      |        |            stop writers, pg_dump
      |        |                   |
      |        +-------------------+
      |                  |
      +-- migrate --force  (no-op on the NO path)
      |
      +-- compose up --detach --wait
```

### Detection reads output, because the exit code cannot carry the answer

Measured against the real image on Laravel 11, `php artisan migrate:status --pending`:

| state | exit | output |
| --- | --- | --- |
| nothing pending | 0 | `INFO  No pending migrations.` |
| one migration pending | 0 | lists the migration, `Pending` |
| database unreachable | 1 | `SQLSTATE[08006] ... could not translate host name` |

The exit code separates *the command worked* from *the command failed*. It does not separate *pending* from *not pending*. This answers the open question the staging change left behind, and it rules out the clean `if returncode:` gate that question was hoping for.

So the gate is three-way and defaults to the safe side:

- non-zero exit → treat as pending
- exit 0 and output matches the no-pending marker → treat as not pending
- exit 0 and anything else → treat as pending

Only the middle case skips the dump, which matches the spec requirement that skipping rests on positive evidence.

Alternatives considered:

- *Parse the migration table directly with SQL.* Avoids depending on artisan's output wording. Rejected because it reimplements Laravel's notion of which migrations exist in the release, which is exactly the thing that changes between releases, and a wrong reimplementation fails silently in the direction of skipping the dump.
- *Compare `migrate:status` line counts before and after.* More output parsing, not less.
- *Have CI decide and put a flag in the release manifest.* Attractive, since CI has the diff. Rejected for now because it widens the payload the deploy accepts, and `validate_payload()` deliberately rejects any field it does not expect. Worth revisiting if the output parsing proves brittle.

The marker to match is `No pending migrations`, matched against the command's combined output. If a future Laravel changes that wording, the gate fails safe: it stops matching, every deploy takes a dump, and production goes back to today's cost rather than losing protection. A test pins the marker so the failure shows up as a red test rather than a silently slower deploy.

### Detection runs against the new image, so the pull moves earlier

`migrate:status --pending` has to see the migration files in the release being deployed, not the one already running. Today the pull happens after the dump. It moves before the gate.

This reorders the deploy but does not weaken it: the pull is not a mutation of the running environment, and `ensure_volume_before_mutation()` still runs first. One real benefit falls out of the reorder, which is that on the ceremony path the outage no longer includes the pull.

### Production converges, exactly as staging does

`systemctl restart opnform-prod.service` is replaced by the explicit migration step plus `docker compose up --detach --wait --wait-timeout 240 --pull never`, both inside the registry config block. `ExecReload` is added to the unit, mirroring `ExecStart`, and `systemd-analyze verify` already accepted this on staging's `Type=oneshot` unit.

Nothing here is novel. It is the staging change applied to a near-identical directory, which was the point of keeping the two directories similar.

### The nginx fix is not optional here either

`deploy/prod/nginx.conf` and `nginx-internal.conf` still name their upstreams literally. nginx resolves a literal upstream name once, at configuration load, and caches it for the life of the process. That is invisible while a deploy replaces every container, and becomes a fault the moment it stops.

Measured on staging: with `api` and `ui` forced onto new addresses under a proxy that was not recreated, the unchanged configuration answered 502 on both the proxied and the FastCGI route, and in a run where addresses were merely shuffled rather than freed, requests for `api` arrived at the `worker` container. Both prod files get the same `resolver 127.0.0.11 valid=10s ipv6=off` and variable-based upstream treatment.

## Risks / Trade-offs

**The proxies are recreated anyway** → The 502 window a deploy still costs is
`ingress` releasing `127.0.0.1:3080` while Compose replaces it, not the `api` and
`ui` swap this section was written to bound. Measured at 14 failed requests out of
120 sampled once a second. The per-request resolver is still required and still
correct — it is what makes a surviving proxy possible at all, and what protects a
deploy that replaces `api` or `ui` without replacing the proxy — but on its own it
does not shorten this window.

**The shared host** → Every step that writes to the root disk is already guarded by the 5 GiB floor, and that guard runs before writers stop and before any dump byte is written. This change adds no new writes to the root disk. It removes most of them, since most deploys will no longer dump at all.

**Detection wrongly reports nothing pending** → Would skip the dump on a release that does change the schema. Contained by running `migrate --force` regardless, so the schema still lands; what is lost is the rollback artifact, not the migration. Further contained by the daily encrypted backup, which is at most 24 hours stale. Accepted, and it is the reason the gate defaults to pending on anything ambiguous.

**Previous release's code runs against the migrated schema during the swap** → The window is the time for new `api` and `ui` containers to become healthy. On staging this cost 3 failed requests out of 79. Around 12% of OpnForm's migrations perform a destructive or type-changing operation in `up()`, and all of them arrive from upstream rather than from this fork, so the window carries real risk only on an upstream merge. That is also precisely the case that now takes the ceremony path, where writers are stopped anyway.

**A new container never becomes healthy** → `--wait` makes the deploy fail rather than report success, `previous-release.env` is written before `release.env` is overwritten, and recovery is to restore it and converge. This is not a regression: today's `down` then `up` has the same exposure.

**The host bundle has never been reinstalled** → It still carries an installer that refuses to run while a runner is configured, and that never installed `nginx-internal.conf`. Both are already fixed in the repository. The install therefore has to happen once, deliberately, with the proxies recreated afterwards.

## Migration Plan

1. The deploy repository change merges.
2. The host bundle is transferred and installed, one administrator step over the management SSH path. `/root/venova-opnform-deploy` is a copied directory, not a checkout, so this is a re-transfer. The installer needs nothing on stdin now that it skips registration when a runner exists.
3. `ingress` and `api-internal` are recreated once, deliberately, so they pick up the changed nginx configuration. A single-file bind mount pins a container to that file's inode, so installing a new file does not reach a running container, and Compose will not recreate them on its own because their service definitions have not changed. On staging this cost one failed request.
4. The first deploy is observed against a request loop on `forms.venova.cz`, on a release known to carry no migrations, so the hot path is exercised first.
5. The ceremony path is exercised on the next release that carries a migration, which in practice means the next upstream merge.

Rollback for the mechanism is to restore the previous `deploy.py`, `compose.yaml`, nginx files and unit on the host and reload, returning to `systemctl restart` behavior. Rollback for a bad release is to restore `previous-release.env` and converge.

## Open Questions

- Whether the hot path should also skip the `migrate --force` call once detection has proven itself over some number of deploys. Deferrable, and the answer is probably no: the call costs seconds and buys unconditional correctness.
- Whether CI should compute the pending-migration answer and carry it in the release manifest, replacing output parsing. Requires widening `validate_payload()`, which is deliberately strict. Revisit if the output marker proves brittle.
