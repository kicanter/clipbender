package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"

import lib "libclipbender:base"

// Package-level logger for use in proc "c" callbacks that lack the context logger
_logger: log.Logger

uds_connect :: proc(socket_path: string) -> linux.Fd {
    if !os.exists(socket_path) {
        fmt.eprintln("Error: socket path does not exist")
        os.exit(1)
    }

    socket_fd, sockerr := linux.socket(.UNIX, .SEQPACKET, {.CLOEXEC}, {})
    fmt.assertf(sockerr == nil, "Failed to create client socket fd: err %d", sockerr)

    socket_addr: linux.Sock_Addr_Un
    socket_addr.sun_family = .UNIX
    copy(socket_addr.sun_path[:], transmute([]u8)socket_path)

    connecterr := linux.connect(socket_fd, &socket_addr)
    fmt.assertf(connecterr == nil, "Client failed to connect to socket: err %d", connecterr)

    return socket_fd
}

main :: proc() {
    _logger = log.create_console_logger()
    context.logger = _logger
    defer log.destroy_console_logger(_logger)

    socket_path := lib.clipbender_socket_path()
    defer delete(socket_path)

    client_fd := uds_connect(socket_path)
    defer linux.close(client_fd)

    args := os.args[1:]

    if len(args) == 0 {
        run_gui(client_fd)
    } else {
        run_cli(client_fd, args)
    }
}
