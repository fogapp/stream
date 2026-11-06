## Stream for Apple TV — build and test (PROPOSAL §11 Phase 6)

# Recipes that pipe xcodebuild into xcbeautify start with `set -o
# pipefail`: otherwise a failed archive or export exits with xcbeautify's
# 0 and release carries on. (macOS's make is 3.81, which ignores
# .SHELLFLAGS, so it's said in each recipe.)
SHELL       := /bin/bash

# Your Apple Developer team, for signing on a real Apple TV and for
# `make release`. Put it in Local.mk (untracked), e.g.
#   STREAM_TEAM_ID = ABCDE12345
# or pass it: `make open STREAM_TEAM_ID=ABCDE12345`. project.yml reads it
# from the environment when `make gen` runs. Simulator builds need none.
-include Local.mk
export STREAM_TEAM_ID

SCHEME      = StreamTV
PROJECT     = StreamTV.xcodeproj
SIMULATOR   ?= Apple TV 4K (3rd generation)
OS          ?= latest
DESTINATION = platform=tvOS Simulator,name=$(SIMULATOR),OS=$(OS)

.PHONY: help gen build test ui lint open clean

help:
	@echo "  make gen     Regenerate StreamTV.xcodeproj from project.yml (brew install xcodegen)"
	@echo "  make build   Build for the tvOS simulator"
	@echo "  make test    Colour lint, then the unit tests on the tvOS simulator"
	@echo "  make ui      Drive the showcase with the remote; screenshots in build/screenshots"
	@echo "  make lint    Every colour from Palette (the design guard)"
	@echo "  make open    Open the project in Xcode (then run it on an Apple TV)"

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" CODE_SIGNING_ALLOWED=NO build

lint:
	Scripts/lint-colors.sh

test: gen lint
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" CODE_SIGNING_ALLOWED=NO -only-testing:StreamTVTests test

ui: gen lint
	rm -rf build/ui.xcresult build/screenshots
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "$(DESTINATION)" CODE_SIGNING_ALLOWED=NO \
		-only-testing:StreamTVUITests -resultBundlePath build/ui.xcresult test; status=$$?; \
		Scripts/export-screenshots.py build/ui.xcresult build/screenshots; exit $$status

open: gen
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) build DerivedData

# Maintainer-only: archive and upload to the maintainer's TestFlight.
ARCHIVE     = build/StreamTV.xcarchive
EXPORT_OPTS = ExportOptions.plist

.PHONY: archive export release bump-version open-asc

archive: gen
	@test -n "$(STREAM_TEAM_ID)" || { echo "Set STREAM_TEAM_ID (see Local.mk above)" >&2; exit 1; }
	@echo "→ Archiving..."
	set -o pipefail; xcodebuild archive \
		-allowProvisioningUpdates \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-archivePath $(ARCHIVE) \
		-destination "generic/platform=tvOS" | xcbeautify

export: archive
	@echo "→ Exporting + uploading to TestFlight..."
	set -o pipefail; xcodebuild -exportArchive \
		-allowProvisioningUpdates \
		-archivePath $(ARCHIVE) \
		-exportPath build/export \
		-exportOptionsPlist $(EXPORT_OPTS) | xcbeautify

release: export
	@echo ""
	@echo "🚀 Stream for Apple TV shipped to TestFlight!"
	@echo "   Add the build at: https://appstoreconnect.apple.com/apps"

bump-version:
ifndef V
	$(error Usage: make bump-version V=1.1)
endif
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" StreamTV/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" StreamTopShelf/Info.plist
	@echo "✓ Version set to $(V)"

open-asc:
	open "https://appstoreconnect.apple.com/apps"
