APP := build/OneShot.app
INSTALL_DIR ?= /Applications

.PHONY: build app install run clean cert

build:
	swift build

app:
	./scripts/build-app.sh

install: app
	pkill -x OneShot || true
	rm -rf "$(INSTALL_DIR)/OneShot.app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/OneShot.app"

run: app
	pkill -x OneShot || true
	open $(APP)

cert:
	./scripts/create-dev-cert.sh

clean:
	rm -rf .build build
