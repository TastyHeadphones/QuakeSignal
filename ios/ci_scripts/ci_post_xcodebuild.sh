#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH DEVELOPER_DIR SDKROOT TOOLCHAINS

script_dir="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"

if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] && [ "${CI_XCODEBUILD_EXIT_CODE:-}" != "0" ]; then
  echo "::error::The protected archive xcodebuild action failed with exit code ${CI_XCODEBUILD_EXIT_CODE:-missing}."
  exit 1
fi

/usr/bin/python3 -I "$script_dir/xcode-cloud-release-guard.py" --phase post-xcodebuild

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "No signed-artifact verification is required for ${CI_XCODEBUILD_ACTION:-unknown} actions."
  exit 0
fi

case "${CI_XCODE_SCHEME:-}:${CI_PRODUCT_PLATFORM:-}" in
  QuakeSignal:iOS) verifier_platform=ios ;;
  QuakeSignal:macOS) verifier_platform=maccatalyst ;;
  QuakeSignalTV:tvOS) verifier_platform=tvos ;;
  QuakeSignalVision:*) verifier_platform=visionos ;;
  *)
    echo "::error::Unsupported protected archive route ${CI_XCODE_SCHEME:-missing}:${CI_PRODUCT_PLATFORM:-missing}."
    exit 1
    ;;
esac

exec "$script_dir/verify-signed-apple-artifacts.sh" \
  --platform "$verifier_platform" \
  --archive "${CI_ARCHIVE_PATH:?CI_ARCHIVE_PATH is required for an archive action}" \
  --exported "${CI_APP_STORE_SIGNED_APP_PATH:?CI_APP_STORE_SIGNED_APP_PATH is required for an App Store release archive}" \
  --build-number 17 \
  --marketing-version 1.1 \
  --team-id 5TT564H883 \
  --archive-signing structure-only
