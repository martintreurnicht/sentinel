APP_NAME := Sentinel
BUNDLE_ID := com.github.martintreurnicht.sentinel
CONFIG := release
# Override for a stable TCC grant across rebuilds, e.g.:
#   make CODESIGN_IDENTITY="Apple Development"
CODESIGN_IDENTITY ?= -
ENTITLEMENTS := Support/Sentinel.entitlements
# Extra swift build flags, e.g. ARCH_FLAGS="--arch arm64 --arch x86_64" for a universal build.
ARCH_FLAGS ?=
# Sparkle.framework is a binary SwiftPM dependency embedded in Contents/Frameworks
# and resolved via @rpath at runtime.
LINKER_FLAGS := -Xlinker -rpath -Xlinker @executable_path/../Frameworks
# Hardened runtime + timestamp only with a real identity; ad-hoc ("-") keeps plain
# signing (library validation under ad-hoc would reject the embedded framework).
CODESIGN_OPTS := $(if $(filter -,$(CODESIGN_IDENTITY)),,-o runtime --timestamp)
# Release stamping (used by CI): VERSION -> CFBundleShortVersionString,
# BUILD_NUMBER -> CFBundleVersion. Applied to the bundled copy of Info.plist only;
# the checked-in Support/Info.plist keeps its placeholder.
VERSION ?=
BUILD_NUMBER ?=
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
DMG := $(BUILD_DIR)/$(APP_NAME)$(if $(VERSION),-$(VERSION)).dmg
ZIP := $(BUILD_DIR)/$(APP_NAME)$(if $(VERSION),-$(VERSION)).zip
ICON_DIR := $(BUILD_DIR)/icon
ICONSET := $(ICON_DIR)/$(APP_NAME).iconset
ICNS := $(BUILD_DIR)/AppIcon.icns
# Linting: SwiftLint is fetched at a pinned version with a checksum so local
# runs and CI use the identical binary; shellcheck and actionlint come from
# Homebrew (brew install shellcheck actionlint). Bump version and checksum
# together (shasum -a 256 of the release's portable_swiftlint.zip).
SWIFTLINT_VERSION := 0.63.3
SWIFTLINT_SHA256 := fb045e85e7cb3374f42a4840b6b85a0106302afa69035c0c6f29af4a44c810b6
SWIFTLINT_DIR := .build/swiftlint-$(SWIFTLINT_VERSION)
SWIFTLINT := $(SWIFTLINT_DIR)/swiftlint

.PHONY: all build bundle icon dmg zip run install uninstall test lint lint-fix verify notarize verify-notarized logs clean

all: bundle

build:
	swift build -c $(CONFIG) $(ARCH_FLAGS) $(LINKER_FLAGS)

icon: $(ICNS)

$(ICNS): scripts/generate-icon.swift
	swift scripts/generate-icon.swift "$(ICON_DIR)"
	iconutil -c icns -o "$(ICNS)" "$(ICONSET)"

# Nested Sparkle components are re-signed inside-out (never --deep): each outer
# signature seals the already-final inner code, so --verify --strict passes.
bundle: build $(ICNS)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Frameworks"
	cp "$$(swift build -c $(CONFIG) $(ARCH_FLAGS) $(LINKER_FLAGS) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	fw="$$(find .build/artifacts -type d -name Sparkle.framework | head -n 1)" && test -d "$$fw" && ditto "$$fw" "$(APP)/Contents/Frameworks/Sparkle.framework"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	mkdir -p "$(APP)/Contents/Resources"
	cp "$(ICNS)" "$(APP)/Contents/Resources/AppIcon.icns"
	if [ -n "$(VERSION)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP)/Contents/Info.plist"; fi
	if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"; fi
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) --preserve-metadata=entitlements "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) "$(APP)/Contents/Frameworks/Sparkle.framework"
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(CODESIGN_OPTS) --entitlements "$(ENTITLEMENTS)" --identifier $(BUNDLE_ID) "$(APP)"

dmg: bundle
	rm -rf "$(BUILD_DIR)/dmg-staging" "$(DMG)"
	mkdir -p "$(BUILD_DIR)/dmg-staging"
	ditto "$(APP)" "$(BUILD_DIR)/dmg-staging/$(APP_NAME).app"
	ln -s /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	for attempt in 1 2 3; do \
		hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg-staging" -ov -format UDZO "$(DMG)" && break; \
		echo "hdiutil create failed (attempt $$attempt), retrying..."; sleep 2; \
	done
	test -f "$(DMG)"
	if [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" --timestamp "$(DMG)"; \
	fi
	rm -rf "$(BUILD_DIR)/dmg-staging"
	@echo "Created $(DMG)"

# Sparkle update archive; the DMG remains the first-install format.
zip: bundle
	rm -f "$(ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	@echo "Created $(ZIP)"

run: bundle
	pkill -x $(APP_NAME) 2>/dev/null || true
	open "$(APP)"

install: bundle
	pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP)" "/Applications/$(APP_NAME).app"
	touch "/Applications/$(APP_NAME).app"
	open "/Applications/$(APP_NAME).app"

uninstall:
	pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "/Applications/$(APP_NAME).app"
	@echo "To also reset the camera permission: tccutil reset Camera $(BUNDLE_ID)"

test:
	swift test

$(SWIFTLINT):
	mkdir -p "$(SWIFTLINT_DIR)"
	curl -fsSL -o "$(SWIFTLINT_DIR)/portable_swiftlint.zip" "https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip"
	echo "$(SWIFTLINT_SHA256)  $(SWIFTLINT_DIR)/portable_swiftlint.zip" | shasum -a 256 -c
	unzip -oq "$(SWIFTLINT_DIR)/portable_swiftlint.zip" swiftlint -d "$(SWIFTLINT_DIR)"
	rm "$(SWIFTLINT_DIR)/portable_swiftlint.zip"

# Swift (strict: warnings fail), shell scripts, and workflow YAML. actionlint
# also runs shellcheck over workflow run: blocks when shellcheck is on PATH.
lint: $(SWIFTLINT)
	@command -v shellcheck >/dev/null || { echo "shellcheck not found — brew install shellcheck"; exit 1; }
	@command -v actionlint >/dev/null || { echo "actionlint not found — brew install actionlint"; exit 1; }
	"$(SWIFTLINT)" lint --strict --quiet
	shellcheck scripts/*.sh
	actionlint

lint-fix: $(SWIFTLINT)
	"$(SWIFTLINT)" lint --fix --quiet

verify:
	plutil -lint Support/Info.plist
	plutil -lint $(ENTITLEMENTS)
	test -d "$(APP)/Contents/Frameworks/Sparkle.framework"
	otool -l "$(APP)/Contents/MacOS/$(APP_NAME)" | grep -q "@executable_path/../Frameworks"
	codesign --verify --strict --deep -v "$(APP)"
	codesign -d -r- "$(APP)"
	test -s "$(APP)/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$(APP)/Contents/Info.plist" >/dev/null
	codesign -d --entitlements - "$(APP)" | grep -q com.apple.security.device.camera

# Submit the DMG to Apple's notary service and staple the ticket.
# Needs NOTARY_KEY / NOTARY_KEY_ID / NOTARY_KEY_ISSUER_ID in the environment.
notarize:
	scripts/notarize.sh "$(DMG)"

# Post-notarization checks; needs network for the Gatekeeper ticket lookup.
# The hardened-runtime check lives here, not in verify: ad-hoc dev builds sign
# without it (library validation would reject the embedded Sparkle.framework).
verify-notarized:
	codesign -dvv "$(APP)" 2>&1 | grep -q "Developer ID Application"
	codesign -d -v "$(APP)" 2>&1 | grep -q 'flags=.*runtime'
	spctl --assess --type execute -vv "$(APP)"
	xcrun stapler validate "$(DMG)"

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --info --debug

clean:
	rm -rf .build $(BUILD_DIR)
