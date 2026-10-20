APP_NAME := AppMixer
BUNDLE_ID := com.yoyokrazy.AppMixer
APP := build/Build/Products/Release/$(APP_NAME).app
# Extra xcodebuild settings, e.g. CI passes version numbers and ad-hoc signing.
XCODEBUILD_FLAGS ?=

.PHONY: project build run install clean snapshots record-snapshots

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build -quiet $(XCODEBUILD_FLAGS) build

# Visual regression tests: render the views from fixtures and compare them to AppMixerSnapshotTests/__Snapshots__.
# Mismatches write actual/diff/reference PNGs to build/snapshot-failures. After an intended UI change, run
# `make record-snapshots`, look at the updated PNGs, and commit them.
SNAPSHOT_TESTS = xcodebuild -project $(APP_NAME).xcodeproj -scheme AppMixerSnapshotTests -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath build $(XCODEBUILD_FLAGS) test
# -quiet would hide Swift Testing's results, so keep just errors and the test lines (✔/✘ plus each issue's details).
SNAPSHOT_OUTPUT = { grep -E '(^|: )error: |^(✔|✘|↳ Snapshot|↳ No reference|    (reference|actual|diff):|  If the change|\*\* TEST)' || true; }

snapshots: project
	@set -o pipefail; $(SNAPSHOT_TESTS) 2>&1 | $(SNAPSHOT_OUTPUT)

record-snapshots: project
	@set -o pipefail; TEST_RUNNER_RECORD_SNAPSHOTS=1 $(SNAPSHOT_TESTS) 2>&1 | $(SNAPSHOT_OUTPUT)

# Quit gracefully (so taps are torn down) before relaunching.
run: build
	-osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	open $(APP)

install: build
	-osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	open /Applications/$(APP_NAME).app

clean:
	rm -rf build $(APP_NAME).xcodeproj
