#!/bin/bash
# Bump CURRENT_PROJECT_VERSION for Debug or Release configurations only.
#
# Why this exists:
#   The project's two Info.plist files use $(CURRENT_PROJECT_VERSION) so the
#   build number is sourced from each XCBuildConfiguration block in
#   project.pbxproj. Debug and Release each carry their own value, which means
#   `xcrun agvtool new-version -all` is no longer safe — it would clobber both.
#   This script edits only the configuration blocks you ask it to.
#
# Usage:
#   scripts/bump-build.sh debug 101
#   scripts/bump-build.sh release 19
#   scripts/bump-build.sh debug          # auto-bump (current Debug + 1)
#
set -euo pipefail

PBX="$(cd "$(dirname "$0")/.." && pwd)/BaoLianDeng.xcodeproj/project.pbxproj"

if [ ! -f "$PBX" ]; then
    echo "ERROR: $PBX not found" >&2
    exit 1
fi

CONFIG="${1:-}"
NEW="${2:-}"

if [ -z "$CONFIG" ] || [ "$CONFIG" != "debug" ] && [ "$CONFIG" != "release" ]; then
    echo "Usage: $0 {debug|release} [new_build_number]" >&2
    exit 1
fi

# The four XCBuildConfiguration block IDs, by configuration name. Hard-coded
# because grep-based matching against block headers is fragile and these IDs
# rarely change.
# Match by the unique block ID (UUID) — comments can be reformatted by Xcode.
case "$CONFIG" in
    debug)
        BLOCKS=(
            "D11C88732910D050C57C2AEE"  # TransparentProxy/Debug
            "AX10003"                   # TransparentProxyAppex/Debug
            "E9D48DA79572E3916C0F3AEF"  # BaoLianDeng/Debug
        )
        ;;
    release)
        BLOCKS=(
            "06AC95C84A776847DF0FBFDB"  # TransparentProxy/Release
            "AX10004"                   # TransparentProxyAppex/Release
            "51D5A9072314B0B4FE0F84C8"  # BaoLianDeng/Release
        )
        ;;
esac

read_block_version() {
    local id="$1"
    awk -v id="$id" '
        index($0, id) {found=1}
        found && /CURRENT_PROJECT_VERSION/ {
            match($0, /[0-9]+/)
            print substr($0, RSTART, RLENGTH)
            exit
        }
    ' "$PBX"
}

# Read the current value from the first block (both should match).
CURRENT=$(read_block_version "${BLOCKS[0]}")

if [ -z "$CURRENT" ]; then
    echo "ERROR: could not read current $CONFIG build number from $PBX" >&2
    exit 1
fi

if [ -z "$NEW" ]; then
    NEW=$((CURRENT + 1))
fi

echo "Bumping $CONFIG: $CURRENT -> $NEW"

# Sanity-check the other block matches before editing anything.
for id in "${BLOCKS[@]}"; do
    val=$(read_block_version "$id")
    if [ "$val" != "$CURRENT" ]; then
        echo "ERROR: $CONFIG blocks have inconsistent values ($val vs $CURRENT). Fix manually." >&2
        exit 1
    fi
done

# Per-block in-place edit: only the CURRENT_PROJECT_VERSION line that follows
# each target block header. Uses Perl for portable in-place regex with state.
for id in "${BLOCKS[@]}"; do
    BLOCK_ID="$id" NEW_VER="$NEW" perl -i -pe '
        BEGIN { $in_block = 0; $id = $ENV{BLOCK_ID}; $ver = $ENV{NEW_VER} }
        if (index($_, $id) >= 0) { $in_block = 1 }
        if ($in_block && s/CURRENT_PROJECT_VERSION = \d+;/CURRENT_PROJECT_VERSION = $ver;/) {
            $in_block = 0;
        }
    ' "$PBX"
done

echo "Done. Verify with:"
echo "  grep -n CURRENT_PROJECT_VERSION $PBX"
