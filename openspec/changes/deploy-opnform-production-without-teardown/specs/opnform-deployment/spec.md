## ADDED Requirements

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

#### Scenario: Snapshot requires quiescing writes

- **WHEN** an environment captures a snapshot before applying a schema change
- **THEN** it may stop the services that write to the database first
- **AND** the database itself keeps running
- **AND** those services are running again when the deploy reports success

#### Scenario: Delivery does not justify stopping services

- **WHEN** a release carries no schema change
- **THEN** no service is stopped at any point in the deploy

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
