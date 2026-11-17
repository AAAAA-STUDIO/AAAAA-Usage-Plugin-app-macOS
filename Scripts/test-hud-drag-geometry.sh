#!/bin/sh
set -eu

project_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_tmp_dir="$(mktemp -d /private/tmp/hud-drag-geometry.XXXXXX)"
trap 'rm -rf "$test_tmp_dir"' EXIT

mkdir -p "$test_tmp_dir/modules"
swiftc \
  -module-cache-path "$test_tmp_dir/modules" \
  "$project_root/HUDDragGeometry.swift" \
  "$project_root/Tests/HUDDragGeometryTests.swift" \
  -o "$test_tmp_dir/hud-drag-geometry-tests"
"$test_tmp_dir/hud-drag-geometry-tests"
