package main

import "core:fmt"
import "core:log"
import "core:os"

import lib "libclipbender:base"

// Package-level logger for use in proc "c" callbacks that lack the context logger
_logger: log.Logger

main :: proc() {
    _logger = log.create_console_logger()
    context.logger = _logger
    defer log.destroy_console_logger(_logger)

    socket_path := lib.clipbender_socket_path()
    defer delete(socket_path)
    log.debugf("Writing socket file to path %s", socket_path)

    backend: lib.Clipboard_Backend
    wl_state: Wayland_State
    //x11_state: X11_State TODO: implement X11 support
    session_type := lib.get_session_type()

    switch session_type {
    case .WAYLAND:
        log.debug("Wayland session type found, initializing clipboard monitoring via `ext-data-control-v1` protocol")

        wl_state = wayland_init()
        if wl_state.display == nil {
            fmt.eprintln("Error: failed to connect to Wayland compositor")
            os.exit(1)
        }
        wl_fd := wayland_get_fd(&wl_state)

        backend = {
            fd = wl_fd,
            dispatch = proc(state: rawptr) -> bool {return wayland_dispatch(cast(^Wayland_State)state)},
            cleanup = proc(state: rawptr) {wayland_cleanup(cast(^Wayland_State)state)},
            set_selection = proc(
                state: rawptr,
                data: []u8,
                mime: string,
                type: lib.Selection_Type,
            ) {wayland_set_selection(cast(^Wayland_State)state, data, mime, type)},
            state = rawptr(&wl_state),
        }
    case .X11:
        log.warn("X11 is currently unsupported for clipboard monitoring, named registers are still functional")
    case .OTHER:
        log.warn("Only Wayland and X11 are supported for clipboard monitoring, named registers are still functional")
    }

    if backend.state != nil {
        log.debugf("Clipboard backend initialized (fd=%d)", int(backend.fd))
    } else {
        log.debug("No clipboard backend active, named registers are still functional")
    }
    // Cleanup backend if using supported backend
    defer if backend.state != nil {backend.cleanup(backend.state)}

    // Check for an existing stale socket first
    check_stale_socket(socket_path)
    // Run socket event loop
    uds_serve(socket_path, &backend)
}

