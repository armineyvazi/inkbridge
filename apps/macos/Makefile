# Build output lives outside the source tree: synced folders (Dropbox,
# iCloud) attach extended attributes that make `codesign` fail with
# "resource fork, Finder information, or similar detritus not allowed".
BUILD_DIR ?= $(HOME)/Library/Caches/InkBridge/macos-build
SWIFT     := swift
FLAGS     := --scratch-path $(BUILD_DIR)

.PHONY: build release test bench app install run probe clean

build:
	$(SWIFT) build $(FLAGS)

release:
	$(SWIFT) build $(FLAGS) -c release

test:
	$(SWIFT) test $(FLAGS)

bench:
	$(SWIFT) test $(FLAGS) -c release --filter PerformanceTests

app: release
	BUILD_DIR=$(BUILD_DIR) ./scripts/build-app.sh

# Copies the app to /Applications so it shows up in Launchpad/Spotlight and
# macOS privacy settings can find it. Quit a running copy first.
install: app
	-osascript -e 'quit app "InkBridge"' 2>/dev/null
	rm -rf /Applications/InkBridge.app
	ditto $(BUILD_DIR)/InkBridge.app /Applications/InkBridge.app
	@echo "installed /Applications/InkBridge.app"

run: install
	open /Applications/InkBridge.app

probe:
	$(SWIFT) run $(FLAGS) -c release inkbridge-probe $(ARGS)

clean:
	rm -rf $(BUILD_DIR)
