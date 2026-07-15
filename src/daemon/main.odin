package main

import "core:fmt"
import "core:log"
import "core:os"

import lib "src:libclipbender"

// Package-level logger for use in proc "c" callbacks that lack the context logger
_logger: log.Logger

main :: proc() {
    _logger = log.create_console_logger()
    context.logger = _logger
    defer log.destroy_console_logger(_logger)

    socket_path := lib.clipbender_socket_path()
    defer delete(socket_path)
    log.debugf("Writing socket file to path %s", socket_path)

    server: Server_State
    init_debounces(&server)

    wl_state: Wayland_State
    //x11_state: X11_State TODO: implement X11 support
    session_type := lib.get_session_type()

    switch session_type {
    case .WAYLAND:
        log.debug("Wayland session type found, initializing clipboard monitoring via `ext-data-control-v1` protocol")

        ok := wayland_init(&wl_state)
        if !ok {
            fmt.eprintln("Error: failed to connect to Wayland compositor")
            os.exit(1)
        }
        wl_fd := wayland_get_fd(&wl_state)

        server.backend = {
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

    if server.backend.state != nil {
        log.debugf("Clipboard backend initialized (fd=%d)", int(server.backend.fd))
    } else {
        log.debug("No clipboard backend active, named registers are still functional")
    }
    // Cleanup backend if using supported backend
    defer if server.backend.state != nil {server.backend.cleanup(server.backend.state)}
    defer cleanup_registers(&server.registers)

    // Load the persisted state
    // HACK: make a config option or maybe a flag or something?
    persist_state := false
    server.state_path = clipbender_state_path(persist_state)
    defer delete(server.state_path)
    {     // new block so we can release the pointers in `regs` after we load them
        regs: [lib.MAX_REGS]lib.Reg_Entry
        _, err := load_registers_state(server.state_path, &regs)
        if err != os.General_Error.None {
            log.warnf("Failed to load registers state from path %s: errno %v", server.state_path, err)
        } else {
            load_registers(&server.registers, &regs)
        }
    }

    // Check for an existing stale socket first
    check_stale_socket(socket_path)
    // Free any temp allocations made during initialization
    free_all(context.temp_allocator)
    // Run socket event loop
    uds_serve(&server, socket_path)
}
