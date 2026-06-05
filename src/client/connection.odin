package main

import "core:fmt"
import "core:os"
import "core:sys/linux"

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

// `args` includes everything after the `clipbender set` subcommand
cmd_set :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) == 2 {     // source reg is passed as an arg
        // dest_reg, source_reg, set_mode := parse_cmd_set_reg(args[0], args[1])
        // msg := [5]byte // SET with source reg is 5-byte message
        // written := lib.encode_cmd_set_reg(dest_reg, source_reg, set_mode, msg[:])
        // linux.send(socket_fd, msg[:written], {})
    } else if len(args) == 1 && !os.is_tty(os.stdin) {     // source data is inline
        // dest, set_mode, mime, data := parse_cmd_set_inline(args[0], os.stdin)
        // msg := make([]byte, 5 + len(mime) + len(data)) // SET with inline data is N-byte message, allocate to fit
        // defer delete(msg)
        // written := lib.encode_cmd_set_inline(dest, set_mode, mime, data, msg[:])
        // linux.send(socket_fd, msg[:written], {})
    } else {
        fmt.eprintln(
            "Usage:\n" +
            "\t`clipbender set <dest-reg> <source-reg>`\n" +
            "\t`clipbender set <dest-reg>` using stdin as source data",
        )
        os.exit(1)
    }
    fmt.println("Set signal sent")
}

// `args` includes everything after the `clipbender get` subcommand
cmd_get :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) < 1 {
        fmt.eprintln("Usage:\n" + "\t`clipbender get <filter...>`")
        os.exit(1)
    }

    // filter := parse_cmd_get(args)
    filter := lib.CMD_GET_FILTER_ALL // HACK: temp

    msg: [9]byte
    written := lib.encode_cmd_get(filter, msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Get signal sent")
}

// `args` includes everything after the `clipbender clear` subcommand
cmd_clear :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) != 1 {
        fmt.eprintln("Usage:\n" + "\t`clipbender clear <register-id>`")
        os.exit(1)
    }

    // reg_id := parse_cmd_clear(args[0])
    reg_id := lib.Reg_Id(0) // HACK: temp

    msg: [2]byte
    written := lib.encode_cmd_clear(reg_id, msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Clear signal sent")
}

// `args` includes everything after the `clipbender shutdown` subcommand
cmd_shutdown :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) != 0 {
        fmt.eprintln("Usage:\n" + "\t`clipbender shutdown`")
        os.exit(1)
    }

    msg: [1]byte
    written := lib.encode_cmd_shutdown(msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Shutdown signal sent")
}

run_cli :: proc(socket_fd: linux.Fd, args: []string) {
    subcommand := args[0]
    switch subcommand {
    case "set":
        cmd_set(args[1:], socket_fd)
    case "get":
        cmd_get(args[1:], socket_fd)
    case "clear":
        cmd_clear(args[1:], socket_fd)
    case "shutdown":
        cmd_shutdown(args[1:], socket_fd)
    case:
        fmt.eprintfln("Unknown command `%v`", subcommand)
        os.exit(1)
    }
}
