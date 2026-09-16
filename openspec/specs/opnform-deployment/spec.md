## Purpose

Governs how a released OpnForm image reaches a running environment: which services a deploy is allowed to disturb, where database migrations run relative to the container swap, and what must be true before a deploy may be reported successful.

## Requirements

### Requirement: A deploy SHALL disturb only the services whose released content changed

A deploy SHALL replace an environment's application services without stopping the services the release does not change. The database, the cache, the public ingress and the internal API proxy SHALL remain running throughout a deploy and SHALL NOT be stopped, removed or recreated because a new application release is being delivered.

Stopping every service in the environment in order to deliver a new release is prohibited. Full stop and start remains the correct behavior for a deliberate shutdown or a host reboot, and SHALL remain available for those.

#### Scenario: New application release leaves data and routing services untouched

- **WHEN** a release is deployed whose application image digests differ from the running release
- **THEN** the database and cache containers are still the same container instances after the deploy as before it
- **AND** the public ingress and internal API proxy containers are still the same container instances
- **AND** the application, worker, scheduler and frontend containers have been replaced

#### Scenario: Re-deploying the running release replaces nothing

- **WHEN** a release is deployed whose image digests and configuration are identical to the running release
- **THEN** no container in the environment is replaced
- **AND** the deploy reports success

### Requirement: Database migrations SHALL be applied before application containers are replaced

Migrations SHALL run as an explicit deploy step against the running database, while the previous release is still serving traffic. An application container SHALL NOT apply migrations as part of its own startup in a managed environment, so that a container becoming ready is not gated on schema work.

The migration step SHALL be safe to run when the release contains no new migrations.

#### Scenario: Release carrying new migrations

- **WHEN** a release containing migrations the database has not applied is deployed
- **THEN** those migrations are applied before any application container is replaced
- **AND** the previous release is still serving traffic while they are applied

#### Scenario: Release carrying no new migrations

- **WHEN** a release containing no migrations the database has not applied is deployed
- **THEN** the migration step completes successfully without changing the schema
- **AND** the deploy proceeds to replace the application containers

#### Scenario: Application container start does not migrate

- **WHEN** an application container in a managed environment starts, whether during a deploy, a restart or a host reboot
- **THEN** it does not apply database migrations

### Requirement: A failed migration SHALL leave the previous release serving

If the migration step does not succeed, the deploy SHALL stop and SHALL NOT replace any application container, so that a schema failure does not also cost the environment its running application.

#### Scenario: Migration fails

- **WHEN** the migration step exits with a failure
- **THEN** no application container is replaced
- **AND** the previous release is still serving traffic
- **AND** the deploy reports failure

### Requirement: A deploy SHALL be reported successful only after the environment serves traffic

Every replaced service SHALL be observed healthy, and the environment SHALL answer a request on its public route, before the deploy reports success. A deploy that cannot reach that state within its timeout SHALL report failure rather than success.

#### Scenario: Replaced services become healthy and the environment answers

- **WHEN** every replaced service reports healthy and a request to the environment's public login route succeeds
- **THEN** the deploy reports success

#### Scenario: A replaced service never becomes healthy

- **WHEN** a replaced service does not report healthy within the deploy's timeout
- **THEN** the deploy reports failure

### Requirement: Operators SHALL have a non-destructive convergence path

An operator SHALL be able to bring a running environment into agreement with its recorded release without stopping the services that release does not change. The destructive path SHALL remain available and SHALL remain distinct, so that reaching for the ordinary lifecycle verb does not silently take the environment down.

#### Scenario: Operator converges a running environment

- **WHEN** an operator converges the environment to its recorded release
- **THEN** only the services that differ from that release are replaced
- **AND** the database and cache keep running

#### Scenario: Host reboot

- **WHEN** the host reboots
- **THEN** the environment starts from stopped and reaches its recorded release

### Requirement: A pre-release snapshot SHALL be taken only when the release changes the schema

An environment that protects itself with a snapshot before a release SHALL take that snapshot when, and only when, the release carries schema changes the database has not applied. A release that changes no schema SHALL NOT trigger a snapshot, because there is no schema change for it to protect against and the snapshot is not free.

Where a snapshot is required, it SHALL be captured before any schema change is applied, and a deploy that cannot capture one SHALL stop rather than apply the change unprotected.

#### Scenario: Release carrying no schema change

- **WHEN** a release is deployed that carries no migrations the database has not applied
- **THEN** no snapshot is taken
- **AND** no service is stopped in order to take one
- **AND** the deploy proceeds

#### Scenario: Release carrying a schema change

- **WHEN** a release is deployed that carries migrations the database has not applied
- **THEN** a snapshot is captured before those migrations are applied
- **AND** the migrations are applied only after the snapshot is complete

#### Scenario: Snapshot cannot be captured

- **WHEN** a release carries a schema change and the snapshot cannot be captured
- **THEN** no migration is applied
- **AND** no application container is replaced
- **AND** the deploy reports failure

### Requirement: An environment MAY stop write traffic to capture a consistent snapshot

Stopping services to protect data is distinct from stopping them to deliver a release, which remains prohibited. An environment MAY stop the services that write to its database for as long as it takes to capture a consistent snapshot. It SHALL NOT stop the database itself, and it SHALL restore the stopped services within the same deploy.

This permission is scoped to the snapshot. It SHALL NOT be used to justify a full stop and start as the delivery mechanism.

This requirement governs stopping services to *protect data*, and tearing the
environment down to *deliver*. It does not govern how many containers a release
replaces. Replacing a service whose image or definition changed is delivery, and
so is an orchestrator replacing a container that depends on one it just replaced.
Those replacements have a cost, and it is a real one, but bounding it is a
separate concern from this requirement and is not what an unnecessary snapshot
would have protected against.

#### Scenario: Snapshot requires quiescing writes

- **WHEN** an environment captures a snapshot before applying a schema change
- **THEN** it may stop the services that write to the database first
- **AND** the database itself keeps running
- **AND** those services are running again when the deploy reports success

#### Scenario: Delivery does not justify stopping services

- **WHEN** a release carries no schema change
- **THEN** no service is stopped in order to take a snapshot
- **AND** the environment is not stopped and started as the way the release is delivered
- **AND** the database keeps running throughout

### Requirement: An environment that cannot determine whether a release changes the schema SHALL assume it does

The decision to skip a snapshot SHALL rest on positive evidence that the release carries no schema change. Absence of evidence is not that. Any check that fails, or that returns a result the environment cannot interpret unambiguously, SHALL be treated as though the release changes the schema, so that an unreadable answer costs an unnecessary snapshot rather than an unprotected migration.

#### Scenario: Detection cannot reach the database

- **WHEN** the check for pending schema changes fails to run
- **THEN** the release is treated as carrying a schema change
- **AND** a snapshot is captured before any migration is applied

#### Scenario: Detection returns an unrecognized result

- **WHEN** the check runs but its result does not unambiguously report that nothing is pending
- **THEN** the release is treated as carrying a schema change

#### Scenario: Detection positively reports nothing pending

- **WHEN** the check runs successfully and reports that no schema change is pending
- **THEN** the release is treated as carrying no schema change
- **AND** the deploy takes no snapshot
