APP_NAME := AppMixer
BUNDLE_ID := com.yoyokrazy.AppMixer
APP := build/Build/Products/Release/$(APP_NAME).app
# Extra xcodebuild settings, e.g. CI passes version numbers and ad-hoc signing.
XCODEBUILD_FLAGS ?=

.PHONY: project build run install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build -quiet $(XCODEBUILD_FLAGS) build

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
