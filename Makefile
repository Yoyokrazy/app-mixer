APP_NAME := AppMixer
BUNDLE_ID := com.yoyokrazy.AppMixer
APP := build/Build/Products/Release/$(APP_NAME).app

.PHONY: project build run install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release -derivedDataPath build -quiet build

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
