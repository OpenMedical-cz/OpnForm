#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
removal_script="$project_root/scripts/ci/remove-volatile-google-chrome-apt-source.sh"
test_root=$(mktemp -d)
sources_dir="$test_root/sources.list.d"

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$sources_dir"
printf 'deb https://dl.google.com/linux/chrome-stable/deb stable main\n' > "$sources_dir/google-chrome.list"
printf 'Types: deb\nURIs: https://dl.google.com/linux/chrome-stable/deb\nSuites: stable\nComponents: main\n' > "$sources_dir/google-chrome.sources"
printf 'Types: deb\nURIs: https://packages.microsoft.com/ubuntu/24.04/prod\nSuites: noble\nComponents: main\n' > "$sources_dir/microsoft-prod.sources"

bash "$removal_script" "$sources_dir"

test ! -e "$sources_dir/google-chrome.list"
test ! -e "$sources_dir/google-chrome.sources"
test -f "$sources_dir/microsoft-prod.sources"
