.PHONY: build test app icons install uninstall run dump hooks clean

build:
	cd macos && swift build -c release

icons:
	bash macos/scripts/make-icons.sh

test:
	cd macos && swift test
	bash scripts/test-hooks.sh

app:
	bash macos/scripts/build.sh

install: app
	pkill -x VSCodeSwitcher || true
	rm -rf /Applications/VSCodeSwitcher.app
	# ditto, not cp -R: it preserves the extended attributes and the signature
	# layout of the bundle, which cp is free to mangle.
	ditto macos/VSCodeSwitcher.app /Applications/VSCodeSwitcher.app
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
	# swift package clean only knows about its own build products; the iconset
	# intermediates from make-icons.sh live in the same directory.
	rm -rf macos/.build/icons
