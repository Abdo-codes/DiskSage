#!/usr/bin/env bash

set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source_icon="$project_dir/Resources/AppIcon.png"
composer_icon="$project_dir/Resources/AppIcon.icon"
output_icon=${1:-"$project_dir/.build/branding/AppIcon.icns"}
output_resources_dir=${2:-""}

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

if [[ -n "$output_resources_dir" && -d "$composer_icon" ]] && xcrun --find actool >/dev/null 2>&1; then
  actool_out="$temporary_dir/actool"
  mkdir -p "$actool_out" "$output_resources_dir"
  xcrun actool "$composer_icon" \
    --compile "$actool_out" \
    --output-format human-readable-text \
    --errors --warnings \
    --output-partial-info-plist "$actool_out/partial.plist" \
    --app-icon AppIcon \
    --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --platform macosx >/dev/null
  if [[ -f "$actool_out/Assets.car" ]]; then
    cp "$actool_out/Assets.car" "$output_resources_dir/Assets.car"
    printf 'Built %s\n' "$output_resources_dir/Assets.car"
  fi
fi
