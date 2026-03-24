#!/bin/bash
#
# Build mPower custom app package for sensor decoder definitions.
#
# Extracts BACNet.zip and MTCT300_direct.zip, organises decoder pairs by
# vendor (decoders/<vendor>/), generates manifest.json, and produces a
# .tgz ready for app-manager.
#
# Usage:
#   ./package.sh              Auto-detect version from git tag / describe
#   ./package.sh 1.2.0        Build with specified version
#   ./package.sh --help       Show usage

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
DIST_DIR="${SCRIPT_DIR}/dist"
DEFS_DIR="${SRC_DIR}/definitions"
APP_NAME="bacnet-decoders"
BACNET_ZIP="${REPO_DIR}/BACNet.zip"
MTCT300_ZIP="${REPO_DIR}/MTCT300_direct.zip"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [VERSION]"
        echo ""
        echo "  VERSION    Semantic version for the package."
        echo "             If omitted, derived from git tag (v1.0.0 -> 1.0.0)"
        echo "             or git describe (e.g. 1.0.0-3-gabcdef0)."
        echo ""
        echo "Expects:"
        echo "  BACNet.zip          at: ${BACNET_ZIP}"
        echo "  MTCT300_direct.zip  at: ${MTCT300_ZIP}"
        exit 0
        ;;
esac

git_version() {
    local tag
    tag=$(git -C "${REPO_DIR}" describe --tags --exact-match 2>/dev/null) && {
        echo "${tag#v}"
        return
    }
    local desc
    desc=$(git -C "${REPO_DIR}" describe --tags --long 2>/dev/null) && {
        echo "${desc#v}"
        return
    }
    local sha
    sha=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null) || sha="unknown"
    echo "0.0.0-dev.${sha}"
}

GIT_COMMIT=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    VERSION=$(git_version)
fi

for f in Install Start status.json; do
    [ -f "${SRC_DIR}/${f}" ] || die "Missing required source file: src/${f}"
done

[ -f "${BACNET_ZIP}" ] || die "BACNet.zip not found at ${BACNET_ZIP}"
[ -f "${MTCT300_ZIP}" ] || die "MTCT300_direct.zip not found at ${MTCT300_ZIP}"

echo "=== Building ${APP_NAME} v${VERSION} ==="

STAGE_DIR=$(mktemp -d "${SCRIPT_DIR}/.stage-XXXXXX")
cleanup() { rm -rf "${STAGE_DIR}"; }
trap cleanup EXIT

cp "${SRC_DIR}/Install" "${STAGE_DIR}/"
cp "${SRC_DIR}/Start" "${STAGE_DIR}/"
cp "${SRC_DIR}/status.json" "${STAGE_DIR}/"
chmod +x "${STAGE_DIR}/Install" "${STAGE_DIR}/Start"

cat > "${STAGE_DIR}/manifest.json" <<EOF
{
  "AppName": "${APP_NAME}",
  "AppVersion": "${VERSION}",
  "AppDescription": "LoRaWAN sensor decoder definitions (Radio Bridge + MTCT300) for Payload Management",
  "AppVersionNotes": "v${VERSION} (${GIT_COMMIT}) - RBS 301/304/306 + MTCT300 decoder pairs, imported via scada-cli",
  "PersistentStorage": true
}
EOF

EXTRACT_DIR=$(mktemp -d "${SCRIPT_DIR}/.extract-XXXXXX")
extract_cleanup() { chmod -R u+w "${EXTRACT_DIR}" 2>/dev/null; rm -rf "${EXTRACT_DIR}"; cleanup; }
trap extract_cleanup EXIT

pair_count=0

mkdir -p "${STAGE_DIR}/decoders/multitech"

# --- Radio Bridge decoders from BACNet.zip ---
echo "  Extracting BACNet.zip (Radio Bridge decoders)..."
unzip -q -o "${BACNET_ZIP}" -d "${EXTRACT_DIR}/bacnet"

while IFS= read -r -d '' json_file; do
    base=$(basename "$json_file" .json)
    parent_dir=$(dirname "$json_file")
    js_file="${parent_dir}/${base}.js"

    if [ ! -f "$js_file" ]; then
        echo "  WARNING: No matching .js for ${json_file}, skipping"
        continue
    fi

    cp "$json_file" "${STAGE_DIR}/decoders/multitech/${base}.json"
    cp "$js_file" "${STAGE_DIR}/decoders/multitech/${base}.js"
    pair_count=$((pair_count + 1))
done < <(find "${EXTRACT_DIR}/bacnet" -name '*.json' -print0)

echo "  Radio Bridge: ${pair_count} decoder pair(s)"

# --- MTCT300 decoder from MTCT300_direct.zip ---
echo "  Extracting MTCT300_direct.zip..."
unzip -q -o "${MTCT300_ZIP}" -d "${EXTRACT_DIR}/mtct300"

mtct300_count=0
MTCT300_JS=$(find "${EXTRACT_DIR}/mtct300" -name 'index-es5.js' -print -quit)
if [ -n "$MTCT300_JS" ] && [ -f "${DEFS_DIR}/MTCT300-direct.json" ]; then
    cp "${DEFS_DIR}/MTCT300-direct.json" "${STAGE_DIR}/decoders/multitech/MTCT300-direct.json"
    cp "$MTCT300_JS" "${STAGE_DIR}/decoders/multitech/MTCT300-direct.js"
    mtct300_count=1
    pair_count=$((pair_count + 1))
else
    echo "  WARNING: Could not find index-es5.js or definition for MTCT300"
fi

echo "  MTCT300: ${mtct300_count} decoder pair(s)"

chmod -R u+w "${EXTRACT_DIR}" 2>/dev/null
rm -rf "${EXTRACT_DIR}"
trap cleanup EXIT

echo "  Total: ${pair_count} decoder pair(s)"

if [ "$pair_count" -eq 0 ]; then
    die "No decoder pairs found"
fi

if command -v dos2unix &>/dev/null; then
    dos2unix "${STAGE_DIR}/Install" "${STAGE_DIR}/Start" "${STAGE_DIR}/manifest.json" 2>/dev/null
    find "${STAGE_DIR}/decoders" -type f -exec dos2unix {} + 2>/dev/null
fi

mkdir -p "${DIST_DIR}"
OUTPUT="${DIST_DIR}/${APP_NAME}_${VERSION}.tgz"

(cd "${STAGE_DIR}" && tar --hard-dereference -hczf "${OUTPUT}" *)

SIZE=$(du -h "${OUTPUT}" | cut -f1)
echo "  Output: ${OUTPUT} (${SIZE})"
echo "  Contents:"
tar -tzf "${OUTPUT}" | sed 's/^/    /'
echo ""
echo "=== Done: ${APP_NAME} v${VERSION} (${pair_count} decoder pairs) ==="
