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

.PHONY: all ios clean

GOMOBILE := $(shell go env GOPATH)/bin/gomobile
GOBIND := $(shell go env GOPATH)/bin/gobind
OUTPUT_DIR := ../../Framework
FRAMEWORK_NAME := MihomoCore

all: ios

setup:
	go install golang.org/x/mobile/cmd/gomobile@latest
	go install golang.org/x/mobile/cmd/gobind@latest
	$(GOMOBILE) init

ios: setup
	mkdir -p $(OUTPUT_DIR)
	$(GOMOBILE) bind \
		-target=ios,iossimulator \
		-o $(OUTPUT_DIR)/$(FRAMEWORK_NAME).xcframework \
		-iosversion=17.0 \
		-tags=ios,with_gvisor \
		-ldflags="-s -w" \
		.

ios-arm64: setup
	mkdir -p $(OUTPUT_DIR)
	$(GOMOBILE) bind \
		-target=ios/arm64 \
		-o $(OUTPUT_DIR)/$(FRAMEWORK_NAME).xcframework \
		-iosversion=17.0 \
		-tags=ios,with_gvisor \
		-ldflags="-s -w" \
		.

clean:
	rm -rf $(OUTPUT_DIR)/$(FRAMEWORK_NAME).xcframework
