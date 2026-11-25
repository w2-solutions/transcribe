DESTINATION := platform=iOS Simulator,name=iPhone 15,OS=27.0
MAC_DESTINATION := platform=macOS
DERIVED     ?= $(or $(TMPDIR),/tmp)/transcribe-dd

.PHONY: project build build-mac test-kit test-ui test-ui-mac sim shots models check-models archive archive-mac release-mac testflight \
        sign-mac publish-mac test-release-scripts

project:
	./scripts/bootstrap.sh

# The speech models shipped in the app, pinned by scripts/models.lock (about 700 MB; idempotent).
# make models FROM=~/Library/Caches/transcribe-test-models copies files you already have instead of downloading.
models:
	./scripts/fetch-models.sh $(if $(FROM),--from '$(patsubst ~/%,$(HOME)/%,$(FROM))')

check-models:
	./scripts/check-models.sh --hash

# Release archive for a real iPhone (needs a signing team), then a strict check of the models inside it.
archive: models
	xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -configuration Release -destination 'generic/platform=iOS' -archivePath '$(DERIVED)/Transcribe.xcarchive' archive
	./scripts/check-models.sh --app '$(DERIVED)/Transcribe.xcarchive/Products/Applications/Transcribe.app'

# Release archive of the Mac app (needs the signing team), then a strict check of the models inside it.
archive-mac: models
	xcodebuild -project Transcribe.xcodeproj -scheme TranscribeMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath '$(DERIVED)' -archivePath '$(DERIVED)/TranscribeMac.xcarchive' DEVELOPMENT_TEAM=53FBF5CS9U -allowProvisioningUpdates archive
	./scripts/check-models.sh --app '$(DERIVED)/TranscribeMac.xcarchive/Products/Applications/Transcribe.app'

# Developer ID release: archive, export, checks, signed DMG in dist/, then notarise and staple (needs the
# notarytool profile transcribe-notary; without it the script stops after the signed DMG and exits 3).
# make release-mac SKIP_NOTARIZE=1 stops after the signed DMG on purpose. DERIVED and FROM pass through.
release-mac:
	./scripts/release-mac.sh $(if $(SKIP_NOTARIZE),--skip-notarize)

# The Mac app's version (MARKETING_VERSION of TranscribeMac), read only when a target below uses it.
MAC_VERSION = $(shell ./scripts/release-mac.sh --print-version | cut -d' ' -f1)

# Sparkle-signs the stapled DMG from make release-mac with the update key in the login keychain (a person approves
# the prompt: Allow, never Always Allow). Writes dist/Transcribe-<version>.latest.json and .appcast.xml. CI signs
# with the key from the mac-release environment instead.
sign-mac:
	./scripts/sign-mac-release.sh --use-keychain "dist/Transcribe-$(MAC_VERSION).dmg"

# Manual fallback for CI's publish step (after make release-mac and make sign-mac): uploads to R2 and switches the
# page and the update feed. Needs R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID and R2_BUCKET in the shell.
publish-mac:
	./scripts/publish-mac.sh --release 'dist/Transcribe-$(MAC_VERSION).latest.json' --dmg 'dist/Transcribe-$(MAC_VERSION).dmg' --appcast 'dist/Transcribe-$(MAC_VERSION).appcast.xml'

# Tests of the release scripts and workflows (lint, version rule, Ed25519, signing, publishing to a folder, gate).
test-release-scripts:
	./scripts/tests/release-scripts-test.sh

# iPhone: archive (Release) and upload to App Store Connect for TestFlight, signed in with an API key.
testflight: models
	./scripts/testflight.sh

build:
	xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED)' build

# The Mac app (Debug, signed to run locally). The models are bundled in every configuration; a Debug build
# without them only warns.
build-mac:
	xcodebuild -project Transcribe.xcodeproj -scheme TranscribeMac -destination '$(MAC_DESTINATION)' -derivedDataPath '$(DERIVED)' build

test-kit:
	./scripts/test-kit.sh

test-ui:
	./scripts/test-ui.sh

# Mac XCUITest: takes over the screen and mouse, so never run two at once.
test-ui-mac:
	PLATFORM=mac ./scripts/test-ui.sh

# make sim SEED=library ROUTE=transcript:0 SCRIPT=newVoices SPEED=instant
sim:
	./scripts/sim.sh $(or $(SEED),library) $(or $(ROUTE),-) $(or $(SCRIPT),-) $(or $(SPEED),instant)

# The nine mockup screens, in mockup order, as PNGs in $$SHOTS (default $$TMPDIR/transcribe-shots):
# 1-library … 9-settings. PREFIX=final- names them final-1-library.png …; SIM_UDID picks the simulator.
shots:
	PREFIX='$(PREFIX)' ./scripts/sim.sh --mockups
