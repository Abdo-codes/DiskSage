#!/usr/bin/env bash

set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_icon="$project_dir/Resources/AppIcon.png"
output_icon=${1:-"$project_dir/.build/branding/AppIcon.icns"}

mkdir -p "$project_dir/.build" "$(dirname -- "$output_icon")"
temporary_dir=$(mktemp -d "$project_dir/.build/icon-XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
iconset="$temporary_dir/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_icon" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$source_icon" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$iconset" --output "$output_icon"
printf 'Built %s\n' "$output_icon"
