# TeamClaude Bar — macOS menu bar client for the teamclaude proxy.
#
#   make build      swift build (release)
#   make test       swift test
#   make app        assemble dist/TeamClaude Bar.app (ad-hoc signed)
#   make run        make app, then open it
#   make install    copy the bundle to /Applications
#   make clean
#
# The bundle version tracks ../package.json, so the app carries the proxy
# release it was built from without a second version file.

SWIFT ?= swift
PRODUCT := TeamClaudeBar
APP_NAME := TeamClaude Bar
DIST := dist
APP := $(DIST)/$(APP_NAME).app
VERSION := $(shell sed -n 's/^  "version": "\(.*\)",/\1/p' ../package.json)
BIN := $(shell $(SWIFT) build -c release --show-bin-path 2>/dev/null)

.PHONY: build test app run install clean

build:
	$(SWIFT) build -c release --product $(PRODUCT)

test:
	$(SWIFT) test

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

clean:
	rm -rf .build $(DIST)
