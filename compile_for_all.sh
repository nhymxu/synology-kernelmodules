#!/bin/bash
# Builds every platform Synology publishes sources for (3.x/legacy platforms excluded).
# Each platform is built once per DSM version in DSM_VERSIONS (default "7.2 7.4").
# Set DSM_VERSIONS="7.2" ./compile_for_all.sh to build a single DSM release.

set -euo pipefail

PLATFORMS_FILE="discovered_platforms.json"
DSM_VERSIONS="${DSM_VERSIONS:-7.2 7.4}"

dsm_args=()
for version in $DSM_VERSIONS; do
  dsm_args+=(--dsm "$version")
done

echo "Discovering platforms from archive.synology.com for DSM $DSM_VERSIONS..."
python3 discover_platforms.py "${dsm_args[@]}" > "$PLATFORMS_FILE"

# One line per (DSM, platform) build.
jq -r 'to_entries[] | .key as $dsm | .value | to_entries[]
       | select(.value.VERSION != "3")
       | "\($dsm) \(.key)"' "$PLATFORMS_FILE" | while read -r dsm platform; do
  echo "Compiling for platform: $platform (DSM $dsm)"
  # Mount the list so every build uses the same sources, even if Synology publishes mid-run.
  docker run --privileged --rm \
    -v ./compiled_modules:/compiled_modules:rw \
    -v "./$PLATFORMS_FILE:/synology-toolkit/platforms.json:ro" \
    -e DSM_VERSION="$dsm" \
    -e PLATFORM="$platform" \
    compile_modules </dev/null || echo "Build failed for $platform (DSM $dsm)"
done
