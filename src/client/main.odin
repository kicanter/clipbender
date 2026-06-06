package main

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:time"

import "../lib"

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

run_gui :: proc(socket_fd: linux.Fd) {
    for {
        fmt.println("You ran the GUI")
        time.sleep(3 * time.Second)
    }
}

main :: proc() {
    socket_path := lib.clipbender_socket_path()

    socket_fd := uds_connect(socket_path)
    defer linux.close(socket_fd)

    args := os.args[1:]

    if len(args) == 0 {
        run_gui(socket_fd)
    } else {
        run_cli(socket_fd, args)
    }
}
