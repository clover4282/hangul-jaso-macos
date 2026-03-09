SCHEME = HangulJaso
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
DERIVED_DIR = $(shell ls -td $(DERIVED_DATA)/$(SCHEME)-* 2>/dev/null | head -1)
BUILD_DIR = $(DERIVED_DIR)/Build/Products
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" HangulJaso/Resources/Info.plist)
BUILD_NUMBER = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" HangulJaso/Resources/Info.plist)

.PHONY: build release run kill rerun clean bump info help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Build Debug configuration
	xcodebuild -scheme $(SCHEME) -configuration Debug build | tail -3

release: ## Build Release configuration
	xcodebuild -scheme $(SCHEME) -configuration Release build | tail -3

run: build ## Build and run the app
	@pkill -x $(SCHEME) 2>/dev/null || true
	@sleep 1
	open "$(BUILD_DIR)/Debug/$(SCHEME).app"

kill: ## Kill running app
	@pkill -x $(SCHEME) 2>/dev/null && echo "$(SCHEME) killed" || echo "$(SCHEME) not running"

rerun: ## Kill and rerun the app
	@pkill -x $(SCHEME) 2>/dev/null || true
	@sleep 1
	open "$(BUILD_DIR)/Debug/$(SCHEME).app"

clean: ## Clean build artifacts
	xcodebuild -scheme $(SCHEME) clean | tail -3

bump: ## Bump version (usage: make bump V=1.1)
	@if [ -z "$(V)" ]; then echo "Usage: make bump V=1.x"; exit 1; fi
	@build="$${B:-$$(($(BUILD_NUMBER) + 1))}"; \
	/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $(V)" HangulJaso/Resources/Info.plist && \
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion $$build" HangulJaso/Resources/Info.plist && \
	echo "Version bumped to $(V) ($$build)"

info: ## Show current build info
	@echo "Version:    $(VERSION)"
	@echo "Build:      $(BUILD_NUMBER)"
	@echo "Scheme:     $(SCHEME)"
	@echo "Derived:    $(DERIVED_DIR)"
	@echo "Build dir:  $(BUILD_DIR)"
