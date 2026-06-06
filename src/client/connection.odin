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

print_usage_and_exit :: proc() {
    fmt.eprintln(
        "Usage: clipbender [command] \n\n" +
        "Commands:\n" +
        "\t(none)                             Launch the clipbender GUI\n" +
        "\tset <dest-reg> [source-reg]        Set the `dest-reg` with the content from `source-reg` or stdin.\n" +
        "\tget <filter...> [=json|=raw]       Retrieve the content, mime type, and timestamp of the registers matching `filter`.\n" +
        "\tclear <reg-id>                     Clear the data stored in register `reg-id`.\n" +
        "\tshutdown                           Shutdown the `clipbenderd` daemon.\n\n" +
        "Examples:\n" +
        "\tclipbender                         Open GUI popup.\n" +
        "\tclipbender shutdown                Stop daemon.\n" +
        "\tclipbender set a clipboard         Set register `a` from system clipboard selection.\n" +
        "\tclipbender set clipboard 1         Set system clipboard selection from clipboard register `1`.\n" +
        "\tclipbender set a primary           Set register `a` from system primary selection.\n" +
        "\tclipbender set A clipboard         Append system clipboard selection to register `a`.\n" +
        "\tclipbender set primary @5          Set system primary selection from primary register `5`.\n" +
        "\t<cmd> | clipbender set a           Set register `a` from stdin pipe.\n" +
        "\tclipbender set a < <file>          Set register `a` from stdin redirection.\n" +
        "\tclipbender clear a                 Clear register `a`.\n" +
        "\tclipbender get ++all               Print all registers.\n" +
        "\tclipbender get ++named -adz        Print named registers except `a`, `d`, `z`.\n" +
        "\tclipbender get +@012 +012          Print the first three numbered registers from primary and clipboard.\n" +
        "\tclipbender get +0:5 +@0:3          Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
        "\tclipbender get ++clipboard =json   Print clipboard registers as structured JSON.\n" +
        "\tclipbender get +a =raw | wl-copy   Pipe only the contents of register `a` and pipe into wl-copy.\n" +
        "\tclipbender get +a =raw > <file>    Redirect the contents of register `a` to `file`.\n",
    )
    os.exit(1)
}

print_cmd_usage_and_exit :: proc(cmd_type: lib.Command_Type) {
    switch cmd_type {
    case .SET:
        fmt.eprintln(
            "Usage: clipbender set <dest-reg> [source-reg]\n\n" +
            "Set the contents of `dest-reg` to the contents of `source-reg`. If no `source-reg` is passed, stdin is\n" +
            "used. This allows the user to pipe or stdin redirect data inline to a register.\n\n" +
            "Registers:\n" +
            "\t0-9                                Numbered clipboard registers: clipboard selection recency (source-only).\n" +
            "\t@0-@9                              Numbered primary registers: primary selection recency (source-only).\n" +
            "\ta-z                                Named registers: store data (dest/source).\n" +
            "\tA-Z                                Named registers: append data to corresponding lowercase register (dest-only).\n" +
            "\tclipboard                          System clipboard selection (dest/source).\n" +
            "\tprimary                            System primary selection (dest/source).\n\n" +
            "Examples:\n" +
            "\tclipbender set a clipboard         Set register `a` from system clipboard selection\n" +
            "\tclipbender set clipboard 1         Set system clipboard selection from clipboard register `1`\n" +
            "\tclipbender set a primary           Set register `a` from system primary selection\n" +
            "\tclipbender set A clipboard         Append system clipboard selection to register `a`\n" +
            "\tclipbender set primary @5          Set system primary selection from primary register `5`\n" +
            "\t<cmd> | clipbender set a           Set register `a` from stdin pipe\n" +
            "\tclipbender set a < <file>          Set register `a` from stdin redirection\n",
        )
    case .GET:
        fmt.eprintln(
            "Usage: clipbender get <filter...> [=json|=raw]\n\n" +
            "Retrieve the content, mime type, and timestamp of the registers matching `filter`. Use the `=json` flag\n" +
            "to output the data as structured JSON and the `=raw` flag to output just the contents of the registers\n" +
            "in newline-delimited byte arrays.\n\n" +
            "Filter tokens:\n" +
            "\t++all, ++clipboard, ++named, ++primary, ++numbered   Include category\n" +
            "\t--all, --clipboard, --named, --primary, --numbered   Exclude category\n" +
            "\t+adz, +038, +@038                                    Include specific registers\n" +
            "\t-adz, -038, -@038                                    Exclude specific registers\n" +
            "\t+0:5, +a:f, +@0:5                                    Include range\n" +
            "\t-0:5, -a:f, -@0:5                                    Exclude range\n\n" +
            "Examples:\n" +
            "\tclipbender get ++all               Print all registers.\n" +
            "\tclipbender get ++named -adz        Print named registers except `a`, `d`, `z`.\n" +
            "\tclipbender get +@012 +012          Print the first three numbered registers from primary and clipboard.\n" +
            "\tclipbender get +0:5 +@0:3          Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
            "\tclipbender get ++clipboard =json   Print clipboard registers as structured JSON.\n" +
            "\tclipbender get +a =raw | wl-copy   Pipe only the contents of register `a` and pipe into wl-copy.\n" +
            "\tclipbender get +a =raw > <file>    Redirect the contents of register `a` to `file`.\n",
        )
    case .CLEAR:
        fmt.eprintln(
            "Usage: clipbender clear <reg-id>\n\n" +
            "Clear the contents of a single register.\n\n" +
            "Examples:\n" +
            "\tclipbender clear a                 Clear register `a`.\n" +
            "\tclipbender clear z                 Clear register `z`.\n",
        )
    case .SHUTDOWN:
        fmt.eprintln(
            "Usage: clipbender shutdown\n\n" +
            "Stop running the clipbenderd daemon.\n\n" +
            "Example:\n" +
            "\tclipbender shutdown                Shutdown the daemon.\n",
        )
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
            print_cmd_usage_and_exit(.SET)
        }
        msg: [5]byte // SET with source reg is 5-byte message
        written := lib.encode_cmd_set_reg(dest_reg, source_reg, set_mode, msg[:])
        linux.send(socket_fd, msg[:written], {})
    } else if len(args) == 1 && !os.is_tty(os.stdin) {     // source data is passed inline by client
        dest, set_mode, mime, data, ok := parse_cmd_set_inline(args[0], os.stdin)
        if !ok {
            print_cmd_usage_and_exit(.SET)
        }
        msg := make([]byte, 5 + len(mime) + len(data)) // SET with inline data is N-byte message, allocate to fit
        defer delete(msg)
        written := lib.encode_cmd_set_inline(dest, set_mode, mime, data, msg[:])
        linux.send(socket_fd, msg[:written], {})
    } else {
        print_cmd_usage_and_exit(.SET)
    }
    fmt.println("Set signal sent")
}

parse_cmd_get :: proc(filter_args: []string) -> (filter: lib.Cmd_Get_Filter, ok: bool) {
    return {}, {}
}

// `args` includes everything after the `clipbender get` subcommand
cmd_get :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) < 1 {
        print_cmd_usage_and_exit(.GET)
    }

    filter, ok := parse_cmd_get(args)
    if !ok {
        print_cmd_usage_and_exit(.GET)
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
        print_cmd_usage_and_exit(.CLEAR)
    }

    reg_id, ok := parse_cmd_clear(args[0])
    if !ok {
        print_cmd_usage_and_exit(.CLEAR)
    }

    msg: [2]byte
    written := lib.encode_cmd_clear(reg_id, msg[:])
    linux.send(socket_fd, msg[:written], {})
    fmt.println("Clear signal sent")
}

// `args` includes everything after the `clipbender shutdown` subcommand
cmd_shutdown :: proc(args: []string, socket_fd: linux.Fd) {
    if len(args) != 0 {
        print_cmd_usage_and_exit(.SHUTDOWN)
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
        print_usage_and_exit()
    }
}

