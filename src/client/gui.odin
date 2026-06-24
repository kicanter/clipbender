package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:time"

import wayland "wayland:odin-wayland"
import wlr_ls "wayland:wlr-layer-shell"

Gui_State :: struct {
    display:          ^wayland.display,
    registry:         ^wayland.registry,
    seat:             ^wayland.seat,
    seat_name:        uint,
    compositor:       ^wayland.compositor,
    compositor_name:  uint,
    shm:              ^wayland.shm,
    shm_name:         uint,
    layer_shell:      ^wlr_ls.layer_shell_v1,
    layer_shell_name: uint,
}

gui_init :: proc() -> Gui_State {
    gui_state: Gui_State

    gui_state.display = wayland.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if gui_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return {}
    }

    // Get registry
    gui_state.registry = wayland.display_get_registry(gui_state.display)
    wayland.registry_add_listener(gui_state.registry, &registry_listener, &gui_state)

    // Roundtrip to receive registry events (binds seat, compositor, shm, and layer_shell)
    wayland.display_roundtrip(gui_state.display)
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

    // Roundtrip to receive initial selection state
    wayland.display_roundtrip(gui_state.display)

    return gui_state
}

gui_cleanup :: proc(gui_state: ^Gui_State) {
    // Cleanup connection state
    if gui_state.layer_shell != nil {wlr_ls.layer_shell_v1_destroy(gui_state.layer_shell)}
    if gui_state.shm != nil {wayland.shm_destroy(gui_state.shm)}
    if gui_state.compositor != nil {wayland.compositor_destroy(gui_state.compositor)}
    if gui_state.seat != nil {wayland.seat_release(gui_state.seat)}
    wayland.registry_destroy(gui_state.registry)
    wayland.display_disconnect(gui_state.display)

}

registry_listener := wayland.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            gui_state.seat = cast(^wayland.seat)wayland.registry_bind(registry, name_, &wayland.seat_interface, 1)
            gui_state.seat_name = name_
        case "wl_compositor":
            gui_state.compositor = cast(^wayland.compositor)wayland.registry_bind(
                registry,
                name_,
                &wayland.compositor_interface,
                1,
            )
            gui_state.compositor_name = name_
        case "wl_shm":
            gui_state.shm = cast(^wayland.shm)wayland.registry_bind(registry, name_, &wayland.shm_interface, 1)
            gui_state.shm_name = name_
        case "zwlr_layer_shell_v1":
            gui_state.layer_shell = cast(^wlr_ls.layer_shell_v1)wayland.registry_bind(
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
    global_remove = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint) {
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

run_gui :: proc(socket_fd: linux.Fd) {
    gui_state := gui_init()
    if gui_state.display == nil {
        fmt.eprintln("Error: failed to connect to Wayland compositor")
        os.exit(1)
    }
    defer gui_cleanup(&gui_state)

    fmt.println("GUI popup successfully connected to Wayland")
    for {
        fmt.println("GUI is running")
        time.sleep(3 * time.Second)
    }
}

