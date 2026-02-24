#!/bin/bash
# Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GO_DIR="$PROJECT_DIR/Go/mihomo-bridge"
OUTPUT_DIR="$PROJECT_DIR/Framework"

echo "==> Checking prerequisites..."

if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed. Install Go 1.22+ from https://go.dev"
    exit 1
fi

echo "Go version: $(go version)"

# Install gomobile if needed
if ! command -v gomobile &> /dev/null; then
    echo "==> Installing gomobile..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
fi

echo "==> Initializing gomobile..."
gomobile init

echo "==> Downloading Go dependencies..."
cd "$GO_DIR"
go mod tidy

echo "==> Building MihomoCore.xcframework..."
mkdir -p "$OUTPUT_DIR"

gomobile bind \
    -target=ios,iossimulator \
    -o "$OUTPUT_DIR/MihomoCore.xcframework" \
    -iosversion=15.0 \
    -tags=ios \
    -ldflags="-s -w" \
    .

echo "==> Done! Framework built at: $OUTPUT_DIR/MihomoCore.xcframework"
echo ""
echo "Next steps:"
echo "  1. Open BaoLianDeng.xcodeproj in Xcode"
echo "  2. Configure signing for both targets"
echo "  3. Build and run on your device"
