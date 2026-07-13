package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

import lib "src:libclipbender"

RESP_BUF_SMALL :: 256 // OK/ERROR responses
RESP_BUF_LARGE :: 65536 // 64 KiB, REGISTERS responses (GET)

print_usage_and_exit :: proc() {
    fmt.eprintln(
        "Usage: clipbender [command] \n\n" +
        "Commands:\n" +
        "\t(none)                                  Launch the clipbender GUI\n" +
        "\tset <dest-reg> [source-reg]             Set the `dest-reg` with the content from `source-reg` or stdin.\n" +
        "\tget <filter...> [fmt=<json|raw>]        Retrieve the content, mime type, and timestamp of the registers matching `filter`.\n" +
        "\tclear <reg-id>                          Clear the data stored in register `reg-id`.\n" +
        "\tshutdown                                Shutdown the `clipbenderd` daemon.\n\n" +
        "Examples:\n" +
        "\tclipbender                              Open GUI popup.\n" +
        "\tclipbender shutdown                     Stop daemon.\n" +
        "\tclipbender set a clipboard              Set register `a` from system clipboard selection.\n" +
        "\tclipbender set clipboard 1              Set system clipboard selection from clipboard register `1`.\n" +
        "\tclipbender set a primary                Set register `a` from system primary selection.\n" +
        "\tclipbender set A clipboard              Append system clipboard selection to register `a`.\n" +
        "\tclipbender set primary @5               Set system primary selection from primary register `5`.\n" +
        "\t<cmd> | clipbender set a                Set register `a` from stdin pipe.\n" +
        "\tclipbender set a < <file>               Set register `a` from stdin redirection.\n" +
        "\tclipbender clear a                      Clear register `a`.\n" +
        "\tclipbender get ++all                    Print all registers.\n" +
        "\tclipbender get ++all --@selection       Print all registers except the live primary selection.\n" +
        "\tclipbender get ++named -adz             Print named registers except `a`, `d`, `z`.\n" +
        "\tclipbender get +@012 +012               Print the first three numbered registers from primary and clipboard.\n" +
        "\tclipbender get +0:5 +@0:3               Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
        "\tclipbender get ++numbered fmt=json      Print clipboard numbered registers as structured JSON.\n" +
        "\tclipbender get +a fmt=raw | wl-copy     Pipe only the contents of register `a` into wl-copy.\n" +
        "\tclipbender get +a fmt=raw > <file>      Redirect the contents of register `a` to `file`.\n",
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
            "Usage: clipbender get <filter...> [fmt=<json|raw>]\n\n" +
            "Retrieve the content, mime type, and timestamp of the registers matching `filter`. Use the `fmt=json` flag\n" +
            "to output the data as structured JSON and the `fmt=raw` flag to output just the contents of the registers\n" +
            "in newline-delimited byte arrays.\n\n" +
            "Keywords (double prefix `++`/`--`), `@` selects the primary-side variant:\n" +
            "\t++all, --all                                         All registers\n" +
            "\t++numbered, ++@numbered                              Clipboard / primary recency registers\n" +
            "\t++named                                              Named registers (a-z)\n" +
            "\t++selection, ++@selection                            Live clipboard / primary selection\n\n" +
            "Register tokens (single prefix `+`/`-`):\n" +
            "\t+adz, +038, +@038                                    Include specific registers\n" +
            "\t-adz, -038, -@038                                    Exclude specific registers\n" +
            "\t+0:5, +a:f, +@0:5                                    Include range\n" +
            "\t-0:5, -a:f, -@0:5                                    Exclude range\n\n" +
            "Examples:\n" +
            "\tclipbender get ++all                  Print all registers.\n" +
            "\tclipbender get ++all --@selection     Print all registers except the live primary selection.\n" +
            "\tclipbender get ++named -adz           Print named registers except `a`, `d`, `z`.\n" +
            "\tclipbender get +@012 +012             Print the first three numbered registers from primary and clipboard.\n" +
            "\tclipbender get +0:5 +@0:3             Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
            "\tclipbender get ++numbered fmt=json    Print clipboard recency registers as structured JSON.\n" +
            "\tclipbender get ++selection            Print the live clipboard selection.\n" +
            "\tclipbender get +a fmt=raw | wl-copy   Pipe only the contents of register `a` into wl-copy.\n" +
            "\tclipbender get +a fmt=raw > <file>    Redirect the contents of register `a` to `file`.\n",
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
parse_cmd_set_dest_reg :: proc(dest_arg: string) -> (dest: lib.Reg_Id, set_mode: lib.Set_Mode, err: Maybe(string)) {
    if len(dest_arg) == 1 {     // single character register
        ch := dest_arg[0]
        if ch >= 'a' && ch <= 'z' {     // overwrite named reg
            dest = lib.reg_id_from_named_index(ch - 'a')
            set_mode = .OVERWRITE
        } else if ch >= 'A' && ch <= 'Z' {     // append named reg
            dest = lib.reg_id_from_named_index(ch - 'A')
            set_mode = .APPEND
        } else {
            return {}, {}, fmt.tprintf("destination register must be a-z, A-Z, `clipboard`, or `primary` (got `%v`)", dest_arg)
        }
    } else if dest_arg == "clipboard" {     // clipboard selection
        dest = lib.SELECTION_CLIPBOARD
        set_mode = .OVERWRITE
    } else if dest_arg == "primary" {     // primary selection
        dest = lib.SELECTION_PRIMARY
        set_mode = .OVERWRITE
    } else {
        return {}, {}, fmt.tprintf("destination register must be a-z, A-Z, `clipboard`, or `primary` (got `%v`)", dest_arg)
    }

    return dest, set_mode, {}
}

// source register can be a lowercase named register, numbered register, `clipboard`, or `primary`
parse_cmd_set_source_reg :: proc(source_arg: string) -> (source: lib.Reg_Id, err: Maybe(string)) {
    if len(source_arg) == 1 {
        ch := source_arg[0]
        if ch >= 'a' && ch <= 'z' {     // lowercase named reg
            source = lib.reg_id_from_named_index(ch - 'a')
        } else if ch >= '0' && ch <= '9' {     // clipboard numbered reg
            source = lib.reg_id_from_clipboard_index(ch - '0')
        } else {
            return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)", source_arg)
        }
    } else if len(source_arg) == 2 && source_arg[0] == '@' {     // primary numbered reg
        ch := source_arg[1]
        if ch >= '0' && ch <= '9' {
            source = lib.reg_id_from_primary_index(ch - '0')
        } else {
            return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)", source_arg)
        }
    } else if source_arg == "clipboard" {     // clipboard selection
        source = lib.SELECTION_CLIPBOARD
    } else if source_arg == "primary" {     // primary selection
        source = lib.SELECTION_PRIMARY
    } else {
        return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `clipboard`, or `primary` (got `%v`)", source_arg)
    }

    return source, {}
}

parse_cmd_set_reg :: proc(
    dest_arg: string,
    source_arg: string,
) -> (
    dest: lib.Reg_Id,
    set_mode: lib.Set_Mode,
    source: lib.Reg_Id,
    err: Maybe(string),
) {
    dest, set_mode, err = parse_cmd_set_dest_reg(dest_arg)
    if err != nil {
        return {}, {}, {}, err
    }

    source, err = parse_cmd_set_source_reg(source_arg)
    if err != nil {
        return {}, {}, {}, err
    }

    return dest, set_mode, source, {}
}

parse_cmd_set_inline :: proc(
    dest_arg: string,
    stdin: ^os.File,
) -> (
    dest: lib.Reg_Id,
    set_mode: lib.Set_Mode,
    mime: string,
    data: []byte,
    err: Maybe(string),
) {
    dest, set_mode, err = parse_cmd_set_dest_reg(dest_arg)
    if err != nil {
        return {}, {}, {}, {}, err
    }

    // get data from stdin
    mime = "text/plain" // TODO: add resolve_mime() to introspect mime based on magic bytes
    os_err: os.Error
    data, os_err = os.read_entire_file(stdin, context.allocator)
    if os_err != nil {
        return {}, {}, {}, {}, fmt.tprintf("could not read stdin: %v", os_err)
    }
    return dest, set_mode, mime, data, {}
}

// `args` includes everything after the `clipbender set` subcommand
cmd_set :: proc(args: []string, client_fd: linux.Fd) {
    // TODO: maybe add a `mime=` flag similar to GET's `fmt=`
    success_msg: string
    if len(args) == 2 {     // source reg was passed as an arg by client
        dest_reg, set_mode, source_reg, err := parse_cmd_set_reg(args[0], args[1])
        if err != nil {
            fmt.eprintfln("Error: %v", err.?)
            print_cmd_usage_and_exit(.SET)
        }
        msg: [5]byte // SET with source reg is 5-byte message
        written := lib.marshal_cmd_set_reg(dest_reg, source_reg, set_mode, msg[:])
        _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
        if send_err != nil {
            fmt.eprintfln("Error: failed sending SET (reg) to daemon: errno %v", send_err)
            os.exit(1)
        }
        success_msg = fmt.tprintf(
            "%s dest reg `%s` with source reg `%s`",
            "overwrote" if set_mode == .OVERWRITE else "appended",
            lib.reg_id_to_string(dest_reg),
            lib.reg_id_to_string(source_reg),
        )
    } else if len(args) == 1 && !os.is_tty(os.stdin) {     // source data is passed inline by client
        dest_reg, set_mode, mime, data, err := parse_cmd_set_inline(args[0], os.stdin)
        if err != nil {
            fmt.eprintfln("Error: %v", err.?)
            print_cmd_usage_and_exit(.SET)
        }
        defer delete(data)
        msg := make([]byte, 5 + len(mime) + len(data)) // SET with inline data is N-byte message, allocate to fit
        defer delete(msg)
        written := lib.marshal_cmd_set_inline(dest_reg, set_mode, mime, data, msg[:])
        _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
        if send_err != nil {
            fmt.eprintfln("Error: failed sending SET (inline) to daemon: errno %v", send_err)
            os.exit(1)
        }
        success_msg = fmt.tprintf(
            "%s dest reg `%s` with inline `%s` data `%s`",
            "overwrote" if set_mode == .OVERWRITE else "appended",
            lib.reg_id_to_string(dest_reg),
            mime,
            string(data),
        )
    } else {
        print_cmd_usage_and_exit(.SET)
    }

    // Receive response from daemon
    resp_buf: [RESP_BUF_SMALL]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `set` command: errno %v", recv_err)
        os.exit(1)
    }

    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        fmt.printfln("Success: %s", success_msg)
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        fmt.eprintfln("Error: %v", err_msg)
        os.exit(1)
    case .REGISTERS:
        fmt.eprintln("Error: unexpected REGISTERS response for `set` command")
        os.exit(1)
    }
}

Get_Cmd_Format :: enum u8 {
    TABLE,
    JSON,
    RAW,
}

parse_cmd_get_reg_group :: proc(
    mask: ^lib.Cmd_Get_Filter,
    arg: string,
    offset: int,
    lo: u8,
    hi: u8,
) -> (
    err: Maybe(string),
) {
    for ch in transmute([]byte)arg {
        if ch < lo || ch > hi {
            return fmt.tprintf("invalid character in register group (got `%c`)", rune(ch))
        }
        mask^ += {int(ch - lo) + offset}
    }
    return {}
}

// Parse a register range where `arg` is everything after the prefix token `+`/`-` or primary token `@` if it exists.
parse_cmd_get_reg_range :: proc(
    mask: ^lib.Cmd_Get_Filter,
    arg: string,
    offset: int,
    lo: u8,
    hi: u8,
) -> (
    err: Maybe(string),
) {
    if len(arg) != 3 || arg[1] != ':' {
        return "register range must be in format `x:y`"
    }

    start, end := arg[0], arg[2]
    if start > end {start, end = end, start}
    if start < lo || end > hi {
        return "register range out of bounds"
    }

    for i in start ..= end {
        mask^ += {int(i - lo) + offset}
    }

    return {}
}

// Parse a register group token for a GET command, `arg` is everything after the prefix `-` or `+`. Handles both
// register ranges and register groups.
parse_cmd_get_registers :: proc(mask: ^lib.Cmd_Get_Filter, arg: string) -> (err: Maybe(string)) {
    if len(arg) == 0 {
        return "a prefix token must precede a register group or register range"
    }

    is_primary := arg[0] == '@'
    body := arg[1:] if is_primary else arg

    if len(body) == 0 {
        return "expected register group or register range after `@`"
    }

    switch body[0] {
    // parse clipboard/primary numbered
    case '0' ..= '9':
        offset := int(lib.CLIPBOARD_START) if !is_primary else int(lib.PRIMARY_START)
        if strings.index_byte(body, ':') >= 0 {
            return parse_cmd_get_reg_range(mask, body, offset, '0', '9')
        }
        return parse_cmd_get_reg_group(mask, body, offset, '0', '9')
    // parse named
    case 'a' ..= 'z':
        if is_primary {
            return "primary registers are numbered not named"
        }
        offset := int(lib.NAMED_START)
        if strings.index_byte(body, ':') >= 0 {
            return parse_cmd_get_reg_range(mask, body, offset, 'a', 'z')
        }
        return parse_cmd_get_reg_group(mask, body, offset, 'a', 'z')
    case:
        return fmt.tprintf("invalid register (got `%v`)", body)
    }
}

KEYWORD_HELP :: "use one of `all`, `numbered`, `@numbered`, `named`, `selection`, `@selection`"

// Parse a keyword token for a GET command, `arg` is everything after the double prefix `--` or `++`.
// `@` prefix selects the primary-side variant (e.g. `@numbered` = primary recency, `@selection` = live primary).
parse_cmd_get_keyword :: proc(mask: ^lib.Cmd_Get_Filter, arg: string) -> (err: Maybe(string)) {
    if len(arg) == 0 {
        return fmt.tprintf("a double prefix token must precede a keyword (%s)", KEYWORD_HELP)
    }

    // immediately following double prefix token must be a keyword
    switch arg {
    case "all":
        mask^ += lib.CMD_GET_FILTER_ALL
    case "numbered":
        mask^ += lib.CMD_GET_FILTER_NUMBERED
    case "@numbered":
        mask^ += lib.CMD_GET_FILTER_PRIMARY_NUMBERED
    case "named":
        mask^ += lib.CMD_GET_FILTER_NAMED
    case "selection":
        mask^ += lib.CMD_GET_FILTER_SELECTION
    case "@selection":
        mask^ += lib.CMD_GET_FILTER_PRIMARY_SELECTION
    case:
        return fmt.tprintf("invalid keyword, %s", KEYWORD_HELP)
    }
    return {}
}

// Uses a double bitmask solution using two u64 masks (inclusion and exclusion) to guarantee order-independence. Each
// `+` and `++` token sets the proper bit in the inclusion mask. Similarly, each `-` and `--` token sets the proper bit
// in the exclusion mask.
//
// * Clipboard Numbered registers are denoted by their respective number (0-9).
// * Named registers are denoted by their respective lowercase letter (a-z).
// * Primary Numbered registers are denoted by a `@` followed by their respective number (@0-@9).
// * Keywords are indicated with a double prefix (`++` or `--`) and individual registers/groups are indicated with
// single prefixes (`+` or `-`).
// * Registers may be grouped after a single prefix based on their "kind" (Clipboard Numbered, Primary Numbered, or
// Named). A Primary Numbered group is denoted by a single `@` following the prefix token e.g. `+@015`.
// * Ranges of registers may be denoted with a `:` delimiting two ends of an inclusive range following a prefix token
// within the same "kind" (Clipboard Numbered, Primary Numbered, or Named) e.g. `+d:g`.
// * One format flags is available and is prefixed by `fmt=`: `fmt=json` and `fmt=raw` (changes output format).
parse_cmd_get :: proc(
    filter_args: []string,
) -> (
    filter: lib.Cmd_Get_Filter,
    format: Get_Cmd_Format,
    err: Maybe(string),
) {
    incl: lib.Cmd_Get_Filter
    excl: lib.Cmd_Get_Filter
    format = .TABLE

    for &arg in filter_args {
        if len(arg) == 0 {     // empty string arg should just be skipped, no-op
            continue
        }

        if len(arg) == 1 {
            return {}, {}, "incomplete token"
        }

        switch arg[0] {     // every arg must start with one of the prefix tokens
        case '+':
            if arg[1] == '+' {     // double prefix include token
                err = parse_cmd_get_keyword(&incl, arg[2:])
            } else {     // otherwise treat it as a register group
                err = parse_cmd_get_registers(&incl, arg[1:])
            }
        case '-':
            if arg[1] == '-' {     // double prefix include token
                err = parse_cmd_get_keyword(&excl, arg[2:])
            } else {     // otherwise treat it as a register group
                err = parse_cmd_get_registers(&excl, arg[1:])
            }
        case 'a' ..= 'z':
            // key=value flags (e.g. fmt=json, fmt=raw)
            eq_idx := strings.index_byte(arg, '=')
            if eq_idx < 0 {
                return {}, {}, fmt.tprintf("invalid arg, expected key=value flag (got `%v`)", arg)
            }
            key := arg[:eq_idx]
            value := arg[eq_idx + 1:]
            switch key {
            case "fmt":
                if format != .TABLE {return {}, {}, "you may only specify one format flag"}
                switch value {
                case "json":
                    format = .JSON
                case "raw":
                    format = .RAW
                case:
                    return {}, {}, fmt.tprintf("invalid format value, expected `json` or `raw` (got `%v`)", value)
                }
            case:
                return {}, {}, fmt.tprintf("unknown flag `%v`", key)
            }
        case:
            return {}, {}, fmt.tprintf("invalid arg, each arg should start with `+`, `-`, or be a key=value flag (got `%v`)", arg)
        }

        if err != nil {return {}, {}, err}
    }

    filter = incl & ~excl
    return filter, format, {}
}

// Format unix epoch timestamp as date time
format_unix_timestamp :: proc(timestamp: i64, buf: ^[19]u8) -> string {
    t := time.unix(timestamp, 0)
    y, m, d := time.date(t)
    h, min, s := time.clock(t)
    return fmt.bprintf(buf[:], "%04d-%02d-%02d %02d:%02d:%02d", y, int(m), d, h, min, s)
}

// Sanitize control characters and truncate string to fit column width, appending "..." if truncated
truncate_content :: proc(content: string, width: int) -> string {
    escaped := strings.builder_make(context.temp_allocator)
    for ch in content {
        switch ch {
        case '\n':
            strings.write_string(&escaped, `\n`)
        case '\t':
            strings.write_string(&escaped, `\t`)
        case '\r':
            strings.write_string(&escaped, `\r`)
        case:
            strings.write_rune(&escaped, ch)
        }
    }
    cleaned := strings.to_string(escaped)
    if len(cleaned) <= width {
        return cleaned
    }
    return fmt.tprintf("%s...", cleaned[:width - 3])
}

// Ordered groups of register IDs for display: clipboard recency, named, primary recency, then live selections.
// Each group is an inclusive [start, end] range so consumers can iterate directly by Reg_Id.
Reg_Group :: struct {
    start: lib.Reg_Id,
    end:   lib.Reg_Id,
}
REG_GROUPS :: [?]Reg_Group {
    {lib.CLIPBOARD_START, lib.CLIPBOARD_END},
    {lib.NAMED_START, lib.NAMED_END},
    {lib.PRIMARY_START, lib.PRIMARY_END},
    {lib.SELECTION_PRIMARY, lib.SELECTION_CLIPBOARD},
}

// Print `regs` register entries formatted as an ascii table.
cmd_get_format_table :: proc(regs: ^[lib.MAX_REGS]lib.Reg_Entry) {
    table_top := "┌──────────┬─────────────────────┬──────────────────────────┬──────────────────────────────────────────┐"
    table_sep := "├──────────┼─────────────────────┼──────────────────────────┼──────────────────────────────────────────┤"
    table_bot := "└──────────┴─────────────────────┴──────────────────────────┴──────────────────────────────────────────┘"
    fmt.println(table_top)
    fmt.println(
        "│ Register │ Timestamp           │ Mime Type                │ Content                                  │",
    )

    CONTENT_FMT :: "│ % 8s │ % -10s │ % -24s │ % -40s │"
    CONTENT_COL_WIDTH :: 40 // How much of the content to show total including truncation

    ts_buf: [19]u8
    any_printed := false
    for group in REG_GROUPS {
        group_printed := false
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            if entry.data == nil {continue}
            // Print a rule above each group that has at least one entry (also separates the header from the body)
            if !group_printed {
                fmt.println(table_sep)
            }
            fmt.printfln(
                CONTENT_FMT,
                lib.reg_id_to_string(id),
                format_unix_timestamp(entry.timestamp, &ts_buf),
                entry.mime_type,
                truncate_content(string(entry.data), CONTENT_COL_WIDTH),
            )
            any_printed = true
            group_printed = true
        }
    }

    if !any_printed {
        fmt.println(
            "├──────────┴─────────────────────┴──────────────────────────┴──────────────────────────────────────────┤",
        )
        fmt.println(
            "│                                       No registers to display                                        │",
        )
        fmt.println(
            "└──────────────────────────────────────────────────────────────────────────────────────────────────────┘",
        )
        return
    }

    fmt.println(table_bot)
}

json_escape_string :: proc(str: string) -> string {
    escaped := strings.builder_make(context.temp_allocator)
    for ch in str {
        switch ch {
        case '"':
            strings.write_string(&escaped, `\"`)
        case '\\':
            strings.write_string(&escaped, `\\`)
        case '\n':
            strings.write_string(&escaped, `\n`)
        case '\t':
            strings.write_string(&escaped, `\t`)
        case '\r':
            strings.write_string(&escaped, `\r`)
        case:
            strings.write_rune(&escaped, ch)
        }
    }
    return strings.to_string(escaped)
}

print_json_entry :: proc(entry: lib.Reg_Entry, id_str: string, printed: ^bool) {
    if printed^ {fmt.print(", ")}
    fmt.printf(
        `{{"reg": "%s", "time": "%d", "mime": "%s", "content": "%s"}}`,
        id_str,
        entry.timestamp,
        json_escape_string(entry.mime_type),
        json_escape_string(string(entry.data)),
    )
    printed^ = true
}

// Print `regs` register entries formatted as json.
cmd_get_format_json :: proc(regs: ^[lib.MAX_REGS]lib.Reg_Entry) {
    printed := false
    fmt.print("[")
    for group in REG_GROUPS {
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            if entry.data == nil {continue}
            print_json_entry(entry, lib.reg_id_to_string(id), &printed)
        }
    }
    fmt.print("]\n")
}

// Print just the raw content from `regs` register entries (newline-delimited).
cmd_get_format_raw :: proc(regs: ^[lib.MAX_REGS]lib.Reg_Entry) {
    printed := false
    for group in REG_GROUPS {
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            if entry.data == nil {continue}
            if printed {fmt.print("\n")}
            fmt.print(string(entry.data))
            printed = true
        }
    }
}

// `args` includes everything after the `clipbender get` subcommand.
cmd_get :: proc(args: []string, client_fd: linux.Fd) {
    if len(args) < 1 {
        print_cmd_usage_and_exit(.GET)
    }

    filter, format, err := parse_cmd_get(args)
    if err != nil {
        fmt.eprintfln("Error: %v", err.?)
        print_cmd_usage_and_exit(.GET)
    }

    // Send GET message
    msg: [9]byte
    written := lib.marshal_cmd_get(filter, msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        fmt.eprintfln("Error: failed sending GET to daemon: errno %v", send_err)
        os.exit(1)
    }

    // Receive response from daemon
    resp_buf: [RESP_BUF_LARGE]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `get` command: errno %v", recv_err)
        os.exit(1)
    }

    regs: [lib.MAX_REGS]lib.Reg_Entry // buffer to store the response data, indexed by Reg_Id
    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        fmt.eprintln("Error: unexpected OK response for `get` command")
        os.exit(1)
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        fmt.eprintfln("Error: %v", err_msg)
        os.exit(1)
    case .REGISTERS:
        lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &regs)
    }

    // At this point, we either have the data or have already errored and exited.
    // Handle printing + formatting the received register entries.
    switch format {
    case .TABLE:
        cmd_get_format_table(&regs)
    case .JSON:
        cmd_get_format_json(&regs)
    case .RAW:
        cmd_get_format_raw(&regs)
    }

    // Free register data
    for &entry in regs {
        lib.free_reg_entry(&entry)
    }
}

parse_cmd_clear :: proc(reg_arg: string) -> (reg: lib.Reg_Id, err: Maybe(string)) {
    if len(reg_arg) == 1 {     // single character register (named)
        ch := reg_arg[0]
        if ch < 'a' || ch > 'z' {
            return {}, fmt.tprintf("register must be a-z (got `%v`)", reg_arg)
        }
        return lib.reg_id_from_named_index(ch - 'a'), {}
    }
    return {}, fmt.tprintf("register must be a-z (got `%v`)", reg_arg)
}

// `args` includes everything after the `clipbender clear` subcommand
cmd_clear :: proc(args: []string, client_fd: linux.Fd) {
    if len(args) != 1 {
        print_cmd_usage_and_exit(.CLEAR)
    }

    reg_id, err := parse_cmd_clear(args[0])
    if err != nil {
        fmt.eprintfln("Error: %v", err.?)
        print_cmd_usage_and_exit(.CLEAR)
    }

    // Send CLEAR message
    msg: [2]byte
    written := lib.marshal_cmd_clear(reg_id, msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        fmt.eprintfln("Error: failed sending CLEAR to daemon: errno %v", send_err)
        os.exit(1)
    }

    // Receive response from daemon
    resp_buf: [RESP_BUF_SMALL]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `clear` command: errno %v", recv_err)
        os.exit(1)
    }

    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        fmt.printfln("Success: cleared register `%s`", lib.reg_id_to_string(reg_id))
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        fmt.eprintfln("Error: %v", err_msg)
        os.exit(1)
    case .REGISTERS:
        fmt.eprintln("Error: unexpected REGISTERS response for `clear` command")
        os.exit(1)
    }
}

// `args` includes everything after the `clipbender shutdown` subcommand
cmd_shutdown :: proc(args: []string, client_fd: linux.Fd) {
    if len(args) != 0 {
        print_cmd_usage_and_exit(.SHUTDOWN)
    }

    // Send SHUTDOWN message
    msg: [1]byte
    written := lib.marshal_cmd_shutdown(msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        fmt.eprintfln("Error: failed sending SHUTDOWN to daemon: errno %v", send_err)
        os.exit(1)
    }

    // Receive response from daemon
    resp_buf: [RESP_BUF_SMALL]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `shutdown` command: errno %v", recv_err)
        os.exit(1)
    }

    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        fmt.println("Success: shutdown `clipbenderd`")
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        fmt.eprintfln("Error: %v", err_msg)
        os.exit(1)
    case .REGISTERS:
        fmt.eprintln("Error: unexpected REGISTERS response for `shutdown` command")
        os.exit(1)
    }
}

run_cli :: proc(client_fd: linux.Fd, args: []string) {
    subcommand := args[0]
    switch subcommand {
    case "set":
        cmd_set(args[1:], client_fd)
    case "get":
        cmd_get(args[1:], client_fd)
    case "clear":
        cmd_clear(args[1:], client_fd)
    case "shutdown":
        cmd_shutdown(args[1:], client_fd)
    case:
        print_usage_and_exit()
    }
}

