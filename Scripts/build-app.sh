#!/usr/bin/env bash

set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
configuration=${1:-release}

cd "$project_dir"
swift build -c "$configuration"

binary_path=$(swift build -c "$configuration" --show-bin-path)/DiskSage
app_path="$project_dir/.build/$configuration/DiskSage.app"
contents_path="$app_path/Contents"

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/DiskSage"

sed "s/__VERSION__/0.1.0/g" "$project_dir/Resources/Info.plist.template" > "$contents_path/Info.plist"
codesign --force --deep --sign - "$app_path"

printf 'Built %s\n' "$app_path"
