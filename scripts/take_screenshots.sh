#!/usr/bin/env bash
# Captures App Store screenshots across required device sizes.
# Usage: ./scripts/take_screenshots.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="${PROJECT_DIR}/build/screenshots"
OUTPUT_DIR="${PROJECT_DIR}/screenshots/en-US"

# App Store required simulator names.
# Update these to match your installed simulators (run `xcrun simctl list devices available` to see options).
# Required sizes: 6.7"+ iPhone (Pro Max), standard iPhone, 12.9"+ iPad Pro
declare -a SIMULATORS=(
    "iPhone 17 Pro Max"
    "iPhone 17"
    "iPhone 11 Pro Max"
    "iPad Pro 13-inch (M5)"
)

rm -rf "${RESULTS_DIR}" "${OUTPUT_DIR}"
mkdir -p "${RESULTS_DIR}" "${OUTPUT_DIR}"

for SIMULATOR in "${SIMULATORS[@]}"; do
    echo "==> Capturing screenshots on: ${SIMULATOR}"
    RESULT_BUNDLE="${RESULTS_DIR}/${SIMULATOR}.xcresult"

    xcodebuild test \
        -project "${PROJECT_DIR}/BaoLianDeng.xcodeproj" \
        -scheme BaoLianDeng \
        -destination "platform=iOS Simulator,name=${SIMULATOR}" \
        -only-testing BaoLianDengUITests/ScreenshotTests/testCaptureScreenshots \
        -resultBundlePath "${RESULT_BUNDLE}" \
        -configuration Debug \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -20 || true

    if [ ! -d "${RESULT_BUNDLE}" ]; then
        echo "    WARNING: No result bundle produced for ${SIMULATOR}, skipping."
        continue
    fi

    echo "    Extracting screenshots from result bundle..."

    # Export attachments using the modern xcresulttool API
    ATTACHMENTS_DIR="${RESULTS_DIR}/${SIMULATOR}_attachments"
    mkdir -p "${ATTACHMENTS_DIR}"

    xcrun xcresulttool export attachments \
        --path "${RESULT_BUNDLE}" \
        --output-path "${ATTACHMENTS_DIR}" 2>/dev/null || true

    # Read the manifest to find our named screenshots
    MANIFEST="${ATTACHMENTS_DIR}/manifest.json"
    if [ ! -f "${MANIFEST}" ]; then
        echo "    WARNING: No attachments manifest for ${SIMULATOR}, skipping."
        continue
    fi

    # Parse manifest and copy screenshots with proper names
    python3 -c "
import json, sys, shutil, os, re

output_dir = sys.argv[1]
simulator = sys.argv[2]
attachments_dir = sys.argv[3]

with open(os.path.join(attachments_dir, 'manifest.json')) as f:
    manifest = json.load(f)

for test_case in manifest:
    for att in test_case.get('attachments', []):
        exported = att.get('exportedFileName', '')
        suggested = att.get('suggestedHumanReadableName', '')
        if not exported or not exported.endswith('.png'):
            continue
        # Extract the attachment name (e.g. '01_Home') from suggested name like '01_Home_0_UUID.png'
        match = re.match(r'^(\d+_\w+)_\d+_', suggested)
        name = match.group(1) if match else os.path.splitext(suggested)[0]
        src = os.path.join(attachments_dir, exported)
        if os.path.exists(src):
            dst = os.path.join(output_dir, f'{simulator}-{name}.png')
            shutil.copy2(src, dst)
            print(f'    Saved: {dst}')
" "${OUTPUT_DIR}" "${SIMULATOR}" "${ATTACHMENTS_DIR}"

done

echo ""
echo "==> Screenshots saved to: ${OUTPUT_DIR}"
ls -la "${OUTPUT_DIR}" 2>/dev/null || echo "    (no screenshots found — check simulator availability)"
