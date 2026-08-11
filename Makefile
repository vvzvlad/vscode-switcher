.PHONY: build test app icons install uninstall run dump hooks clean

build:
	cd macos && swift build -c release

icons:
	bash macos/scripts/make-icons.sh

test:
	cd macos && swift test

app:
	bash macos/scripts/build.sh

install: app
	pkill -x VSCodeSwitcher || true
	rm -rf /Applications/VSCodeSwitcher.app
	cp -R macos/VSCodeSwitcher.app /Applications/
	open /Applications/VSCodeSwitcher.app

run: app
	pkill -x VSCodeSwitcher || true
	open macos/VSCodeSwitcher.app

dump: build
	./macos/.build/release/VSCodeSwitcher --dump

hooks:
	bash scripts/install-hooks.sh

uninstall:
	pkill -x VSCodeSwitcher || true
	rm -rf /Applications/VSCodeSwitcher.app

clean:
	cd macos && swift package clean
	rm -rf macos/VSCodeSwitcher.app
