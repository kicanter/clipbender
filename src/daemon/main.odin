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
        server.backend = &wl_state
    case .X11:
        log.warn("X11 is currently unsupported for clipboard monitoring, named registers are still functional")
    case .NONE:
        log.warn("Only Wayland and X11 are supported for clipboard monitoring, named registers are still functional")
    }

    if server.backend != nil {
        log.debugf("Clipboard backend initialized (fd=%d)", int(backend_fd(server.backend)))
    } else {
        log.debug("No clipboard backend active, named registers are still functional")
    }
    // Cleanup backend if using supported backend
    defer backend_cleanup(&server.backend)
    defer cleanup_registers(&server.registers)

    // Load the persisted state
    // HACK: make a config option or maybe a flag or something?
    persist_state := false
    // The two modes fail differently by design: persistence was explicitly requested, so an unresolvable durable
    // location is fatal, whereas ephemeral state is expendable and we simply stop persisting.
    if persist_state {
        path, err := persistent_state_path()
        if err != nil {
            fmt.eprintfln("Error: persistence is enabled but %s", err.?)
            os.exit(1)
        }
        server.state_path = path
    } else {
        server.state_path = ephemeral_state_path()
    }

    defer if server.state_path != nil {delete(server.state_path.?)}
    if path, ok := server.state_path.?; ok {
        regs: [lib.MAX_REGS]lib.Reg_Entry
        err, parse_err := load_registers_state(path, &regs)
        switch {
        case err != os.General_Error.None:
            // Expected on a first run, when no state file exists yet.
            log.warnf("Failed to load registers state from path %s: errno %v", path, err)
        case parse_err != nil:
            // `unmarshal_state` already freed whatever it decoded and zeroed `regs`, so there is nothing to clean up
            // here and nothing partially restored. Starting empty is the correct degradation for an unusable file.
            log.errorf("Ignoring unusable state file %s: %s", path, parse_err.?)
        case:
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
