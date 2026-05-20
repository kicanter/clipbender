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

    // Connect client fd to socket addr
    connecterr := linux.connect(socket_fd, &socket_addr)
    fmt.assertf(sockerr == nil, "Client failed to connect to socket: err %d", connecterr)

    return socket_fd
}

command_shutdown :: proc(socket_fd: linux.Fd) {
    msg := [1]u8{u8(lib.Message_Type.SHUTDOWN)}
    linux.send(socket_fd, msg[:], {})
    fmt.println("Shutdown signal sent")
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
        if len(args[1:]) != 0 {
            fmt.eprintfln("Command `shutdown` does not take any args")
            os.exit(1)
        }
        fmt.println("shutdown")
        command_shutdown(socket_fd)
    case:
        fmt.eprintfln("Unknown command `%v`", subcommand)
        os.exit(1)
    }
}

main :: proc() {
    socket_path := lib.clipbender_socket_path()

    socket_fd := uds_connect(socket_path)
    defer linux.close(socket_fd)

    // Get args minus command `clipbender`
    args := os.args[1:]

    // Run GUI if no subcommand, otherwise CLI
    if len(args) == 0 {
        run_gui(socket_fd)
    } else {
        run_cli(socket_fd, args)
    }
}

