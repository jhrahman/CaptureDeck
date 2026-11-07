#!/bin/bash
# Runs unit tests. With full Xcode, plain `swift test` works. With only the
# Command Line Tools, Swift Testing lives in a non-default location, so add its paths.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="/Library/Developer/CommandLineTools/Library/Developer"
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$DEV/Frameworks/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -F -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi
exec swift test "$@"
