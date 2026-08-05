APP_NAME   = FishAudioDemo
BUILD_DIR  = .build/release
APP_BUNDLE = dist/$(APP_NAME).app

.PHONY: build bundle sign run clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Packaging/Info.plist $(APP_BUNDLE)/Contents/Info.plist

sign: bundle
	codesign --force --deep --sign - $(APP_BUNDLE)

run: sign
	open $(APP_BUNDLE)

clean:
	rm -rf .build dist
