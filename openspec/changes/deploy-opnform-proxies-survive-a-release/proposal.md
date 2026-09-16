## Why

`deploy-opnform-production-without-teardown` removed the teardown from a production
deploy. What it did not remove is the outage, and the reason turned out not to be
the one the design predicted.

Measured on production on 2026-09-16 (promotion run 35068805436): a release changing
both image digests cost **14 failed requests out of 120** sampled once a second, a
502 window from 07:30:36 to 07:30:50. That window is not the `api` and `ui` swap the
design bounded. It is `ingress` itself releasing `127.0.0.1:3080` while Compose
replaces it, which leaves Caddy with nothing to reach.

`ingress` and `api-internal` are replaced on every deploy that replaces `api` or
`ui`, because Compose recreates a service's dependents when it recreates the
service, and both declare `depends_on`:

```yaml
  api-internal:
    depends_on:
      api: { condition: service_healthy }
  ingress:
    depends_on:
      api: { condition: service_healthy }
      ui:  { condition: service_healthy }
```

`deploy/stg/compose.yaml` declares exactly the same, so the staging measurement the
previous change quoted — proxies keeping their container IDs — cannot have been what
it claimed, and the production task written against it expected something
unreachable.

The `depends_on` was load-bearing before that change and is not now. nginx resolves a
literal upstream name once, at configuration load, and **refuses to start** when it
does not resolve: `host not found in upstream "ui"`. Ordering the proxies behind
their upstreams was how that was avoided. Both configurations now resolve through a
variable and Docker's embedded resolver, so nginx starts regardless of whether `api`
and `ui` exist yet. The ordering constraint the `depends_on` encoded is gone; only
its side effect remains.

## What Changes

- **`ingress` and `api-internal` stop declaring `depends_on`,** so Compose has no
  reason to recreate them for a release that does not change their own definitions.
  They keep their containers, and keep holding `127.0.0.1:3080`, across a deploy.
- **`ingress` gains a healthcheck `start_period`.** Without the `depends_on` it can
  start before `ui` is healthy on a cold start, and its healthcheck renders a page
  through `ui`. At `retries: 6` and `interval: 10s` with no start period, it has 60
  seconds before it is declared unhealthy and `--wait` fails the deploy, against a
  `ui` that is allowed 30 seconds of start period plus 12 retries of its own. The
  start period has to cover that.
- **Staging changes first and is measured first,** since the same correction applies
  to `deploy/stg` and the claim that started this was a staging claim.

Not in scope:

- Eliminating the `api` and `ui` swap gap. Requests in flight while those containers
  are replaced will still see brief 502s; that is what the per-request resolver
  bounds rather than removes.
- `db` and `redis`, which already survive a deploy and declare no `depends_on`.
- The daily encrypted backup, the dump gate, and the migration step, all unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `opnform-deployment`: the existing requirement that no service is stopped to
  deliver a release is currently met only in spirit. A deploy stops no service to
  take a snapshot, which is what the requirement was written to police, but it does
  stop two proxies that carry no part of the release. This change either makes the
  implementation meet the requirement as written or sharpens the requirement to say
  which services a release may replace. Which of the two is a question for the
  spec artifact, not this proposal.

## Impact

- `OpenMedical-cz/venova-opnform-deploy` (private): `deploy/stg/compose.yaml`,
  `deploy/prod/compose.yaml`, and the deploy tests for both.
- No fork change. No `deploy.py` change.

Hosts: staging `142.132.167.249` first, then production `89.167.33.175`, **which is
shared with clinic production**. Both need one deliberate recreate of `ingress` and
`api-internal` to pick up a changed service definition, the same step and the same
cost as the previous rollout: one failed request on staging, and on production a
measured 1 failed request out of 31.

The risk this carries is a cold start, not a deploy: a host that comes up from
`systemctl start` with no containers running. That is the path `depends_on` used to
order, and it is the path the `start_period` has to cover. It should be exercised
on staging explicitly, by stopping the unit and starting it again, before production
sees the change.
