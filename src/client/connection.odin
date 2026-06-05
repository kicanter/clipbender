package main

import "core:fmt"
import "core:os"
import "core:strings"
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

display_usage_and_exit :: proc(cmd_type: lib.Command_Type) {
    switch cmd_type {
    case .SET:
        fmt.eprintln(
            "Usage:\n" +
            "\t`clipbender set <dest-reg> <source-reg>`\n" +
            "\t`clipbender set <dest-reg>` using stdin as source data",
        )
    case .GET:
        fmt.eprintln("Usage:\n" + "\t`clipbender get <filter...>`")
    case .CLEAR:
        fmt.eprintln("Usage:\n" + "\t`clipbender clear <register-id>`")
    case .SHUTDOWN:
        fmt.eprintln("Usage:\n" + "\t`clipbender shutdown`")
    }
    os.exit(1)
}

// destination register can be a lowercase/uppercase named register, `clipboard`, or `primary`
parse_cmd_set_dest_reg :: proc(dest_arg: string) -> (dest: lib.Reg_Id, set_mode: lib.Set_Mode, ok: bool) {
    if len(dest_arg) == 1 {     // single character register
        ch := dest_arg[0]
        if ch >= 'a' && ch <= 'z' {     // overwrite named reg
            dest = lib.reg_id_from_named_index(ch - 'a')
            set_mode = .OVERWRITE
        } else if ch >= 'A' && ch <= 'Z' {     // append named reg
            dest = lib.reg_id_from_named_index(ch - 'A')
            set_mode = .APPEND
        } else {
            fmt.eprintfln(
                "Error: destination register must be a-z, A-Z, `clipboard`, or `primary` (got `%v`)",
                dest_arg,
            )
            return {}, {}, false
        }
    } else if dest_arg == "clipboard" {     // clipboard selection
        dest = lib.SELECTION_CLIPBOARD
        set_mode = .OVERWRITE
    } else if dest_arg == "primary" {     // primary selection
        dest = lib.SELECTION_PRIMARY
        set_mode = .OVERWRITE
    } else {
        fmt.eprintfln("Error: destination register must be a-z, A-Z, `clipboard`, or `primary` (got `%v`)", dest_arg)
        return {}, {}, false
    }

    return dest, set_mode, true
}

// source register can be a lowercase named register, numbered register, `clipboard`, or `primary`
parse_cmd_set_source_reg :: proc(source_arg: string) -> (source: lib.Reg_Id, ok: bool) {
    if len(source_arg) == 1 {
        ch := source_arg[0]
        if ch >= 'a' && ch <= 'z' {     // lowercase named reg
            source = lib.reg_id_from_named_index(ch - 'a')
        } else if ch >= '0' && ch <= '9' {     // clipboard numbered reg
            source = lib.reg_id_from_clipboard_index(ch - '0')
        } else {
            fmt.eprintfln(
                "Error: source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)",
                source_arg,
            )
            return {}, false
        }
    } else if len(source_arg) == 2 && source_arg[0] == '@' {     // primary numbered reg
        ch := source_arg[1]
        if ch >= '0' && ch <= '9' {
            source = lib.reg_id_from_primary_index(ch - '0')
        } else {
            fmt.eprintfln(
                "Error: source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)",
                source_arg,
            )
            return {}, false
        }
    } else if source_arg == "clipboard" {     // clipboard selection
        source = lib.SELECTION_CLIPBOARD
    } else if source_arg == "primary" {     // primary selection
        source = lib.SELECTION_PRIMARY
    } else {
        fmt.eprintfln(
            "Error: source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)",
            source_arg,
        )
        return {}, false
    }

    return source, true
}

parse_cmd_set_reg :: proc(
    dest_arg: string,
    source_arg: string,
) -> (
    dest: lib.Reg_Id,
    set_mode: lib.Set_Mode,
    source: lib.Reg_Id,
    ok: bool,
) {
    dest, set_mode, ok = parse_cmd_set_dest_reg(dest_arg)
    if !ok {
        return {}, {}, {}, false
    }

    source, ok = parse_cmd_set_source_reg(source_arg)
    if !ok {
        return {}, {}, {}, false
    }

    return dest, set_mode, source, true
}

parse_cmd_set_inline :: proc(
    dest_arg: string,
    stdin: ^os.File,
) -> (
    dest: lib.Reg_Id,
    set_mode: lib.Set_Mode,
    mime: string,
    data: []byte,
    ok: bool,
) {
    dest, set_mode, ok = parse_cmd_set_dest_reg(dest_arg)
    if !ok {
        return {}, {}, {}, {}, false
    }

    // get data from stdin
    mime = "text/plain" // TODO: add resolve_mime() to introspect mime based on magic bytes
    err: os.Error
    data, err = os.read_entire_file(stdin, context.allocator)
    if err != nil {
        fmt.eprintfln("Error reading stdin: %v", err)
        return {}, {}, {}, {}, false
    }
    return dest, set_mode, mime, data, true
}

// `args` includes everything after the `clipbender set` subcommand
cmd_set :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) == 2 {     // source reg was passed as an arg by client
        dest_reg, set_mode, source_reg, ok := parse_cmd_set_reg(args[0], args[1])
        if !ok {
            display_usage_and_exit(.SET)
        }
        msg: [5]byte // SET with source reg is 5-byte message
        written := lib.encode_cmd_set_reg(dest_reg, source_reg, set_mode, msg[:])
        linux.send(socket_fd, msg[:written], {})
    } else if len(args) == 1 && !os.is_tty(os.stdin) {     // source data is passed inline by client
        dest, set_mode, mime, data, ok := parse_cmd_set_inline(args[0], os.stdin)
        if !ok {
            display_usage_and_exit(.SET)
        }
        msg := make([]byte, 5 + len(mime) + len(data)) // SET with inline data is N-byte message, allocate to fit
        defer delete(msg)
        written := lib.encode_cmd_set_inline(dest, set_mode, mime, data, msg[:])
        linux.send(socket_fd, msg[:written], {})
    } else {
        display_usage_and_exit(.SET)
    }
    fmt.println("Set signal sent")
}

parse_cmd_get :: proc(filter_args: []string) -> (filter: lib.Cmd_Get_Filter, ok: bool) {
    return {}, {}
}

// `args` includes everything after the `clipbender get` subcommand
cmd_get :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) < 1 {
        display_usage_and_exit(.GET)
    }

    filter, ok := parse_cmd_get(args)
    if !ok {
        display_usage_and_exit(.GET)
    }

    msg: [9]byte
    written := lib.encode_cmd_get(filter, msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Get signal sent")
}

parse_cmd_clear :: proc(reg_arg: string) -> (reg: lib.Reg_Id, ok: bool) {
    if len(reg_arg) == 1 {     // single character register (named)
        ch := reg_arg[0]
        if ch < 'a' || ch > 'z' {     // not a named register
            fmt.eprintfln("Error: must use a named register (got `%v`)", ch)
            return {}, false
        }
        return lib.reg_id_from_named_index(ch - 'a'), true
    }
    fmt.eprintfln("Error: must use a named register (got `%v`)", reg_arg)
    return {}, false
}

// `args` includes everything after the `clipbender clear` subcommand
cmd_clear :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) != 1 {
        display_usage_and_exit(.CLEAR)
    }

    reg_id, ok := parse_cmd_clear(args[0])
    if !ok {
        display_usage_and_exit(.CLEAR)
    }

    msg: [2]byte
    written := lib.encode_cmd_clear(reg_id, msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Clear signal sent")
}

// `args` includes everything after the `clipbender shutdown` subcommand
cmd_shutdown :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) != 0 {
        display_usage_and_exit(.SHUTDOWN)
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

