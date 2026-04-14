#!/usr/bin/env bash
# update_checksums.sh
#
# Downloads each PostgreSQL tarball and prints the sha256 sum so you can
# update _PG_VERSIONS in extensions.bzl and repositories.bzl.
#
# Usage:
#   bash tools/update_checksums.sh [version]
#   bash tools/update_checksums.sh 16

set -euo pipefail

VERSIONS=("${@:-14 15 16}")

declare -A URLS=(
    [14_linux_amd64]="https://get.enterprisedb.com/postgresql/postgresql-14.11-1-linux-x64-binaries.tar.gz"
    [14_darwin_arm64]="https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip"
    [14_darwin_amd64]="https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip"
    [15_linux_amd64]="https://get.enterprisedb.com/postgresql/postgresql-15.6-1-linux-x64-binaries.tar.gz"
    [15_darwin_arm64]="https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip"
    [15_darwin_amd64]="https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip"
    [16_linux_amd64]="https://get.enterprisedb.com/postgresql/postgresql-16.2-1-linux-x64-binaries.tar.gz"
    [16_darwin_arm64]="https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip"
    [16_darwin_amd64]="https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip"
)

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for version in "${VERSIONS[@]}"; do
    for platform in linux_amd64 darwin_arm64 darwin_amd64; do
        key="${version}_${platform}"
        url="${URLS[$key]:-}"
        if [[ -z "$url" ]]; then
            echo "No URL for $key, skipping."
            continue
        fi
        fname="$TMPDIR/${key}.archive"
        echo -n "Downloading $url … "
        curl -fsSL -o "$fname" "$url"
        sha=$(sha256sum "$fname" | awk '{print $1}')
        echo "$sha"
        echo "  ${key}: sha256 = \"${sha}\","
    done
done
