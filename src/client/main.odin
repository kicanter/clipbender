package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:time"

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

    // Connect client fd to socket addr
    connecterr := linux.connect(socket_fd, &socket_addr)
    fmt.assertf(sockerr == nil, "Client failed to connect to socket: err %d", connecterr)

    return socket_fd
}

run_gui :: proc(socket_fd: linux.Fd) {
    for {
        fmt.println("You ran the GUI 😻")
        time.sleep(3 * time.Second)
    }
}

run_cli :: proc(socket_fd: linux.Fd, args: []string) {
    subcommand := args[0]
    switch subcommand {
    case "set":
        fmt.println("set")
    case "get":
        fmt.println("get")
    case "clear":
        fmt.println("clear")
    case "shutdown":
        fmt.println("shutdown")
    case:
        fmt.eprintfln("Unknown command `%v`", subcommand)
        os.exit(1)
    }
}

main :: proc() {
    fmt.println("Hello clipbender client 😹")

    // Get XDG_RUNTIME_DIR, fallback to /tmp
    socket_dir := os.get_env("XDG_RUNTIME_DIR", context.allocator)
    if len(socket_dir) == 0 || !os.is_directory(socket_dir) {
        socket_dir = "/tmp"
    }
    socket_path := fmt.tprintf("%s/clipbender.sock", socket_dir)

    socket_fd := uds_connect(socket_path)
    defer linux.close(socket_fd)

    // Get args minus command `clipbender`
    args := os.args[1:]

    // Run GUI if no subcommand, otherwise CLI
    if len(args) == 0 {
        run_gui(socket_fd)
    } else {
        run_cli(socket_fd)
    }
}

