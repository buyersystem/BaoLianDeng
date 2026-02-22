# Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
#
# Licensed under the MIT License. See LICENSE file in the project root for details.

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
