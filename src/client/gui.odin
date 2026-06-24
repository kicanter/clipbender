package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"

import wl "wayland:odin-wayland"
import wlr_ls "wayland:wlr-layer-shell"

Gui_State :: struct {
    // General connection state
    display:          ^wl.display,
    registry:         ^wl.registry,
    seat:             ^wl.seat,
    seat_name:        uint,
    compositor:       ^wl.compositor,
    compositor_name:  uint,
    shm:              ^wl.shm,
    shm_name:         uint,
    layer_shell:      ^wlr_ls.layer_shell_v1,
    layer_shell_name: uint,
    running:          bool,
    // Surface-specific state
    surface:          ^wl.surface,
    layer_surface:    ^wlr_ls.layer_surface_v1,
}

gui_init_surface :: proc(gui_state: ^Gui_State) {
    // Init wl_surface and wlr_layer_surface
    gui_state.surface = wl.compositor_create_surface(gui_state.compositor)
    gui_state.layer_surface = wlr_ls.layer_shell_v1_get_layer_surface(
        gui_state.layer_shell,
        gui_state.surface,
        nil, // output = `nil` means let the compositor choose
        .overlay,
        "clipbender",
    )

    // Configure layer surface
    width: uint = 800
    height: uint = 600
    wlr_ls.layer_surface_v1_set_size(gui_state.layer_surface, width, height)
    wlr_ls.layer_surface_v1_set_keyboard_interactivity(gui_state.layer_surface, .exclusive)

    // Add listener
    wlr_ls.layer_surface_v1_add_listener(gui_state.layer_surface, &layer_surface_listener, rawptr(gui_state))
    wl.surface_commit(gui_state.surface)
}

gui_init :: proc() -> Gui_State {
    gui_state: Gui_State
    gui_state.running = true

    gui_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if gui_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return {}
    }

    // Get registry
    gui_state.registry = wl.display_get_registry(gui_state.display)
    wl.registry_add_listener(gui_state.registry, &registry_listener, &gui_state)

    // Roundtrip to receive registry events (binds seat, compositor, shm, and layer_shell)
    wl.display_roundtrip(gui_state.display)
    if gui_state.seat == nil {
        log.error("Failed to bind Wayland seat")
        return {}
    }
    if gui_state.compositor == nil {
        log.error("Failed to bind Wayland compositor")
        return {}
    }
    if gui_state.shm == nil {
        log.error("Failed to bind Wayland shm")
        return {}
    }
    if gui_state.layer_shell == nil {
        log.error("Failed to bind Wayland wlr_layer_shell")
        return {}
    }

    // Init surface resources and commit
    gui_init_surface(&gui_state)
    if gui_state.surface == nil {
        log.error("Failed to init Wayland surface")
        return {}
    }
    if gui_state.layer_surface == nil {
        log.error("Failed to init Wayland wlr_layer_surface")
        return {}
    }

    // Roundtrip to receive configure event for layer_surface_listener
    wl.display_roundtrip(gui_state.display)

    return gui_state
}

gui_cleanup :: proc(gui_state: ^Gui_State) {
    // Cleanup connection state
    if gui_state.layer_surface != nil {wlr_ls.layer_surface_v1_destroy(gui_state.layer_surface)}
    if gui_state.surface != nil {wl.surface_destroy(gui_state.surface)}
    if gui_state.layer_shell != nil {wlr_ls.layer_shell_v1_destroy(gui_state.layer_shell)}
    if gui_state.shm != nil {wl.shm_destroy(gui_state.shm)}
    if gui_state.compositor != nil {wl.compositor_destroy(gui_state.compositor)}
    if gui_state.seat != nil {wl.seat_release(gui_state.seat)}
    wl.registry_destroy(gui_state.registry)
    wl.display_disconnect(gui_state.display)

}

registry_listener := wl.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            gui_state.seat = cast(^wl.seat)wl.registry_bind(registry, name_, &wl.seat_interface, 1)
            gui_state.seat_name = name_
        case "wl_compositor":
            gui_state.compositor = cast(^wl.compositor)wl.registry_bind(registry, name_, &wl.compositor_interface, 1)
            gui_state.compositor_name = name_
        case "wl_shm":
            gui_state.shm = cast(^wl.shm)wl.registry_bind(registry, name_, &wl.shm_interface, 1)
            gui_state.shm_name = name_
        case "zwlr_layer_shell_v1":
            gui_state.layer_shell = cast(^wlr_ls.layer_shell_v1)wl.registry_bind(
                registry,
                name_,
                &wlr_ls.layer_shell_v1_interface,
                1,
            )
            gui_state.layer_shell_name = name_
        case:
            log.debugf("Uninterested in Wayland registry global callback for interface `%s`", interface_)
            return
        }
        log.debugf("Successfully bound Wayland interface `%s`", interface_)
    },
    global_remove = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data

        if name_ == gui_state.seat_name ||
           name_ == gui_state.compositor_name ||
           name_ == gui_state.shm_name ||
           name_ == gui_state.layer_shell_name {
            interface: string
            switch name_ {
            case gui_state.seat_name:
                interface = "wl_seat"
            case gui_state.compositor_name:
                interface = "wl_compositor"
            case gui_state.shm_name:
                interface = "wl_shm"
            case gui_state.layer_shell_name:
                interface = "zwlr_layer_shell_v1"
            }
            log.errorf("Critical Wayland global removed `%s`, shutting down", interface)
            // TODO: Handle exit
        }
    },
}

layer_surface_listener := wlr_ls.layer_surface_v1_listener {
    configure = proc "c" (
        data: rawptr,
        layer_surface_v1: ^wlr_ls.layer_surface_v1,
        serial_: uint,
        width_: uint,
        height_: uint,
    ) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data
        log.debug("Received configure event")

        width := width_
        height := height_
        if width == 0 || height == 0 {
            // Set width & height to default
            width = 800
            height = 600
        }
        wlr_ls.layer_surface_v1_set_size(layer_surface_v1, width, height)
        wlr_ls.layer_surface_v1_ack_configure(layer_surface_v1, serial_)
        wl.surface_commit(gui_state.surface)
    },
    closed = proc "c" (data: rawptr, layer_surface_v1: ^wlr_ls.layer_surface_v1) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data
        log.debug("Received closed event")
        gui_state.running = false
    },
}

run_gui :: proc(socket_fd: linux.Fd) {
    gui_state := gui_init()
    if gui_state.display == nil {
        fmt.eprintln("Error: failed to connect to Wayland compositor")
        os.exit(1)
    }
    defer gui_cleanup(&gui_state)

    fmt.println("GUI popup successfully connected to Wayland")
    for gui_state.running {
        wl.display_dispatch(gui_state.display)
    }
}

