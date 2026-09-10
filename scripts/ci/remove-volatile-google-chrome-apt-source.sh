#!/usr/bin/env bash
set -euo pipefail

sources_dir=${1:-/etc/apt/sources.list.d}

if [ ! -d "$sources_dir" ]; then
    printf 'APT sources directory does not exist: %s\n' "$sources_dir" >&2
    exit 1
fi

while IFS= read -r -d '' source_file; do
    if grep -Fq 'dl.google.com/linux/chrome' "$source_file"; then
        rm -f -- "$source_file"
    fi
done < <(find "$sources_dir" -maxdepth 1 \( -type f -o -type l \) \( -name '*.list' -o -name '*.sources' \) -print0)

if grep -R --include='*.list' --include='*.sources' -Fq 'dl.google.com/linux/chrome' "$sources_dir"; then
    printf 'Google Chrome APT source remains after cleanup.\n' >&2
    exit 1
fi
