PREFIX ?= /usr/local
BUILD_DIR := build
FLAGS ?=

$(shell mkdir -p $(BUILD_DIR))

# TODO: when ready to release, make default target point to release and make separate `dev` target
all: daemon client

daemon:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -warnings-as-errors -target=linux_amd64 -vet $(FLAGS)

client:
	odin build src/client -out:$(BUILD_DIR)/clipbender -warnings-as-errors -target=linux_amd64 -vet $(FLAGS)

test:
ifdef PKG
	odin test src/$(PKG) -warnings-as-errors -vet $(FLAGS)
else
	odin test src/lib -warnings-as-errors -vet $(FLAGS)
	odin test src/daemon -warnings-as-errors -vet $(FLAGS)
	odin test src/client -warnings-as-errors -vet $(FLAGS)
endif

debug:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -debug -sanitize:address -target=linux_amd64
	odin build src/client -out:$(BUILD_DIR)/clipbender -debug -sanitize:address -target=linux_amd64

release:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -warnings-as-errors -vet -o:speed -target=linux_amd64
	odin build src/client -out:$(BUILD_DIR)/clipbender -warnings-as-errors -vet -o:speed -target=linux_amd64
	strip $(BUILD_DIR)/clipbenderd
	strip $(BUILD_DIR)/clipbender

clean:
	rm -rf $(BUILD_DIR)

install: all
	install -Dm755 $(BUILD_DIR)/clipbenderd $(PREFIX)/bin/clipbenderd
	install -Dm755 $(BUILD_DIR)/clipbender $(PREFIX)/bin/clipbender

.PHONY: all daemon client test debug release clean install
