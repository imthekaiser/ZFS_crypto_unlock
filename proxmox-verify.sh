#!/bin/bash
# Verify explicit encrypted storage trees after the upstream unlock script runs.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 pool/encrypted-root [pool/another-root ...]" >&2
    exit 2
fi

fail() {
    echo "$*" >&2
    exit 1
}

for root in "$@"; do
    rows=$(zfs list -r -H -t filesystem,volume -o name,type,mounted,canmount "$root")
    while IFS=$'\t' read -r dataset type mounted canmount; do
        [ "$(zfs get -H -o value keystatus "$dataset")" = available ] ||
            fail "Encryption key is not available: $dataset"
        if [ "$type" = volume ]; then
            [ -b "/dev/zvol/$dataset" ] || fail "Missing zvol device: $dataset"
            dd if="/dev/zvol/$dataset" of=/dev/null bs=512 count=1 status=none ||
                fail "Cannot read zvol: $dataset"
        elif [ "$canmount" = on ] && [ "$mounted" != yes ]; then
            fail "Filesystem is not mounted: $dataset"
        fi
    done <<< "$rows"
done
