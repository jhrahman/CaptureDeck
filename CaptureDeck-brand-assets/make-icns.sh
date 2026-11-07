#!/bin/bash
# Run on your Mac, in this folder: creates AppIcon.icns
set -e
cd "$(dirname "$0")"
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "Created AppIcon.icns"
