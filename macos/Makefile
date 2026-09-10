# TeamClaude Bar — macOS menu bar client for the teamclaude proxy.
#
#   make build      swift build (release)
#   make test       swift test
#   make app        assemble dist/TeamClaude Bar.app (ad-hoc signed)
#   make run        make app, then open it
#   make install    copy the bundle to /Applications
#   make snapshots  render the popover and settings panes to dist/snapshots/*.png
#   make clean
#
# The bundle version tracks ../package.json, so the app carries the proxy
# release it was built from without a second version file.
#
# SCRATCH=<dir> builds in a private directory (swift --scratch-path) instead of
# .build, for a second checkout or agent that must not race this one's build.

SWIFT ?= swift
SCRATCH ?=
SCRATCH_FLAG := $(if $(SCRATCH),--scratch-path $(SCRATCH),)
PRODUCT := TeamClaudeBar
APP_NAME := TeamClaude Bar
DIST := dist
APP := $(DIST)/$(APP_NAME).app
SNAPSHOT_DIR ?= $(DIST)/snapshots
VERSION := $(shell sed -n 's/^  "version": "\(.*\)",/\1/p' ../package.json)
BIN := $(shell $(SWIFT) build -c release $(SCRATCH_FLAG) --show-bin-path 2>/dev/null)

.PHONY: build test app run install snapshots clean

build:
	$(SWIFT) build -c release $(SCRATCH_FLAG) --product $(PRODUCT)

test:
	$(SWIFT) test $(SCRATCH_FLAG)

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)/$(PRODUCT)" "$(APP)/Contents/MacOS/$(PRODUCT)"
	sed 's/__VERSION__/$(VERSION)/g' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@if [ -d Resources/AppIcon.iconset ]; then iconutil -c icns Resources/AppIcon.iconset -o "$(APP)/Contents/Resources/AppIcon.icns"; fi
	codesign --force --deep --sign - --identifier com.karpeleslab.teamclaudebar "$(APP)"
	@echo "built $(APP) ($(VERSION))"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "installed /Applications/$(APP_NAME).app"

# Throwaway headless proxy + TEAMCLAUDE_BAR_SNAPSHOT; see scripts/snapshots.sh.
snapshots:
	SWIFT="$(SWIFT)" SCRATCH="$(SCRATCH)" SNAPSHOT_DIR="$(abspath $(SNAPSHOT_DIR))" scripts/snapshots.sh

clean:
	rm -rf .build $(DIST)
