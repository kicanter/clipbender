package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:sys/linux/uring"

import "../lib"

Event :: enum u8 {
    ACCEPT,
    RECV,
    SIGNAL,
}

data_buf: [4096]u8
sig_buf: [128]u8

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
    if connecterr != nil {
        // Connection succeeded, daemon is already running
        fmt.eprintln("Error: daemon already running")
        os.exit(1)
    }

    // Connection refused, stale socket
    os.remove(socket_path)
}

cleanup_socket :: proc(socket_path: string, socket_fd: linux.Fd) {
    linux.close(socket_fd)
    os.remove(socket_path)
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
        n_copied, err := uring.copy_cqes(&ring, cqes[:], 1)
        if (err != nil) {
            log.errorf("Error copying CQEs from completion queue: %v", err)
        }

        for i in 0 ..< n_copied {
            cqe := cqes[i]

            switch cast(Event)cqe.user_data {
            case .ACCEPT:
                // new client
                if cqe.res < 0 {
                    log.errorf("Client accept failed: %v", cqe.res)
                    continue
                }

                // Submit recv
                client_fd := cast(linux.Fd)cqe.res
                uring.recv(&ring, u64(Event.RECV), client_fd, data_buf[:], {})
                uring.accept(&ring, u64(Event.ACCEPT), socket_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
            case .RECV:
                // Receive data
                bytes_read := int(cqe.res)
                if bytes_read > 0 {
                    msg_type := cast(lib.Command_Type)data_buf[0]
                    switch msg_type {
                    case lib.Command_Type.SET:
                        fmt.printfln("Got set message: %s", string(data_buf[:bytes_read]))
                    case lib.Command_Type.GET:
                        fmt.printfln("Got get message: %s", string(data_buf[:bytes_read]))
                    case lib.Command_Type.CLEAR:
                        fmt.printfln("Got clear: %s", string(data_buf[:bytes_read]))
                    case lib.Command_Type.SHUTDOWN:
                        fmt.printfln("Shutting down: %s", string(data_buf[:bytes_read]))
                        running = false
                    }
                }
            case .SIGNAL:
                running = false
            }
        }
        uring.submit(&ring)
    }
}

main :: proc() {
    socket_path := lib.clipbender_socket_path()

    // Check for an existing stale socket first
    check_stale_socket(socket_path)

    // Run socket event loop
    uds_serve(socket_path)
}

