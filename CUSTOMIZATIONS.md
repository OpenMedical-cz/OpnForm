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
- `README.md`: links to fork maintenance and identifies the separate private deployment repository.
- `.github/workflows/`: upstream checks gate the fork's GHCR image build. Successful `main` pushes publish immutable image digests and dispatch the private staging workflow with only the source run ID. The fork retains only the limited dispatch token.
- Form badge removal: `client/components/open/forms/OpenForm.vue` and `OpenFormFocused.vue` no longer render the "Made with OpnForm" badge. This applies to existing forms, embeds, editor previews, and submission completion, regardless of stored `no_branding` values. Focused navigation arrows remain available.
- `client/components/pages/forms/show/PoweredBy.vue` and badge-specific styles in `FormEditorPreview.vue` were removed. `FormCustomization.vue` no longer offers the "Hide OpnForm Branding" toggle or its upgrade handler. Stored `no_branding` values, defaults, and API compatibility remain unchanged; no migration is required. Other branding, licensing, and enterprise code are unchanged.
- After upstream updates, check both layouts in public forms, embeds, editor previews, and submission completion with `no_branding` enabled and disabled. Verify that the badge and editor toggle remain absent and navigation and submission still work. Search for reintroduced `PoweredBy` components, `powered-by-button` styles, and badge renderers; run frontend lint and relevant tests.

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

Deployment is a separate private control-plane step. Record the previous application version and prepare a database backup and recovery plan before any production deployment with migrations.

## Workflow status

This document defines the upstream update process. The fork `main` branch is protected with mandatory PR review and CI checks. The private repository owns deployment workflow, runtime secrets, the self-hosted runner, root-owned deployment code, and staging operations.
