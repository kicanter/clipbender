package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/linux/uring"

import lib "src:libclipbender"

// Scratch buffer for receiving from socket client
data_buf: [4096]u8
// Scratch buffer for receiving signal (SIGINT/SIGTERM)
sig_buf: [128]u8
// Max data allowed to pass over IPC
MAX_DATA_SIZE :: 65536 // 64 KiB

Debounce_Event :: enum u8 {
    CLIPBOARD,
    PRIMARY,
    SAVE_STATE,
}

SELECTION_DEBOUNCE_MS :: 1000 // 1s debounce time between selection events
SAVE_STATE_DEBOUNCE_MS :: 3000 // 3s debounce time for saving state
Debounce :: struct {
    ts:         linux.Time_Spec,
    generation: u64, // id-like field, bumped on each arm so only the timer matching the current generation commits
}

// All otherwise-global daemon state, threaded explicitly through the event loop and its handlers.
Server_State :: struct {
    backend:    lib.Clipboard_Backend,
    registers:  Register_Store,
    debounces:  [Debounce_Event]Debounce,
    state_path: string,
}

// Initialize the debounce timers with their configured durations.
init_debounces :: proc(server: ^Server_State) {
    server.debounces = {
        .CLIPBOARD = Debounce{ts = linux.Time_Spec{time_nsec = SELECTION_DEBOUNCE_MS * 1_000_000}},
        .PRIMARY = Debounce{ts = linux.Time_Spec{time_nsec = SELECTION_DEBOUNCE_MS * 1_000_000}},
        .SAVE_STATE = Debounce{ts = linux.Time_Spec{time_nsec = SAVE_STATE_DEBOUNCE_MS * 1_000_000}},
    }
}

Event :: enum u8 {
    ACCEPT,
    RECV,
    SIGNAL,
    WAYLAND,
    DEBOUNCE,
}

sigaddset :: proc(set: ^linux.Sig_Set, sig: linux.Signal) {
    set[0] |= 1 << (uint(sig) - 1)
}

SFD_CLOEXEC :: 0x00080000 // value straight from kernel
signalfd :: proc(mask: ^linux.Sig_Set) -> linux.Fd {
    result := linux.syscall(linux.SYS_signalfd4, -1, mask, size_of(linux.Sig_Set), SFD_CLOEXEC)
    return cast(linux.Fd)result
}

check_stale_socket :: proc(socket_path: string) {
    if !os.exists(socket_path) {
        return
    }

    // Try connecting, if success then daemon is already running
    socket_fd, sockerr := linux.socket(.UNIX, .SEQPACKET, {.CLOEXEC}, {})
    if sockerr != .NONE {
        return
    }
    defer linux.close(socket_fd)

    socket_addr: linux.Sock_Addr_Un
    socket_addr.sun_family = .UNIX
    copy(socket_addr.sun_path[:], transmute([]u8)socket_path)

    connecterr := linux.connect(socket_fd, &socket_addr)
    if connecterr == nil {
        // Connection succeeded, daemon is already running
        fmt.eprintln("Daemon already running, connection succeeded")
        os.exit(1)
    }

    // Connection refused, stale socket
    os.remove(socket_path)
}

cleanup_socket :: proc(socket_path: string, socket_fd: linux.Fd) {
    linux.close(socket_fd)
    os.remove(socket_path)
}

// Returns `running` (false to shut down the daemon) and `dirty` (true if a register was mutated and state should be
// persisted). The caller arms the save-state debounce when `dirty`.
handle_recv :: proc(server: ^Server_State, bytes_read: int, client_fd: linux.Fd) -> (running: bool, dirty: bool) {
    running = true
    store := &server.registers
    resp_buf: [MAX_DATA_SIZE]u8
    msg_type := cast(lib.Command_Type)data_buf[0]

    switch msg_type {
    case lib.Command_Type.SET:
        // Client is not allowed to overwrite numbered registers
        log.debugf("Got set message: %v", data_buf[:bytes_read])
        dest_reg := lib.Reg_Id(data_buf[1])
        set_mode := lib.Set_Mode(data_buf[2])
        source_kind := lib.Source_Kind(data_buf[3])
        data: []u8
        mime: string

        switch (source_kind) {
        case .REGISTER:
            source_reg := lib.Reg_Id(data_buf[4])
            source := get_reg(store, source_reg)
            if source == nil {
                errmsg := fmt.tprintf("source register `%s` is empty", lib.reg_id_to_string(source_reg))
                resp_written := lib.marshal_resp_error(errmsg, resp_buf[:])
                linux.send(client_fd, resp_buf[:resp_written], {})
                return running, dirty
            }

            data, mime = slice.clone(source.data), strings.clone(source.mime_type)
            log.debug("REGISTER:")
            log.debugf("\tSource Reg: `%s`", lib.reg_id_to_string(source_reg))

            // Setting a selection from its own recency ring, so to avoid pushing out unique data just to copy the
            // existing data from source register, move that register to the front and update the timestamp.
            // Note: duplicating this entry is avoided by self-source check in wayland.odin::wayland_commit_selection()
            if dest_reg == lib.SELECTION_CLIPBOARD && lib.reg_id_is_clipboard_num(source_reg) {
                move_recency_reg_to_front(store, .CLIPBOARD, lib.reg_id_to_clipboard_index(source_reg))
            } else if dest_reg == lib.SELECTION_PRIMARY && lib.reg_id_is_primary_num(source_reg) {
                move_recency_reg_to_front(store, .PRIMARY, lib.reg_id_to_primary_index(source_reg))
            }
        case .INLINE:
            mime, data = lib.unmarshal_cmd_set_inline(data_buf[4:bytes_read])
            log.debug("INLINE:")
        }

        log.debugf("\tContent: `%s`", string(data))
        log.debugf("\tMime: `%s`", mime)
        log.debugf(
            "\tDestination Reg: %s `%s`",
            "OVERWRITE" if set_mode == .OVERWRITE else "APPEND",
            lib.reg_id_to_string(dest_reg),
        )

        // Destination register must be either named a register or SELECTION_CLIPBOARD/PRIMARY
        errmsg := ""
        if lib.reg_id_is_named(dest_reg) {
            // ownership of data and mime transferred
            set_named_reg(store, dest_reg, data, mime, set_mode)
            data, mime = {}, {}
        } else if lib.reg_id_is_selection(dest_reg) {
            // ownership of data and mime transferred
            set_selection_reg(&server.backend, dest_reg, data, mime)
            data, mime = {}, {}
        } else {
            errmsg = fmt.tprintf(
                "invalid destination register, must be named or selection register (got `%s`)",
                lib.reg_id_to_string(dest_reg),
            )
            delete(data)
            delete(mime)
        }

        resp_written: int
        if errmsg != "" {
            resp_written = lib.marshal_resp_error(errmsg, resp_buf[:])

        } else {
            dirty = true
            resp_written = lib.marshal_resp_ok(resp_buf[:])
        }

        // Send response back to client
        linux.send(client_fd, resp_buf[:resp_written], {})
    case lib.Command_Type.GET:
        log.debugf("Got get message: %v", data_buf[:bytes_read])
        filter := lib.unmarshal_cmd_get(data_buf[1:bytes_read])
        raw := transmute(u64)filter
        log.debug("Filter:")
        log.debugf("\tClipboard: %010b", raw & 0x3FF)
        log.debugf("\tNamed:     %026b", (raw >> 10) & 0x3FFFFFF)
        log.debugf("\tPrimary:   %010b", (raw >> 36) & 0x3FF)

        regs: [lib.MAX_REGS]lib.Reg_Entry
        get_registers(store, filter, &regs)

        // Send REGISTERS response back to client (marshal packs only non-empty slots)
        resp_written := lib.marshal_resp_registers(&regs, resp_buf[:])
        linux.send(client_fd, resp_buf[:resp_written], {})
    case lib.Command_Type.CLEAR:
        log.debugf("Got clear message: %v", data_buf[:bytes_read])
        reg := lib.Reg_Id(data_buf[1])

        resp_written: int
        // Register must be a named register to manually clear it
        if !lib.reg_id_is_named(reg) {
            errmsg := fmt.tprintf(
                "invalid register, can only clear named registers (got `%s`)",
                lib.reg_id_to_string(reg),
            )
            resp_written = lib.marshal_resp_error(errmsg, resp_buf[:])
        } else {
            // Clear named reg
            log.debugf("Register: `%s`", lib.reg_id_to_string(reg))
            clear_named_reg(store, reg)
            dirty = true
            resp_written = lib.marshal_resp_ok(resp_buf[:])
        }

        // Send response back to client
        linux.send(client_fd, resp_buf[:resp_written], {})
    case lib.Command_Type.SHUTDOWN:
        fmt.println("Shutting clipbenderd down")
        running = false
        // Send OK response back to client
        resp_written := lib.marshal_resp_ok(resp_buf[:])
        linux.send(client_fd, resp_buf[:resp_written], {})
    }

    return running, dirty
}

arm_debounce :: proc(server: ^Server_State, ring: ^uring.Ring, debounce_event: Debounce_Event) {
    // Bump generation so any previously-armed timers become stale. Encode it in the upper bits of user_data:
    // [byte 0: Event][byte 1: Debounce_Event][bytes 2-7: generation]
    debounce := &server.debounces[debounce_event]
    debounce.generation += 1
    timeout_data := (debounce.generation << 16) | (u64(debounce_event) << 8) | u64(Event.DEBOUNCE)

    _, ok := uring.timeout(ring, timeout_data, &debounce.ts, 0, {})
    if !ok {
        log.error("Failed to submit timeout SQE, submission queue full")
    }
}

// Serialize the current register state (recency rings + named registers, excluding live selections) to the state file.
save_state :: proc(server: ^Server_State) {
    filter := lib.CMD_GET_FILTER_NUMBERED + lib.CMD_GET_FILTER_NAMED + lib.CMD_GET_FILTER_PRIMARY_NUMBERED
    regs: [lib.MAX_REGS]lib.Reg_Entry
    get_registers(&server.registers, filter, &regs)

    written, err := save_registers_state(server.state_path, &regs)
    if err != os.General_Error.None {
        log.errorf("Failed to save register state to %s: errno %v", server.state_path, err)
    } else {
        log.debugf("Saved state, wrote %d bytes to %s", written, server.state_path)
    }
}

dispatch_cqe :: proc(
    server: ^Server_State,
    cqe: linux.IO_Uring_CQE,
    ring: ^uring.Ring,
    server_fd: linux.Fd,
) -> (
    running: bool,
) {
    running = true

    switch cast(Event)(cqe.user_data & 0xFF) {
    case .ACCEPT:
        if cqe.res < 0 {
            log.errorf("Client accept failed: %v", cqe.res)
            return running
        }
        log.debugf("Client connected (fd=%d)", cqe.res)

        client_fd := cast(linux.Fd)cqe.res
        user_data := (u64(client_fd) << 8) | u64(Event.RECV)
        uring.recv(ring, user_data, client_fd, data_buf[:], {})
        uring.accept(ring, u64(Event.ACCEPT), server_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
    case .RECV:
        client_fd := cast(linux.Fd)(cqe.user_data >> 8)
        bytes_read := int(cqe.res)
        if bytes_read > 0 {
            dirty: bool
            running, dirty = handle_recv(server, bytes_read, client_fd)
            // A mutating command (SET/CLEAR) occurred; (re)arm the debounced state save
            if dirty {
                arm_debounce(server, ring, .SAVE_STATE)
            }
            // Re-arm recv for this client so it can continue sending messages
            user_data := (u64(client_fd) << 8) | u64(Event.RECV)
            uring.recv(ring, user_data, client_fd, data_buf[:], {})
        } else {
            // Client disconnected (EOF)
            linux.close(client_fd)
        }
    case .SIGNAL:
        // Cast magic to get signal enum from signal number
        signal := cast(linux.Signal)(cast(^i32)&sig_buf[0])^
        log.debugf("Received signal %v, shutting down", signal)
        running = false
    case .WAYLAND:
        log.debug("Wayland event received")
        // `dispatch` returns false if error occurs
        if server.backend.dispatch(server.backend.state) {
            // Successful dispatch, re-arm the poll
            uring.poll_add(ring, u64(Event.WAYLAND), server.backend.fd, {.IN}, {})

            // Check if either selection needs a debounce timer (re)armed
            wl_state := cast(^Wayland_State)server.backend.state
            if wl_state.clipboard_state.staged {
                wl_state.clipboard_state.staged = false
                arm_debounce(server, ring, .CLIPBOARD)
            }
            if wl_state.primary_state.staged {
                wl_state.primary_state.staged = false
                arm_debounce(server, ring, .PRIMARY)
            }
        } else {
            log.warn(
                "Clipboard backend disabled, dropping clipboard monitoring (named registers still functional). " +
                "You'll probably want to restart `clipbenderd`.",
            )
            server.backend.cleanup(server.backend.state)
            server.backend.state = nil
        }
    case .DEBOUNCE:
        // A debounce timer fired. Only commit if it matches the current generation, otherwise a newer selection event
        // superseded it and this timer is stale (e.g. Chrome drag-select fires many events in a row).
        debounce_event := cast(Debounce_Event)((cqe.user_data >> 8) & 0xFF)
        generation := cqe.user_data >> 16
        if generation != server.debounces[debounce_event].generation {return running}
        log.debugf("%v debounce timer fired, processing event", debounce_event)
        switch debounce_event {
        case .CLIPBOARD:
            if server.backend.state != nil &&
               wayland_commit_selection(cast(^Wayland_State)server.backend.state, &server.registers, .CLIPBOARD) {
                arm_debounce(server, ring, .SAVE_STATE)
            }
        case .PRIMARY:
            if server.backend.state != nil &&
               wayland_commit_selection(cast(^Wayland_State)server.backend.state, &server.registers, .PRIMARY) {
                arm_debounce(server, ring, .SAVE_STATE)
            }
        case .SAVE_STATE:
            save_state(server)
        }
    }
    return running
}

uds_serve :: proc(server: ^Server_State, socket_path: string) {
    server_fd, sockerr := linux.socket(.UNIX, .SEQPACKET, {.CLOEXEC}, {})
    fmt.assertf(sockerr == nil, "Failed to create server socket fd: err %d", sockerr)

    socket_addr: linux.Sock_Addr_Un
    socket_addr.sun_family = .UNIX
    copy(socket_addr.sun_path[:], transmute([]u8)socket_path)

    binderr := linux.bind(server_fd, &socket_addr)
    fmt.assertf(binderr == nil, "Failed to bind server fd to socket: %v", binderr)

    listenerr := linux.listen(server_fd, 128)
    fmt.assertf(listenerr == nil, "Server failed to listen to socket: %v", listenerr)

    // Make sure to clean up socket on exit.
    // Note: doesn't cover SIGKILL, SIGSEGV, or power loss, but stale socket check on next startup cleans it up.
    defer cleanup_socket(socket_path, server_fd)

    // Block SIGINT/SIGTERM
    mask: linux.Sig_Set
    sigaddset(&mask, .SIGINT)
    sigaddset(&mask, .SIGTERM)
    linux.rt_sigprocmask(.SIG_BLOCK, &mask, nil)
    sig_fd := signalfd(&mask)

    // Set up io_uring
    ring: uring.Ring
    params := uring.DEFAULT_PARAMS
    err := uring.init(&ring, &params)
    fmt.assertf(err == nil, "uring.init: %v", err)
    defer uring.destroy(&ring)

    // Push initial operations in submission queue to jump start queue
    // - An `accept` call to watch the server's FD for client connections to the socket
    // - A `read` call to watch the special signalfd for incoming signals
    // - A `poll_add` call to watch the backend's FD (Wayland/X11) for readability/writability
    ok: bool
    _, ok = uring.accept(&ring, u64(Event.ACCEPT), server_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
    fmt.assertf(ok, "Failed to submit original accept SQE, Submission queue for io_uring is full")
    _, ok = uring.read(&ring, u64(Event.SIGNAL), sig_fd, sig_buf[:], 0)
    fmt.assertf(ok, "Failed to submit original SIGNAL read SQE, submission queue for io_uring is full")
    if server.backend.state != nil {
        _, ok = uring.poll_add(&ring, u64(Event.WAYLAND), server.backend.fd, {.IN}, {})
        fmt.assertf(ok, "Failed to submit original WAYLAND poll SQE, submission queue for io_uring is full")
    }

    // Submit the submission queue (tells the kernel to start asynchronously wait for these FDs to get written)
    _, err = uring.submit(&ring)
    if (err != .NONE) {
        log.errorf("Error: could not submit SQEs in submission queue: errno %v", err)
    }

    log.debug("Daemon ready, entering event loop")
    // Completion queue event loop
    running := true
    cqes: [16]linux.IO_Uring_CQE
    for running {
        num_cqes: u32
        num_cqes, err = uring.copy_cqes(&ring, cqes[:], 1)
        if (err != .NONE) {
            log.errorf("Error: could not copy CQEs from completion queue: errno %v", err)
        }

        for i in 0 ..< num_cqes {
            running = dispatch_cqe(server, cqes[i], &ring, server_fd)
        }

        _, err = uring.submit(&ring)
        if (err != .NONE) {
            log.errorf("Error: could not submit SQEs in submission queue: errno %v", err)
        }

        // Clear arena allocator to not balloon
        free_all(context.temp_allocator)
    }

    // Flush any unsaved register state before exiting so a pending (debounced) save isn't lost on shutdown
    save_state(server)
}
