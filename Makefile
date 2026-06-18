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
	odin test src/libclipbender -warnings-as-errors -vet $(FLAGS)
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

SCANNER := wayland/odin-wayland/scanner/wayland-scanner
PROTO_DIR := wayland/protocols
BIND_DIR := wayland/protocols/bindings
WAYLAND_DIR := ../../odin-wayland

$(SCANNER):
	odin build wayland/odin-wayland/scanner -out:$(SCANNER)

protocols: $(SCANNER)
	$(SCANNER) $(PROTO_DIR)/ext-data-control-v1.xml $(BIND_DIR)/ext_data_control.odin bindings false false $(WAYLAND_DIR)
	$(SCANNER) $(PROTO_DIR)/wlr-data-control-unstable-v1.xml $(BIND_DIR)/wlr_data_control.odin bindings false true $(WAYLAND_DIR)
	$(SCANNER) $(PROTO_DIR)/wlr-layer-shell-unstable-v1.xml $(BIND_DIR)/wlr_layer_shell.odin bindings false true $(WAYLAND_DIR)

clean:
	rm -rf $(BUILD_DIR)

distclean: clean
	rm -f $(SCANNER)

install: all
	install -Dm755 $(BUILD_DIR)/clipbenderd $(PREFIX)/bin/clipbenderd
	install -Dm755 $(BUILD_DIR)/clipbender $(PREFIX)/bin/clipbender

.PHONY: all daemon client test debug release protocols clean distclean install
