PREFIX ?= $(HOME)/.local
SWIFT_BUILD_FLAGS ?=

.PHONY: build test install

build:
	swift build -c release $(SWIFT_BUILD_FLAGS)

test:
	swift test $(SWIFT_BUILD_FLAGS)

install: build
	install -d "$(PREFIX)/bin"
	install -m 755 "$$(swift build -c release $(SWIFT_BUILD_FLAGS) --show-bin-path)/sing" "$(PREFIX)/bin/sing"
