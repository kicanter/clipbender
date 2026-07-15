#!/usr/bin/env bash
# clipbender build script. The Makefile delegates to this; run it directly for
# development or via `make <target>` for the conventional interface.
#
# Usage: ./build.sh <command> [package]
#   ./build.sh dev [daemon|client]      # unoptimized build (-vet -warnings-as-errors)
#   ./build.sh debug [daemon|client]    # -debug -sanitize:address
#   ./build.sh release [daemon|client]  # -o:speed, then strip (default command)
#   ./build.sh test [package]           # run tests (all, or one src/ package)
#   ./build.sh protocols                # regenerate Wayland bindings
#   ./build.sh install                  # build release + install (honors PREFIX/DESTDIR)
#   ./build.sh uninstall
#   ./build.sh clean
#   ./build.sh distclean
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR="build"
COLLECTIONS=(-collection:src=src -collection:wayland=wayland -collection:bindings=bindings)
FLAGS="${FLAGS:-}"

# Install locations (override via environment, e.g. `PREFIX=~/.local ./build.sh install`)
PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
BINDIR="${BINDIR:-$PREFIX/bin}"
SYSTEMD_DIR="${SYSTEMD_DIR:-$PREFIX/lib/systemd/user}"
BASH_COMP_DIR="${BASH_COMP_DIR:-$PREFIX/share/bash-completion/completions}"
ZSH_COMP_DIR="${ZSH_COMP_DIR:-$PREFIX/share/zsh/site-functions}"
FISH_COMP_DIR="${FISH_COMP_DIR:-$PREFIX/share/fish/vendor_completions.d}"

STB_LIB="$(odin root)/vendor/stb/lib/stb_truetype.a"

# package src dir -> output binary name
out_name() {
    case "$1" in
    daemon) echo "clipbenderd" ;;
    client) echo "clipbender" ;;
    *) echo "unknown package: $1 (expected daemon|client)" >&2; exit 2 ;;
    esac
}

# Build the vendored stb_truetype static lib if missing (only the client links it).
ensure_stb() {
    [[ -f "$STB_LIB" ]] && return
    make -C "$(odin root)/vendor/stb/src"
}

# build_pkg <mode> <package>
build_pkg() {
    local mode="$1" pkg="$2" out
    out="$(out_name "$pkg")"
    [[ "$pkg" == "client" ]] && ensure_stb

    local mode_flags=()
    case "$mode" in
    dev)     mode_flags=(-warnings-as-errors -vet) ;;
    debug)   mode_flags=(-debug -sanitize:address) ;;
    release) mode_flags=(-warnings-as-errors -vet -o:speed) ;;
    esac

    # shellcheck disable=SC2086
    odin build "src/$pkg" -out:"$BUILD_DIR/$out" -target=linux_amd64 \
        "${mode_flags[@]}" "${COLLECTIONS[@]}" $FLAGS

    [[ "$mode" == "release" ]] && strip "$BUILD_DIR/$out"
    return 0
}

# build <mode> [package]  — builds both packages when no package is given
build() {
    local mode="$1" pkg="${2:-}"
    mkdir -p "$BUILD_DIR"
    if [[ -n "$pkg" ]]; then
        build_pkg "$mode" "$pkg"
    else
        build_pkg "$mode" daemon
        build_pkg "$mode" client
    fi
}

run_tests() {
    local pkg="${1:-}"
    local pkgs
    if [[ -n "$pkg" ]]; then
        pkgs=("src/$pkg")
    else
        pkgs=(src/libclipbender src/daemon src/client)
    fi
    for p in "${pkgs[@]}"; do
        # shellcheck disable=SC2086
        odin test "$p" -warnings-as-errors -vet "${COLLECTIONS[@]}" $FLAGS
    done
}

gen_protocols() {
    local scanner="wayland/odin-wayland/scanner/wayland-scanner"
    local wl="wayland" wldir="wayland/odin-wayland"
    [[ -f "$scanner" ]] || odin build wayland/odin-wayland/scanner -out:"$scanner"

    "$scanner" "$wl/ext-data-control/ext-data-control-v1.xml" "$wl/ext-data-control/ext_data_control.odin" ext_data_control false false "$wldir"
    "$scanner" "$wl/wlr-data-control/wlr-data-control-unstable-v1.xml" "$wl/wlr-data-control/wlr_data_control.odin" wlr_data_control false false "$wldir"
    "$scanner" "$wl/xdg-shell/xdg-shell.xml" "$wl/xdg-shell/xdg_shell.odin" xdg_shell false false "$wldir"
    "$scanner" "$wl/wlr-layer-shell/wlr-layer-shell-unstable-v1.xml" "$wl/wlr-layer-shell/wlr_layer_shell.odin" wlr_layer_shell false false "$wldir"

    # TODO: Remove once odin-wayland scanner handles cross-protocol imports
    sed -i '/^import wl/a import xdg_shell "../xdg-shell"' "$wl/wlr-layer-shell/wlr_layer_shell.odin"
    sed -i 's/&popup_interface/\&xdg_shell.popup_interface/g' "$wl/wlr-layer-shell/wlr_layer_shell.odin"
    sed -i 's/popup_: \^popup/popup_: ^xdg_shell.popup/g' "$wl/wlr-layer-shell/wlr_layer_shell.odin"
}

do_install() {
    build release
    install -Dm755 "$BUILD_DIR/clipbenderd" "$DESTDIR$BINDIR/clipbenderd"
    install -Dm755 "$BUILD_DIR/clipbender" "$DESTDIR$BINDIR/clipbender"
    install -Dm644 packaging/systemd/clipbenderd.service "$DESTDIR$SYSTEMD_DIR/clipbenderd.service"
    install -Dm644 packaging/completions/clipbender.bash "$DESTDIR$BASH_COMP_DIR/clipbender"
    install -Dm644 packaging/completions/_clipbender "$DESTDIR$ZSH_COMP_DIR/_clipbender"
    install -Dm644 packaging/completions/clipbender.fish "$DESTDIR$FISH_COMP_DIR/clipbender.fish"
    echo "Installed. nushell users: source packaging/completions/clipbender.nu from your config.nu"
}

do_uninstall() {
    rm -f "$DESTDIR$BINDIR/clipbenderd" "$DESTDIR$BINDIR/clipbender"
    rm -f "$DESTDIR$SYSTEMD_DIR/clipbenderd.service"
    rm -f "$DESTDIR$BASH_COMP_DIR/clipbender"
    rm -f "$DESTDIR$ZSH_COMP_DIR/_clipbender"
    rm -f "$DESTDIR$FISH_COMP_DIR/clipbender.fish"
}

cmd="${1:-release}"
shift || true
case "$cmd" in
dev | debug | release) build "$cmd" "$@" ;;
test)                  run_tests "$@" ;;
protocols)             gen_protocols ;;
install)               do_install ;;
uninstall)             do_uninstall ;;
clean)                 rm -rf "$BUILD_DIR" ;;
distclean)             rm -rf "$BUILD_DIR"; rm -f wayland/odin-wayland/scanner/wayland-scanner ;;
*)                     echo "unknown command: $cmd" >&2; exit 2 ;;
esac
