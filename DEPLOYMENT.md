# Venova deployment

Owner: OpenMedical. This document defines the target infrastructure and deployment process for the OpnForm fork. These controls are requirements, not confirmation of a running deployment. Staging host preparation is recorded below. Compose, the startup guard, and restricted SSH delivery are installed, but the stack is not deployed. GitHub Actions delivery has not run, and production backups and recovery checks remain unconfigured.

## Environments

- Staging: `stg-forms.venova.cz`.
- Production: `forms.venova.cz`.
- Staging uses the existing shared OpenMedical staging VM. OpnForm must have its own PostgreSQL, Redis, Docker network, and Hetzner Volume, separate from the other applications. Production uses a separate EU VM and its own services and Volume.
- Each Hetzner Volume uses a fixed mount path and stores PostgreSQL data and other persistent container data through explicit Docker bind mounts beneath that path. Staging retains `/mnt/HC_Volume_106834335`; the production target path is `/mnt/opnform-data`.
- Startup must verify both the mount and the expected volume identity before starting the stack, including PostgreSQL, Redis, application workers, and scheduled jobs. A directory existing at the mount path is not sufficient. Do not fall back to the VM root disk when the volume is absent; apply this check after reboots as well as deployments.
- Staging and production never share a volume, database, Redis instance, or credentials. Use synthetic data in staging.

## Staging host preparation

Verified on 2026-09-09:

- Ubuntu 24.04, Docker and Docker Compose are already installed. The host has 4 vCPUs and approximately 8 GB RAM; existing applications share these resources.
- Caddy is active. A root-owned `sites-enabled` import is installed; the fixed deploy command will add the authenticated OpnForm site after the containers pass health checks. The shared proxy and its public ports remain unchanged.
- The 20 GB Volume is mounted at `/mnt/HC_Volume_106834335`. Its stable device identity is `/dev/disk/by-id/scsi-0HC_Volume_106834335`, and an `/etc/fstab` entry already exists.
- Created `/opt/opnform` for deployment files and `/mnt/HC_Volume_106834335/opnform/postgres` and `/mnt/HC_Volume_106834335/opnform/redis` for persistent service data. Container-specific ownership must be set when configuring the stack.
- The mount and device identity were checked before creating the data directories. The existing `nofail` mount option allows the VM to boot without the Volume. The installed systemd unit checks the Volume before startup and disables Docker container restart policies that would bypass this check. The unit is enabled but remains inactive until the first deployment.
- The `opnform-deploy` SSH account has no supplementary groups, forwarding, TTY, password login, or unrestricted shell. Its key can invoke only the root-owned deploy script through one exact `sudo` rule. The workflow cannot install or replace that script.

DNS resolves `stg-forms.venova.cz` directly to the staging VM. No OpnForm containers have been started, so the authenticated HTTPS route and certificate have not yet been created or verified.

## Data and secrets

- PostgreSQL stores forms and submissions.
- Staging stores test uploads and generated PDFs locally in `/mnt/HC_Volume_106834335/opnform/storage/app`, on the same Hetzner Volume as PostgreSQL and Redis. Use the private local filesystem; staging does not require R2 or backups.
- Production uses private Cloudflare R2 storage configured for EU jurisdiction for uploads and archived PDFs. Verify the jurisdiction configuration during provisioning and use scoped credentials.
- Serve files only through authorized access or time-limited signed URLs. Staging must never use production file storage or credentials.
- PostgreSQL and Redis are accessible only within the environment's internal Docker network. Do not publish their ports on the VM.
- Keep secrets outside Git and Docker images. Supply them at runtime through restricted secret files or a secret manager and through GitHub Actions secrets where needed. Do not include secret values in build arguments or logs.

## Deployment process

1. A merge into the fork's `main` triggers GitHub Actions validation. After checks pass, build versioned API and frontend Docker images and publish them to GitHub Container Registry (GHCR), tagged with the commit SHA.
2. Record the commit and both immutable image digests as one release. Automatically deploy that release to staging and check service health and the form submission flow.
3. After staging verification, manually trigger production promotion of that exact release. Deploy the same image digests without rebuilding. Serialize deployments within each environment.
4. Before production migrations or container replacement, create an encrypted PostgreSQL backup and confirm successful upload to both external backup destinations. Stop deployment if the backup fails. Record the backup identifier and previous release digests.
5. Run required migrations, update the application services, and verify health, login, form rendering, submission, and access to stored files. Record the result with the release.

The [CI workflow](.github/workflows/ci-cd.yml) retains upstream checks and restricts upstream Vapor/Amplify and Docker Hub jobs to the official repository. For this fork, successful main-push checks call [Venova staging delivery](.github/workflows/venova-staging.yml) to publish GHCR images and deploy through restricted SSH. The host access, SSH key, and verified host key are configured. This local workflow draft is not yet published or validated in GitHub; `STAGING_HTTP_PASSWORD` is still required before its first run. The upstream merge procedure is in [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md).

## Backups

Staging uses disposable synthetic data and has no scheduled or pre-deployment backups. Data loss and recreation are acceptable there. The following backup and recovery requirements apply to production only.

- Automatically create encrypted PostgreSQL backups.
- Keep two independent external copies of each backup: Cloudflare R2 EU and Backblaze B2. Use backup storage and credentials separate from application uploads, with separate credentials for each provider and environment.
- Create an additional backup before each production deployment.
- Configure explicit retention periods and automatic deletion of expired copies in both destinations. Select the schedule and retention periods before enabling production.
- Monitor backup creation and delivery to both destinations. Report failures; a local backup alone does not satisfy this policy.
- Keep decryption keys outside the VM and backup archives so recovery does not depend on the original server.
- Regularly restore from each provider into an isolated environment. Check decryption, database restoration, forms, submissions, and file references; record the date, backup identifier, result, and recovery duration. Agree the restore-test cadence and recovery objectives before production.
- A Hetzner Volume is not a backup.

These PostgreSQL backups do not contain uploads or archived PDF objects from R2. Define and validate a separate object recovery policy before production, including recovery from accidental deletion and compatibility with restored database references.

## Rollback

Return all application services to the previous release's recorded image digests and verify service health and submission handling. Keep previous images available in GHCR for the agreed rollback window.

An image rollback does not undo database migrations. Prefer migrations compatible with both the previous and new application versions. For incompatible changes, prepare and test a database recovery procedure before deployment. Restoring a backup can discard submissions received after that backup; account for writes and uploaded objects during recovery.
