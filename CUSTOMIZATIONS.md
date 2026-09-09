# Venova customizations

OpenMedical maintains this OpnForm fork for Venova. Keep branding and small application changes in the fork's `main` branch and keep this document current with each change.

## Repository

- Fork (`origin`): https://github.com/OpenMedical-cz/OpnForm
- Official repository (`upstream`): https://github.com/OpnForm/OpnForm
- Initial upstream baseline: `b80a17b2b8a68b506b196023335cb93c6342ffdd` (upstream `main` at cloning, not a selected release).
- Owner: OpenMedical.

Remotes are local Git configuration. Add upstream in each new clone:

```bash
git remote add upstream https://github.com/OpnForm/OpnForm.git
git fetch upstream --tags
```

If `upstream` already exists, verify its URL with `git remote -v` instead of adding it again.

## Current differences

- `CUSTOMIZATIONS.md`: fork ownership, customization register, and update procedure.
- `DEPLOYMENT.md`: target environments, data storage, deployment, backups, and rollback requirements.
- `README.md`: links to fork maintenance and deployment documentation.
- `.github/workflows/`: upstream checks gate the fork's GHCR image build and staging delivery. Upstream deployment jobs run only in the official repository. Deployment secrets come from the GitHub `staging` Environment.
- `deploy/stg/`: dedicated Compose project, loopback ingress for the shared Caddy, resource limits, external runtime configuration schema, and a systemd Volume guard. Staging uses private local file storage on the Hetzner Volume, without R2 or backups. Recheck image entrypoints, service health checks, API routing, local signed downloads, and the Volume guard after upstream updates.
- No Venova branding or application behavior changes have been implemented.

For each future customization, record the affected paths, purpose, and checks needed after an upstream update. Remove entries when the customization is removed or replaced by upstream functionality.

## Local changes

Keep changes small and focused. Merge completed work into the fork's `main` through a PR targeting `OpenMedical-cz/OpnForm`. Update this register in the same PR. Preserve upstream history so future merges can identify changes already integrated.

## Upstream release updates

1. Start with a clean working tree. Review the chosen official release notes, breaking changes, dependency requirements, and database migrations.
2. Fetch upstream and create a branch from the current fork `main`. Replace `RELEASE_TAG` below with the exact selected upstream tag:

   ```bash
   git switch main
   git pull --ff-only origin main
   git fetch upstream --tags
   git switch -c update/opnform-RELEASE_TAG
   git merge --no-ff RELEASE_TAG
   ```

3. Resolve conflicts on this branch, preserving the customizations listed above. Complete the merge and update this document with the integrated release tag, commit, and any changed customizations. Do not merge upstream directly into `main`.
4. Validate the result in an isolated test environment using synthetic data:
   - Run client lint, tests, and build, backend lint and tests, shared-file checks, and E2E checks defined in [the CI workflow](.github/workflows/ci-cd.yml).
   - Check login, form editing, publishing, public submission, and viewing submissions. Check uploads, notifications, and embeds when used by Venova.
   - Verify all Venova customizations. Test any database migrations against a disposable database before deployment.
5. Push the update branch and open a PR explicitly against the fork:

   ```bash
   git push -u origin update/opnform-RELEASE_TAG
   gh pr create --repo OpenMedical-cz/OpnForm --base main --head update/opnform-RELEASE_TAG
   ```

6. Include the upstream release link, resolved conflicts, customization impact, validation results, and migration requirements in the PR. Merge only after review and successful checks. Use a merge commit to preserve upstream ancestry, rather than squash or rebase merging the update PR.

Deployment is a separate step, defined in [DEPLOYMENT.md](DEPLOYMENT.md). Record the previous application version and prepare a database backup and recovery plan before deploying an update with migrations.

## Workflow status

This document defines the process; it does not configure GitHub branch protection or required checks. No upstream release update has been validated through this process yet.

The local workflow draft gates Venova delivery on upstream checks and restricts inherited deployment jobs to the official repository. It has not yet run in GitHub. Verify that validation jobs actually run in the fork; documentation-only changes outside the deployment directory do not trigger the path-filtered CI workflow.
