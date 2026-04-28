PROJECT := Retrospective.xcodeproj
SCHEME := Retrospective
BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Retrospective.app
INSTALL_DIR := /Applications

.PHONY: project icon release install run clean

# Regenerate the Xcode project from project.yml.
project:
	xcodegen generate

# Regenerate the AppIcon set from scripts/icon-source.jpg.
icon:
	swift scripts/generate-icon.swift

# Build a Release configuration .app under ./build.
release: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -derivedDataPath $(BUILD_DIR) clean build

# Build Release and copy to /Applications. Replaces any existing copy.
install: release
	rm -rf $(INSTALL_DIR)/Retrospective.app
	cp -R $(APP) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/Retrospective.app"

# Open the installed app (it's a menu-bar agent — look in the status bar).
run:
	open -a Retrospective

clean:
	rm -rf $(BUILD_DIR)
