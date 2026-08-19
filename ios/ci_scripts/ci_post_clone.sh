#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH DEVELOPER_DIR SDKROOT TOOLCHAINS

script_dir="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"
exec /usr/bin/python3 -I "$script_dir/xcode-cloud-release-guard.py" --phase post-clone
