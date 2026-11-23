DESTINATION := platform=iOS Simulator,name=iPhone 15,OS=27.0
DERIVED     ?= $(or $(TMPDIR),/tmp)/transcribe-dd

.PHONY: project build test-kit test-ui sim shots

project:
	./scripts/bootstrap.sh

build:
	xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED)' build

test-kit:
	./scripts/test-kit.sh

test-ui:
	./scripts/test-ui.sh

# make sim SEED=library ROUTE=transcript:0 SCRIPT=newVoices SPEED=instant
sim:
	./scripts/sim.sh $(or $(SEED),library) $(or $(ROUTE),-) $(or $(SCRIPT),-) $(or $(SPEED),instant)

# The nine mockup screens, in mockup order, as PNGs in $$SHOTS (default $$TMPDIR/transcribe-shots):
# 1-library … 9-settings. PREFIX=final- names them final-1-library.png …; SIM_UDID picks the simulator.
shots:
	PREFIX='$(PREFIX)' ./scripts/sim.sh --mockups
