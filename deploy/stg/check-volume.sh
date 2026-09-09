#!/usr/bin/env bash
set -euo pipefail

volume_path=/mnt/HC_Volume_106834335
volume_device=/dev/disk/by-id/scsi-0HC_Volume_106834335

fail() {
    printf 'OpnForm startup blocked: %s\n' "$1" >&2
    exit 1
}

mountpoint -q "$volume_path" || fail 'required Volume is not mounted'
[[ -b "$volume_device" ]] || fail 'expected Volume device is missing'
actual_device=$(findmnt -nro SOURCE --mountpoint "$volume_path")
[[ "$(readlink -f "$actual_device")" == "$(readlink -f "$volume_device")" ]] || fail 'unexpected Volume device'
[[ "$(findmnt -nro FSTYPE --mountpoint "$volume_path")" == ext4 ]] || fail 'unexpected filesystem'
mount_options=$(findmnt -nro OPTIONS --mountpoint "$volume_path")
[[ ",$mount_options," == *,rw,* ]] || fail 'Volume is not writable'

for directory in postgres redis storage; do
    data_path="$volume_path/opnform/$directory"
    [[ -d "$data_path" && ! -L "$data_path" ]] || fail "missing or symlinked data directory: $directory"
    [[ "$(readlink -f "$data_path")" == "$data_path" ]] || fail "data path resolves outside expected directory: $directory"
    [[ "$(findmnt -nro TARGET --target "$data_path")" == "$volume_path" ]] || fail "unexpected nested mount: $directory"
done

printf 'OpnForm Volume and data directories verified.\n'
