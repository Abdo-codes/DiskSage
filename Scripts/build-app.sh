#!/usr/bin/env bash

set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
configuration=${1:-release}

case "$configuration" in
  debug|release) ;;
  *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 64 ;;
esac

version=$(tr -d '[:space:]' < "$project_dir/VERSION")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid VERSION: %s\n' "$version" >&2
  exit 65
fi

cd "$project_dir"
swift build -c "$configuration"

binary_path=$(swift build -c "$configuration" --show-bin-path)/DiskSage
app_path="$project_dir/.build/$configuration/DiskSage.app"
contents_path="$app_path/Contents"

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/DiskSage"

sed "s/__VERSION__/$version/g" "$project_dir/Resources/Info.plist.template" > "$contents_path/Info.plist"
plutil -lint "$contents_path/Info.plist" >/dev/null
codesign --force --deep --sign - "$app_path"

printf 'Built %s\n' "$app_path"
