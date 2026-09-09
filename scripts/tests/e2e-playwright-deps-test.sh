#!/usr/bin/env bash
set -euo pipefail

workflow=.github/workflows/ci-cd.yml

grep -Fq 'rm -f /etc/apt/sources.list.d/google-chrome.list' "$workflow" || {
    printf 'E2E must remove the volatile Google Chrome APT source before Playwright dependency installation.\n' >&2
    exit 1
}
grep -Fq 'npx playwright install-deps chromium' "$workflow" || {
    printf 'E2E must install Playwright Chromium system dependencies.\n' >&2
    exit 1
}
