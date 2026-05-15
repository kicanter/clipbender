PREFIX ?= /usr/local
BUILD_DIR := build

all: daemon client

daemon:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd

client:
	odin build src/client -out:$(BUILD_DIR)/clipbender

test:
	odin test tests

clean:
	rm -rf $(BUILD_DIR)

install: all
	install -Dm755 $(BUILD_DIR)/clipbenderd $(PREFIX)/bin/clipbenderd
	install -Dm755 $(BUILD_DIR)/clipbender $(PREFIX)/bin/clipbender

.PHONY: all daemon client test clean install
