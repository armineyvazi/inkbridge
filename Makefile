# InkBridge — top-level developer commands.
# Platform details live in apps/macos/Makefile and apps/android/Makefile.

.PHONY: help test test-macos test-android check lint format build-macos build-android \
        install-macos install-android e2e clean

SWIFT_FORMAT ?= xcrun swift-format

help:
	@echo "InkBridge developer targets"
	@echo "  make test            Run macOS + Android unit/integration tests"
	@echo "  make check           Format check + tests (CI entry point)"
	@echo "  make format          Apply Swift formatting"
	@echo "  make lint            Format check (no writes) + Android lint"
	@echo "  make build-macos     Release .app into ~/Library/Caches/InkBridge"
	@echo "  make build-android   Debug APK"
	@echo "  make install-macos   Install to /Applications/InkBridge.app"
	@echo "  make install-android adb install on a connected device"
	@echo "  make e2e             Loopback client ↔ host (USB path)"
	@echo "  make clean           Remove local build caches for this project"

test: test-macos test-android

test-macos:
	$(MAKE) -C apps/macos test

test-android:
	$(MAKE) -C apps/android test

format:
	$(SWIFT_FORMAT) format -i -r apps/macos/Sources apps/macos/Tests

lint:
	$(SWIFT_FORMAT) lint -r apps/macos/Sources apps/macos/Tests
	$(MAKE) -C apps/android lint

check: lint test

build-macos:
	$(MAKE) -C apps/macos app

build-android:
	$(MAKE) -C apps/android apk

install-macos:
	$(MAKE) -C apps/macos install

install-android:
	$(MAKE) -C apps/android install

e2e:
	./scripts/e2e.sh

clean:
	$(MAKE) -C apps/macos clean
	$(MAKE) -C apps/android clean
