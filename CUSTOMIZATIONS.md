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
- `api/app/Service/Branding/BrandingPolicy.php`: `canRemoveBranding()` skips the paid `Feature::BRANDING_REMOVAL`/whitelabel-license check when `config('app.self_hosted')`, but still requires `$requested` (the per-template `remove_branding` toggle, or the form's `no_branding` flag) to be true first — it does not force branding off unconditionally. Turning on a PDF template's "Remove Branding" toggle now removes the "PDF generated with OpnForm" footer on self-hosted without a license; leaving it off still shows the footer. `PdfTemplate.remove_branding` never passes through `FormCleaner`, so this is the reliable, fully-working case.
  Do not make this unconditional (ignore `$requested`): `FormResource` round-trips `no_branding` into every form update request, and `FormCleaner` separately resets an unlicensed `no_branding=true` via `PlanAccessService::hasFormFeature()` (which this change does not touch), so forcing `no_branding` to always read `true` makes every self-hosted form save surface a spurious "pro features will be disabled" downgrade warning — this broke `FormTest.php`'s self-hosted custom-slug tests when first tried.
  This same gate also feeds `canRemoveFormBranding()` (used by `FormEmailNotification`), but do not assume that reliably suppresses branding in notification emails: any create/update that goes through `FormCleaner::processForm`/`processRequest` (the normal UI/API path) still resets a self-hosted form's stored `no_branding` back to `false` without a whitelabel license, per `FormCleanerTest.php`'s `'cleans no_branding on self-hosted without whitelabel license'`, which this change intentionally leaves in place. So this only benefits a form whose `no_branding` is already `true` in the database through some other means (e.g. it was set while a license was active). The form-page "Powered by OpnForm" badge is unaffected either way — it's already removed unconditionally by the change above.
  Cloud/hosted behavior (non self-hosted) is unchanged — still gated by the workspace's `branding.removal` feature. After upstream updates, re-check that `PdfGeneratorService::generatePdfContent()` still calls `BrandingPolicy::canRemoveBranding()` to decide `$addBranding`, and generate a PDF on a self-hosted instance (with the template's remove-branding toggle on) to confirm no footer is added.
- `client/nuxt.config.ts`: a `routeRules` entry redirects `/` to `/login`. The upstream OpnForm marketing landing page (`client/pages/index.vue`) is unused by this fork and is never rendered, but the file is left in place to minimize upstream merge conflicts. After upstream updates, confirm the redirect still takes effect and that `index.vue` changes upstream don't need porting.
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
