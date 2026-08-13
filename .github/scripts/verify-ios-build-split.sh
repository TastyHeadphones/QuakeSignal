#!/usr/bin/env bash
# Verify that the public Release executable cannot contain the internal-only
# delayed-training request or Settings control, while InternalQA does compile
# both. This is deliberately artifact-based: source guards alone are not
# sufficient evidence for a shipped archive boundary.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <release-app> <internal-qa-app>" >&2
  exit 64
fi

release_app="$1"
internal_qa_app="$2"

app_executable() {
  local app="$1"
  local executable

  if [ ! -d "$app" ]; then
    echo "::error::Expected app bundle is missing: $app" >&2
    return 1
  fi
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
  if [ -z "$executable" ] || [ ! -f "$app/$executable" ]; then
    echo "::error::Expected app executable is missing: $app/$executable" >&2
    return 1
  fi
  printf '%s\n' "$app/$executable"
}

release_executable="$(app_executable "$release_app")"
internal_qa_executable="$(app_executable "$internal_qa_app")"
release_strings="$(LC_ALL=C strings "$release_executable")"
internal_qa_strings="$(LC_ALL=C strings "$internal_qa_executable")"

assert_absent() {
  local marker="$1"
  if grep -Fqx -- "$marker" <<<"$release_strings"; then
    echo "::error::Public Release contains internal-only marker: $marker" >&2
    return 1
  fi
}

assert_present() {
  local marker="$1"
  if ! grep -Fqx -- "$marker" <<<"$internal_qa_strings"; then
    echo "::error::InternalQA is missing required marker: $marker" >&2
    return 1
  fi
}

# The first marker is the wire contract; the second is the exact Settings UI
# localization key. Neither may be compiled into a public Release executable.
for marker in delayed-training settings.delayedTestAlert; do
  assert_absent "$marker"
  assert_present "$marker"
done

echo "Verified public Release excludes the delayed-training request and Settings UI; InternalQA includes both."
