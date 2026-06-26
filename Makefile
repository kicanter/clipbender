PREFIX ?= /usr/local
BUILD_DIR := build
FLAGS ?=
COLLECTIONS := -collection:wayland=wayland -collection:libclipbender=src/libclipbender

$(shell mkdir -p $(BUILD_DIR))

ODIN_ROOT := $(shell odin root)
STB_LIB := $(ODIN_ROOT)/vendor/stb/lib/stb_truetype.a

# TODO: when ready to release, make default target point to release and make separate `dev` target
all: daemon client

daemon:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -warnings-as-errors -target=linux_amd64 -vet $(COLLECTIONS) $(FLAGS)

client: $(STB_LIB)
	odin build src/client -out:$(BUILD_DIR)/clipbender -warnings-as-errors -target=linux_amd64 -vet $(COLLECTIONS) $(FLAGS)

$(STB_LIB):
	make -C $(ODIN_ROOT)/vendor/stb/src

test:
ifdef PKG
	odin test src/$(PKG) -warnings-as-errors -vet $(COLLECTIONS) $(FLAGS)
else
	odin test src/libclipbender/base -warnings-as-errors -vet $(COLLECTIONS) $(FLAGS)
	odin test src/daemon -warnings-as-errors -vet $(COLLECTIONS) $(FLAGS)
	odin test src/client -warnings-as-errors -vet $(COLLECTIONS) $(FLAGS)
endif

debug:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -debug -sanitize:address -target=linux_amd64 $(COLLECTIONS)
	odin build src/client -out:$(BUILD_DIR)/clipbender -debug -sanitize:address -target=linux_amd64 $(COLLECTIONS)

release:
	odin build src/daemon -out:$(BUILD_DIR)/clipbenderd -warnings-as-errors -vet -o:speed -target=linux_amd64 $(COLLECTIONS)
	odin build src/client -out:$(BUILD_DIR)/clipbender -warnings-as-errors -vet -o:speed -target=linux_amd64 $(COLLECTIONS)
	strip $(BUILD_DIR)/clipbenderd
	strip $(BUILD_DIR)/clipbender

SCANNER := wayland/odin-wayland/scanner/wayland-scanner
WL_DIR := wayland
WAYLAND_DIR := wayland/odin-wayland

$(SCANNER):
	odin build wayland/odin-wayland/scanner -out:$(SCANNER)

protocols: $(SCANNER)
	$(SCANNER) $(WL_DIR)/ext-data-control/ext-data-control-v1.xml $(WL_DIR)/ext-data-control/ext_data_control.odin ext_data_control false false $(WAYLAND_DIR)
	$(SCANNER) $(WL_DIR)/wlr-data-control/wlr-data-control-unstable-v1.xml $(WL_DIR)/wlr-data-control/wlr_data_control.odin wlr_data_control false false $(WAYLAND_DIR)
	$(SCANNER) $(WL_DIR)/xdg-shell/xdg-shell.xml $(WL_DIR)/xdg-shell/xdg_shell.odin xdg_shell false false $(WAYLAND_DIR)
	$(SCANNER) $(WL_DIR)/wlr-layer-shell/wlr-layer-shell-unstable-v1.xml $(WL_DIR)/wlr-layer-shell/wlr_layer_shell.odin wlr_layer_shell false false $(WAYLAND_DIR)

clean:
	rm -rf $(BUILD_DIR)

distclean: clean
	rm -f $(SCANNER)

install: all
	install -Dm755 $(BUILD_DIR)/clipbenderd $(PREFIX)/bin/clipbenderd
	install -Dm755 $(BUILD_DIR)/clipbender $(PREFIX)/bin/clipbender

.PHONY: all daemon client test debug release protocols clean distclean install
