package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:sys/linux/uring"

import "../lib"

data_buf: [4096]u8
sig_buf: [128]u8
MAX_DATA_SIZE :: 65536 // 64 KiB

Event :: enum u8 {
    ACCEPT,
    RECV,
    SIGNAL,
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
    if sockerr != nil {
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

handle_recv :: proc(bytes_read: int, client_fd: linux.Fd) -> (running: bool) {
    running = true
    msg_type := cast(lib.Command_Type)data_buf[0]
    switch msg_type {
    case lib.Command_Type.SET:
        // Client is not allowed to overwrite numbered registers
        log.debugf("Got set message: %v", data_buf[:bytes_read])
        dest_reg := lib.Reg_Id(u8(data_buf[1]))
        set_mode := lib.Set_Mode(u8(data_buf[2]))
        source_kind := lib.Source_Kind(u8(data_buf[3]))
        switch (source_kind) {
        case .REGISTER:
            source_reg := lib.Reg_Id(u8(data_buf[4]))
            source := get_reg(source_reg)
            if source == nil {
                break
            }

            // Destination register must be either named register or SELECTION_CLIPBOARD/PRIMARY
            if lib.reg_id_is_named(dest_reg) {
                set_named_reg(set_mode, dest_reg, source.data, source.mime_type)
            } else if lib.reg_id_is_selection(dest_reg) {
                set_selection_reg(dest_reg, source.data, source.mime_type)
            } else {
                // error response
            }
        case .INLINE:
            mime, data := lib.decode_cmd_set_inline(data_buf[4:bytes_read])
            if lib.reg_id_is_named(dest_reg) {
                set_named_reg(set_mode, dest_reg, data, mime)
            } else if lib.reg_id_is_selection(dest_reg) {
                set_selection_reg(dest_reg, data, mime)
            } else {
                // error response
            }
        }
    case lib.Command_Type.GET:
        log.debugf("Got get message: %v", data_buf[:bytes_read])
        filter := lib.decode_cmd_get(data_buf[1:bytes_read])
        raw := transmute(u64)filter
        log.debugf("Filter:")
        log.debugf("\tClipboard: %010b", raw & 0x3FF)
        log.debugf("\tNamed:     %026b", (raw >> 10) & 0x3FFFFFF)
        log.debugf("\tPrimary:   %010b", (raw >> 36) & 0x3FF)

        regs: [46]lib.Resp_Reg
        reg_count, ok := get_registers(filter, &regs)
        if !ok {
            // error response
        }

        resp_buf: [MAX_DATA_SIZE]u8
        resp_written := lib.encode_resp_data(regs[:reg_count], resp_buf[:])
        linux.send(client_fd, resp_buf[:resp_written], {})
    case lib.Command_Type.CLEAR:
        log.debugf("Got clear message: %v", data_buf[:bytes_read])
    case lib.Command_Type.SHUTDOWN:
        fmt.println("Shutting clipbenderd down")
        running = false
    }

    return running
}

dispatch_cqe :: proc(cqe: linux.IO_Uring_CQE, ring: ^uring.Ring, socket_fd: linux.Fd) -> (running: bool) {
    running = true

    switch cast(Event)(cqe.user_data & 0xFF) {
    case .ACCEPT:
        if cqe.res < 0 {
            log.errorf("Client accept failed: %v", cqe.res)
            return running
        }

        client_fd := cast(linux.Fd)cqe.res
        user_data := (u64(client_fd) << 8) | u64(Event.RECV)
        uring.recv(ring, user_data, client_fd, data_buf[:], {})
        uring.accept(ring, u64(Event.ACCEPT), socket_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
    case .RECV:
        client_fd := cast(linux.Fd)(cqe.user_data >> 8)
        bytes_read := int(cqe.res)
        if bytes_read > 0 {
            running = handle_recv(bytes_read, client_fd)
        }
    case .SIGNAL:
        running = false
    }
    return running
}

uds_serve :: proc(socket_path: string) {
    socket_fd, sockerr := linux.socket(.UNIX, .SEQPACKET, {.CLOEXEC}, {})
    fmt.assertf(sockerr == nil, "Failed to create server socket fd: err %d", sockerr)

    socket_addr: linux.Sock_Addr_Un
    socket_addr.sun_family = .UNIX
    copy(socket_addr.sun_path[:], transmute([]u8)socket_path)

    binderr := linux.bind(socket_fd, &socket_addr)
    fmt.assertf(binderr == nil, "Failed to bind server fd to socket: %v", binderr)

    listenerr := linux.listen(socket_fd, 128)
    fmt.assertf(listenerr == nil, "Server failed to listen to socket: %v", listenerr)

    // Make sure to clean up socket on exit.
    // Note: doesn't cover SIGKILL, SIGSEGV, or power loss, but stale socket check on next startup cleans it up.
    defer cleanup_socket(socket_path, socket_fd)

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

    // Submit initial accept to jump start queue
    _, ok := uring.accept(&ring, u64(Event.ACCEPT), socket_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
    fmt.assertf(ok, "Submission queue for io_uring is full")
    uring.read(&ring, u64(Event.SIGNAL), sig_fd, sig_buf[:], 0)
    uring.submit(&ring)

    // Completion queue event loop
    running := true
    cqes: [16]linux.IO_Uring_CQE
    for running {
        n_copied, uring_err := uring.copy_cqes(&ring, cqes[:], 1)
        if (uring_err != nil) {
            log.errorf("Error copying CQEs from completion queue: %v", uring_err)
        }

        for i in 0 ..< n_copied {
            running = dispatch_cqe(cqes[i], &ring, socket_fd)
        }
        uring.submit(&ring)
    }
}

