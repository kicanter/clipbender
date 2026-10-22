package main

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

import lib "src:libclipbender"

RESP_BUF_SMALL :: 256 // OK/ERROR responses

print_usage_and_exit :: proc(is_err: bool) {
    usage_str :=
        "Usage: clipbender [command]\n\n" +
        "Commands:\n" +
        "\t(none)                                  Launch the clipbender GUI\n" +
        "\tset <dest-reg> [source-reg]             Set the `dest-reg` with the content from `source-reg` or stdin.\n" +
        "\tget <filter...> [fmt=<table|json|raw>]  Retrieve the content, mime type, and timestamp of the registers matching `filter`.\n" +
        "\tclear <reg-id>                          Clear the data stored in register `reg-id`.\n" +
        "\tshutdown                                Shutdown the `clipbenderd` daemon.\n\n" +
        "Examples:\n" +
        "\tclipbender                              Open GUI popup.\n" +
        "\tclipbender shutdown                     Stop daemon.\n" +
        "\tclipbender set a .                      Set register `a` from the live clipboard selection.\n" +
        "\tclipbender set . 1                      Set the live clipboard selection from clipboard register `1`.\n" +
        "\tclipbender set a @.                     Set register `a` from the live primary selection.\n" +
        "\tclipbender set A .                      Append the live clipboard selection to register `a`.\n" +
        "\tclipbender set @. @5                    Set the live primary selection from primary register `5`.\n" +
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
        "\tclipbender get +a fmt=raw > <file>      Redirect the contents of register `a` to `file`.\n"
    if is_err {
        fmt.eprintln(usage_str)
        os.exit(1)
    } else {
        fmt.println(usage_str)
        os.exit(0)
    }
}

print_cmd_usage_and_exit :: proc(cmd_type: lib.Command_Type, is_err: bool) {
    usage: string
    switch cmd_type {
    case .SET:
        usage =
            ("Usage: clipbender set <dest-reg> [source-reg] [mime=<type/subtype>]...\n\n" +
                "Set the contents of `dest-reg` to the contents of `source-reg`. If no `source-reg` is passed, stdin is\n" +
                "used. This allows the user to pipe or stdin redirect data inline to a register.\n\n" +
                "`mime=` labels stdin explicitly and may be repeated, because one payload can legitimately carry several\n" +
                "names (an RTF document is both `application/rtf` and `text/plain`). Listed most-specific-first. When given,\n" +
                "it replaces magic-byte detection rather than adding to it, so name every mime you want the register to\n" +
                "claim. Applies to stdin only, not to a `source-reg`.\n\n" +
                "Registers:\n" +
                "\t0-9                                Numbered clipboard registers: clipboard selection recency (source-only).\n" +
                "\t@0-@9                              Numbered primary registers: primary selection recency (source-only).\n" +
                "\ta-z                                Named registers: store data (dest/source).\n" +
                "\tA-Z                                Named registers: append data to corresponding lowercase register (dest-only).\n" +
                "\t.                                  Live clipboard selection (dest/source).\n" +
                "\t@.                                 Live primary selection (dest/source).\n\n" +
                "Examples:\n" +
                "\tclipbender set a .                 Set register `a` from the live clipboard selection\n" +
                "\tclipbender set . 1                 Set the live clipboard selection from clipboard register `1`\n" +
                "\tclipbender set a @.                Set register `a` from the live primary selection\n" +
                "\tclipbender set A .                 Append the live clipboard selection to register `a`\n" +
                "\tclipbender set @. @5               Set the live primary selection from primary register `5`\n" +
                "\t<cmd> | clipbender set a           Set register `a` from stdin pipe\n" +
                "\tclipbender set a < <file>          Set register `a` from stdin redirection\n" +
                "\tclipbender set a mime=text/markdown mime=text/plain < notes.md\n" +
                "\t                                   Label stdin explicitly instead of detecting it\n")
    case .GET:
        usage =
            ("Usage: clipbender get <filter...> [fmt=<table|json|raw>]\n\n" +
                "Retrieve the content, mime type, and timestamp of the registers matching `filter`. `fmt=table` (the default)\n" +
                "prints an aligned table, `fmt=json` emits structured JSON, and `fmt=raw` emits just the register contents\n" +
                "separated by NUL bytes (recoverable with `read -d ''`, `xargs -0`; use `fmt=json` for binary contents).\n\n" +
                "Keywords (double prefix `++`/`--`), `@` selects the primary-side variant:\n" +
                "\t++all, --all                                         All registers\n" +
                "\t++numbered, ++@numbered                              Clipboard / primary recency registers\n" +
                "\t++named                                              Named registers (a-z)\n" +
                "\t++selection, ++@selection                            Live clipboard / primary selection\n\n" +
                "Exact mime (attaches to any `+`/`++` token with `=`; quote mimes containing `;`):\n" +
                "\t+a=image/png                                         Fetch that exact representation\n" +
                "\t++all=text/plain                                     ...for every register\n" +
                "\t++all=text/plain +a=image/png                        Broad default, narrow override\n" +
                "\t+a='text/plain;charset=utf-8'                        Quote it: `;` ends the command otherwise\n\n" +
                "Register tokens (single prefix `+`/`-`):\n" +
                "\t+adz, +038, +@038                                    Include specific registers\n" +
                "\t-adz, -038, -@038                                    Exclude specific registers\n" +
                "\t+0:5, +a:f, +@0:5                                    Include range\n" +
                "\t-0:5, -a:f, -@0:5                                    Exclude range\n" +
                "\t+., +@., -., -@.                                     Live clipboard / primary selection\n\n" +
                "Examples:\n" +
                "\tclipbender get ++all                                 Print all registers.\n" +
                "\tclipbender get ++all --@selection                    Print all registers except the live primary selection.\n" +
                "\tclipbender get ++named -adz                          Print named registers except `a`, `d`, `z`.\n" +
                "\tclipbender get +@012 +012                            Print the first three numbered registers from primary and clipboard.\n" +
                "\tclipbender get +0:5 +@0:3                            Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
                "\tclipbender get ++numbered fmt=json                   Print clipboard recency registers as structured JSON.\n" +
                "\tclipbender get ++selection                           Print the live clipboard selection.\n" +
                "\tclipbender get +. +@.                                Same two registers, addressed individually.\n" +
                "\tclipbender get +a fmt=raw | wl-copy                  Pipe only the contents of register `a` into wl-copy.\n" +
                "\tclipbender get +a fmt=raw > <file>                   Redirect the contents of register `a` to `file`.\n" +
                "\tclipbender get +a=image/png fmt=raw > out.png        Write register `a`'s PNG representation to a file.\n")
    case .CLEAR:
        usage =
            ("Usage: clipbender clear <reg-id>\n\n" +
                "Clear the contents of a single register.\n\n" +
                "Examples:\n" +
                "\tclipbender clear a                 Clear register `a`.\n" +
                "\tclipbender clear z                 Clear register `z`.\n")
    case .SHUTDOWN:
        usage =
            ("Usage: clipbender shutdown\n\n" +
                "Stop running the clipbenderd daemon.\n\n" +
                "Example:\n" +
                "\tclipbender shutdown                Shutdown the daemon.\n")
    }

    if is_err {
        fmt.eprintln(usage)
        os.exit(1)
    }
    fmt.println(usage)
    os.exit(0)
}

// Destination register can be a lowercase/uppercase named register, `.`, or `@.`
parse_cmd_set_dest_reg :: proc(dest_arg: string) -> (dest: lib.Reg_Id, set_mode: lib.Set_Mode, err: Maybe(string)) {
    if len(dest_arg) == 1 {
        ch := dest_arg[0]
        switch ch {
        case 'a' ..= 'z':
            // overwrite named reg
            return lib.reg_id_from_named_index(ch - 'a'), .OVERWRITE, {}
        case 'A' ..= 'Z':
            // append named reg
            return lib.reg_id_from_named_index(ch - 'A'), .APPEND, {}
        case lib.SELECTION_REG_NAME:
            // overwrite clipboard selection
            return lib.SELECTION_CLIPBOARD, .OVERWRITE, {}
        }
    } else if len(dest_arg) == 2 && dest_arg[0] == '@' {     // primary numbered reg
        ch := dest_arg[1]
        switch ch {
        case lib.SELECTION_REG_NAME:
            // overwrite primary selection
            return lib.SELECTION_PRIMARY, .OVERWRITE, {}
        }
    }
    return {}, {}, fmt.tprintf("destination register must be a-z, A-Z, `%s`, or `%s` (got `%v`)", lib.SELECTION_CLIPBOARD_REG_STR, lib.SELECTION_PRIMARY_REG_STR, dest_arg)
}

// Source register can be a lowercase named register, numbered register, `.`, or `@.`
parse_cmd_set_source_reg :: proc(source_arg: string) -> (source: lib.Reg_Id, err: Maybe(string)) {
    if len(source_arg) == 1 {
        ch := source_arg[0]
        switch ch {
        case 'a' ..= 'z':
            // lowercase named reg
            return lib.reg_id_from_named_index(ch - 'a'), {}
        case '0' ..= '9':
            // clipboard numbered reg
            return lib.reg_id_from_clipboard_index(ch - '0'), {}
        case lib.SELECTION_REG_NAME:
            // clipboard selection
            return lib.SELECTION_CLIPBOARD, {}
        }
    } else if len(source_arg) == 2 && source_arg[0] == '@' {     // primary reg
        ch := source_arg[1]
        switch ch {
        case '0' ..= '9':
            // primary numbered
            return lib.reg_id_from_primary_index(ch - '0'), {}
        case lib.SELECTION_REG_NAME:
            // primary selection
            return lib.SELECTION_PRIMARY, {}
        }
    }
    return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `%s`, or `%s` (got `%v`)", lib.SELECTION_CLIPBOARD_REG_STR, lib.SELECTION_PRIMARY_REG_STR, source_arg)
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

// `explicit_mimes` comes from `mime=` flags and takes ownership: non-empty means detection is skipped entirely and
// these are returned verbatim, so the caller frees the same list either way.
parse_cmd_set_inline :: proc(
    dest_arg: string,
    stdin: ^os.File,
    explicit_mimes: []string = nil,
) -> (
    dest: lib.Reg_Id,
    set_mode: lib.Set_Mode,
    mimes: []string,
    data: []byte,
    err: Maybe(string),
) {
    dest, set_mode, err = parse_cmd_set_dest_reg(dest_arg)
    if err != nil {
        return {}, {}, {}, {}, err
    }

    // get data from stdin
    os_err: os.Error
    data, os_err = os.read_entire_file(stdin, context.allocator)
    if os_err != nil {
        return {}, {}, {}, {}, fmt.tprintf("could not read stdin: %v", os_err)
    }

    if len(explicit_mimes) > 0 {
        return dest, set_mode, explicit_mimes, data, {}
    }

    // Derive mimes from magic bytes, so necessarily after the read. `resolve_mimes()` borrows from `.rodata`, so clone
    // before returning ownership to the caller.
    ro_mimes := lib.resolve_mimes(data)
    mimes = make([]string, len(ro_mimes))
    for mime, i in ro_mimes {mimes[i] = strings.clone(mime)}
    return dest, set_mode, mimes, data, {}
}

// `args` includes everything after the `clipbender set` subcommand
cmd_set :: proc(args: []string, client_fd: linux.Fd) {
    // Flags are partitioned out before dispatch: the form is chosen by *positional* count, so a `mime=` token would
    // otherwise make `set a mime=text/plain` look like the two-argument register form.
    explicit_mimes, mime_err := parse_set_mime_flags(args)
    if mime_err != nil {
        fmt.eprintfln("Error: %v", mime_err.?)
        print_cmd_usage_and_exit(.SET, true)
    }
    positional := make([dynamic]string, 0, len(args))
    defer delete(positional)
    for arg in args {
        if !is_set_mime_flag(arg) {append(&positional, arg)}
    }

    success_msg: string
    if len(positional) == 2 {     // source reg was passed as an arg by client
        // Relabelling a register's stored data is a different operation from labelling new input, and the source's own
        // mimes already describe it -- so silently ignoring the flag here would be worse than refusing.
        if len(explicit_mimes) > 0 {
            fmt.eprintln("Error: `mime=` applies to inline/stdin input, not to a source register")
            print_cmd_usage_and_exit(.SET, true)
        }
        dest_reg, set_mode, source_reg, err := parse_cmd_set_reg(positional[0], positional[1])
        if err != nil {
            fmt.eprintfln("Error: %v", err.?)
            print_cmd_usage_and_exit(.SET, true)
        }
        msg: [lib.CMD_SET_REG_SIZE]byte
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
    } else if len(positional) == 1 && !os.is_tty(os.stdin) {     // source data is passed inline by client
        dest_reg, set_mode, mimes, data, err := parse_cmd_set_inline(positional[0], os.stdin, explicit_mimes)
        if err != nil {
            fmt.eprintfln("Error: %v", err.?)
            print_cmd_usage_and_exit(.SET, true)
        }

        // SET with inline data is an N-byte message; size it to the content rather than guessing.
        msg := make([]byte, lib.cmd_set_inline_size(mimes, data))

        defer {
            for mime in mimes {delete(mime)}
            delete(mimes)

            // Both hold the payload -- `data` as read from stdin, `msg` as the marshalled copy.
            lib.zero_and_delete(data)
            lib.zero_and_delete(msg)
        }
        written := lib.marshal_cmd_set_inline(dest_reg, set_mode, mimes, data, msg[:])
        _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
        if send_err != nil {
            fmt.eprintfln("Error: failed sending SET (inline) to daemon: errno %v", send_err)
            os.exit(1)
        }
        success_msg = fmt.tprintf(
            "%s dest reg `%s` with %d bytes of inline `%v` data",
            "overwrote" if set_mode == .OVERWRITE else "appended",
            lib.reg_id_to_string(dest_reg),
            len(data),
            mimes,
        )
    } else {
        print_cmd_usage_and_exit(.SET, true)
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
    // parse the live selection -- a single register, so it takes no group or range
    case lib.SELECTION_REG_NAME:
        if len(body) != 1 {
            return fmt.tprintf(
                "`%c` is one register and takes no group or range (got `%v`)",
                lib.SELECTION_REG_NAME,
                body,
            )
        }
        mask^ += {int(lib.SELECTION_PRIMARY if is_primary else lib.SELECTION_CLIPBOARD)}
        return nil
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
// * An exact mime attaches to any `+`/`++` token with `=`, e.g. `+a=image/png` or `++named=text/html`.
// * Flags are `key=value`: `fmt=table|json|raw` (output shape).
parse_cmd_get :: proc(
    filter_args: []string,
) -> (
    filter: lib.Cmd_Get_Filter,
    format: Get_Cmd_Format,
    err: Maybe(string),
) {
    incl: lib.Cmd_Get_Filter
    excl: lib.Cmd_Get_Filter

    // Flag defaults
    format = .TABLE // fmt= default TODO (config): allow user to set default format
    format_set := false

    for &arg in filter_args {
        if len(arg) == 0 {     // empty string arg should just be skipped, no-op
            continue
        }

        if len(arg) == 1 {
            return {}, {}, "incomplete token"
        }

        switch arg[0] {     // every arg must start with one of the prefix tokens
        case '+':
            // Strip any `=mime` before dispatching so neither register nor keyword parsing has to know about it. The
            // mime itself is re-read by `resolve_mime_groups`; validated here so a bad one is rejected once, up front.
            token, mime, has_mime := split_mime_suffix(arg)
            if has_mime {
                if err = validate_exact_mime(mime); err != nil {return {}, {}, err}
            }
            if token[1] == '+' {     // double prefix include token
                err = parse_cmd_get_keyword(&incl, token[2:])
            } else {     // otherwise treat it as a register group
                err = parse_cmd_get_registers(&incl, token[1:])
            }
        case '-':
            token, _, has_mime := split_mime_suffix(arg)
            if has_mime {
                // Exclusion operates on register *presence*, so "exclude `a`, but as plain text" has no coherent
                // meaning. Silently dropping the mime would look like it worked.
                return {}, {}, fmt.tprintf("cannot attach a mime to an exclusion token (got `%v`)", arg)
            }
            if token[1] == '-' {     // double prefix exclude token
                err = parse_cmd_get_keyword(&excl, token[2:])
            } else {     // otherwise treat it as a register group
                err = parse_cmd_get_registers(&excl, token[1:])
            }
        case 'a' ..= 'z':
            // key=value flags. Register tokens keep their `+` prefix precisely so they stay distinguishable from this
            // namespace -- a bare `a=text/plain` is a flag named `a`, not register `a`.
            eq_idx := strings.index_byte(arg, '=')
            if eq_idx < 0 {
                return {}, {}, fmt.tprintf("invalid arg, expected key=value flag (got `%v`)", arg)
            }
            key := arg[:eq_idx]
            value := arg[eq_idx + 1:]
            switch key {
            case "fmt":
                if format_set {return {}, {}, "you may only specify one format flag"}
                switch value {
                case "table":
                    format = .TABLE
                case "json":
                    format = .JSON
                case "raw":
                    format = .RAW
                case:
                    return {}, {}, fmt.tprintf("invalid format value, expected `table`, `json`, or `raw` (got `%v`)", value)
                }
                format_set = true
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

// Split a register token from a trailing `=mime`. Splits on the first `=` because mimes can contain them (e.g.
// `text/plain;charset=utf-8`).
split_mime_suffix :: proc(arg: string) -> (token: string, mime: string, has_mime: bool) {
    eq_idx := strings.index_byte(arg, '=')
    if eq_idx < 0 {return arg, "", false}
    return arg[:eq_idx], arg[eq_idx + 1:], true
}

SET_MIME_FLAG :: "mime="

// True for a `mime=` token, which is a flag rather than a positional argument.
is_set_mime_flag :: proc(arg: string) -> bool {
    return strings.has_prefix(arg, SET_MIME_FLAG)
}

// Collect the `mime=` flags from `args`, cloned so the caller owns them exactly as it owns `resolve_mimes`' output.
//
// **Repeatable on purpose.** One payload legitimately carries several names -- an RTF document is `application/rtf`
// *and* `text/plain` -- which is why `resolve_mimes` returns a list. An override able to name only one would be less
// expressive than the detection it overrides. Order is preserved: most-specific-first is what drives resolution.
//
// **Replaces detection, never augments it.** Naming mimes asserts what the payload is, so appending `text/plain`
// behind the user's back would relabel data they deliberately described. `mime=application/rtf` alone therefore
// yields a register claiming only RTF -- which renders as its descriptor under the default TEXTUAL policy.
// Honest rather than surprising, and `mime=application/rtf mime=text/plain` is how you ask for both.
parse_set_mime_flags :: proc(args: []string) -> (mimes: []string, err: Maybe(string)) {
    collected := make([dynamic]string)
    defer if err != nil {
        for mime in collected {delete(mime)}
        delete(collected)
    }

    for arg in args {
        if !is_set_mime_flag(arg) {continue}
        mime := arg[len(SET_MIME_FLAG):]
        if mime_err := validate_exact_mime(mime); mime_err != nil {
            err = fmt.tprintf("`%s`: %s", arg, mime_err.?)
            return
        }

        // Repeats are redundant rather than contradictory -- unlike `fmt=`, accumulating is the whole point --
        // so drop them silently, matching how the Wayland layer dedupes advertised mimes on append.
        already := false
        for existing in collected {
            if existing == mime {already = true; break}
        }
        if already {continue}

        // The wire format's mime count is one byte, so refuse rather than let `marshal_cmd_set_inline` clamp silently.
        if len(collected) == lib.MAX_MIME_COUNT {
            err = fmt.tprintf("too many `mime=` flags, the maximum is %d", lib.MAX_MIME_COUNT)
            return
        }
        append(&collected, strings.clone(mime))
    }

    return collected[:], nil
}

validate_exact_mime :: proc(mime: string) -> Maybe(string) {
    if len(mime) == 0 {
        return "empty mime after `=`"
    }
    if len(mime) > lib.MAX_MIME_LEN {
        return fmt.tprintf("mime is %d bytes, the maximum is %d (got `%v`)", len(mime), lib.MAX_MIME_LEN, mime)
    }
    return nil
}

// One `+`/`++` token that carried an `=mime`, as the set of registers it covers plus that mime. Kept as a set rather
// than flattened immediately because overlap resolution has to compare the sets two tokens cover.
Mime_Token :: struct {
    set:  lib.Cmd_Get_Filter,
    mime: string,
    arg:  string, // the original token, for error messages
}

// Turn the parsed args into wire groups: one group per distinct preference, together covering exactly `presence`.
//
// Tokens may cover overlapping register sets, and the two-mask parser is order-independent, so resolution must be too --
// comparing the sets rather than relying on the order they were written:
//
//   - disjoint sets            -> no interaction
//   - same mime on both        -> never a conflict, whatever the shapes
//   - strict nesting           -> the narrower set wins those registers
//   - partial overlap          -> error, because neither set contains the other and they disagree
//
// `++all=text/plain +a=image/png` is the useful case: a broad default with a narrow override.
resolve_mime_groups :: proc(
    filter_args: []string,
    presence: lib.Cmd_Get_Filter,
    default_policy: lib.Mime_Policy,
    groups: ^[lib.MAX_REGS]lib.Cmd_Get_Group,
) -> (
    count: int,
    err: Maybe(string),
) {
    tokens: [lib.MAX_REGS]Mime_Token
    token_count := 0

    for &arg in filter_args {
        if len(arg) < 2 || arg[0] != '+' {continue}
        token, mime, has_mime := split_mime_suffix(arg)
        if !has_mime {continue}

        set: lib.Cmd_Get_Filter
        if token[1] == '+' {
            parse_cmd_get_keyword(&set, token[2:])
        } else {
            parse_cmd_get_registers(&set, token[1:])
        }
        // Excluded registers are already gone from `presence`, so they cannot be resurrected by a mime token.
        set &= presence
        if set == {} {continue}

        if token_count == lib.MAX_REGS {
            return 0, fmt.tprintf("too many mime selections, the maximum is %d", lib.MAX_REGS)
        }
        tokens[token_count] = Mime_Token {
            set  = set,
            mime = mime,
            arg  = arg,
        }
        token_count += 1
    }

    // Validate every disagreeing pair before assigning anything, so an error names the conflict rather than whichever
    // register happened to be visited first.
    for i in 0 ..< token_count {
        for j in i + 1 ..< token_count {
            a := tokens[i]
            b := tokens[j]
            if a.mime == b.mime {continue}

            inter := a.set & b.set
            if inter == {} {continue}
            // Strict nesting: the narrower set wins.
            if inter == a.set && inter != b.set {continue}
            if inter == b.set && inter != a.set {continue}

            for bit in inter {
                return 0, fmt.tprintf(
                    "overlapping mime selections disagree on register `%s` (`%s` vs `%s`)",
                    lib.reg_id_to_string(lib.Reg_Id(bit)),
                    a.arg,
                    b.arg,
                )
            }
        }
    }

    // Narrowest covering token wins each register. Ties in cardinality mean identical sets, which the pass above
    // already rejected unless the mimes match.
    assigned: [lib.MAX_REGS]string
    for bit in presence {
        best := -1
        for i in 0 ..< token_count {
            if bit not_in tokens[i].set {continue}
            if best < 0 || card(tokens[i].set) < card(tokens[best].set) {best = i}
        }
        if best >= 0 {assigned[bit] = tokens[best].mime}
    }

    // Partition by winning mime. Two tokens resolving to the same mime belong in one group.
    emitted: lib.Cmd_Get_Filter
    for bit in presence {
        if bit in emitted {continue}

        mime := assigned[bit]
        set: lib.Cmd_Get_Filter
        for other in presence {
            if other in emitted {continue}
            if assigned[other] == mime {set += {other}}
        }
        emitted += set

        policy: lib.Mime_Policy = default_policy if mime == "" else lib.Exact_Mime(mime)
        groups[count] = lib.Cmd_Get_Group {
            filter = set,
            policy = policy,
        }
        count += 1
    }

    return count, nil
}

// Extension -> mime for the targets people actually redirect into. Deliberately small: the general solution is parsing
// Note: will read `/usr/share/mime/globs2` (with `/etc/mime.types` as fallback) in the future.
OUTPUT_EXT_MIMES :: [?]struct {
    ext:  string,
    mime: string,
} {
    {".png", "image/png"},
    {".webp", "image/webp"},
    {".jpg", "image/jpeg"},
    {".jpeg", "image/jpeg"},
    {".gif", "image/gif"},
    {".tif", "image/tiff"},
    {".tiff", "image/tiff"},
    {".bmp", "image/bmp"},
    {".svg", "image/svg+xml"},
    {".html", "text/html"},
    {".htm", "text/html"},
    {".md", "text/markdown"},
    {".rtf", "text/rtf"},
    {".json", "application/json"},
    {".xml", "application/xml"},
    {".csv", "text/csv"},
    {".tsv", "text/tab-separated-values"},
    {".txt", "text/plain"},
    {".uri", "text/uri-list"},
}

// True when stdout is a terminal, i.e. output is being read by a human right now.
stdout_is_terminal :: proc() -> bool {
    return os.is_tty(os.stdout)
}

// The file stdout is redirected to, or "" when it is not a named file.
stdout_path :: proc() -> string {
    path, err := os.read_link("/proc/self/fd/1", context.temp_allocator)
    if err != nil {return ""}
    if !strings.has_prefix(path, "/") {return ""}     // `pipe:[N]`, `socket:[N]`, `anon_inode:...`
    if strings.has_prefix(path, "/dev/") {return ""}
    return path
}

// The mime implied by a path's extension, or "" if unrecognised.
mime_for_path :: proc(path: string) -> string {
    dot := strings.last_index_byte(path, '.')
    if dot < 0 {return ""}
    ext := strings.to_lower(path[dot:], context.temp_allocator)
    for entry in OUTPUT_EXT_MIMES {
        if ext == entry.ext {return entry.mime}
    }
    return ""
}

// Infer unstated output intent from where stdout goes. Only attempts to infer for a request of a single register and if
// the output is not going directly to stdout.
infer_output :: proc(
    filter: lib.Cmd_Get_Filter,
    format: Get_Cmd_Format,
    policy: lib.Mime_Policy,
    format_stated: bool,
) -> (
    Get_Cmd_Format,
    lib.Mime_Policy,
) {
    if card(filter) != 1 || stdout_is_terminal() {return format, policy}

    format := format
    policy := policy
    if !format_stated {format = .RAW}

    // Only override the preference when the output is actually raw bytes.
    if format == .RAW {
        // An unrecognised or absent extension leaves TEXTUAL; `cmd_get` retries with VISUAL when that selects
        // the extension when a register holds several image formats.
        if mime := mime_for_path(stdout_path()); mime != "" {
            policy = lib.Exact_Mime(mime)
        }
    }
    return format, policy
}

// Whether the user wrote a `key=` flag.
has_flag :: proc(args: []string, key: string) -> bool {
    for arg in args {
        if strings.has_prefix(arg, key) {return true}
    }
    return false
}

// Sanitize control characters and truncate string to fit column width, appending "..." if truncated.
// Prepare a string for a fixed-width table cell: escape anything that would move the terminal cursor, truncate to
// `width`, then pad to exactly `width`.
//
// Widths are counted in runes, not bytes.
table_cell :: proc(str: string, width: int) -> string {
    escaped := strings.builder_make(context.temp_allocator)
    runes := 0
    truncated := false
    for ch in str {
        if runes > width - 1 {
            // Only pay for the ellipsis if something actually remains.
            truncated = true
            break
        }

        switch ch {
        case '\n':
            strings.write_string(&escaped, `\n`)
            runes += 2
        case '\t':
            strings.write_string(&escaped, `\t`)
            runes += 2
        case '\r':
            strings.write_string(&escaped, `\r`)
            runes += 2
        case 0 ..< 0x20, 0x7F:
            // Every other control byte, escaped rather than printed. A form feed or an escape sequence in clipboard
            // content would otherwise move the cursor and wreck the table -- and clipboard content is untrusted text.
            fmt.sbprintf(&escaped, "\\x%02x", int(ch))
            runes += 4
        case:
            strings.write_rune(&escaped, ch)
            runes += 1
        }
    }

    cell := strings.to_string(escaped)
    if truncated {
        cell = cell[:len(cell) - 3]
        cell = fmt.tprintf("%s...", cell)
        runes += 3
    }
    if runes >= width {return cell}
    return fmt.tprintf("%s%s", cell, strings.repeat(" ", width - runes, context.temp_allocator))
}

// `REPR_MARK` indicates a repr with its own payload, `ALIAS_MARK` is another mime for the payload above it.
REPR_MARK :: '='
ALIAS_MARK :: '+'

// The content cell for one register. Non-text content is described rather than rendered: replacement characters are
// noise, and their widths would skew the column even after escaping.
display_data :: proc(entry: lib.Resp_Reg, width: int) -> string {
    if !entry.data_sent {
        // No bytes to render, either because nothing matched the preference or because the match did not fit the
        // message. Describe the repr the policy chose when there was one, else the first, rather than leaving the cell
        // blank. Uses size and meta tag to determine what data to show.
        described := entry.selected if lib.resp_reg_selected(entry) != nil else 0
        return table_cell(describe_repr(entry.reprs[described]), width)
    }
    if !utf8.valid_string(string(entry.data)) {
        return table_cell(describe_repr(entry.reprs[entry.selected]), width)
    }
    return table_cell(string(entry.data), width)
}

// Get a description string of a repr whose data blob is not available/printable e.g. `image/png 600x300 67.4 KiB`.
describe_repr :: proc(repr: lib.Resp_Repr) -> string {
    switch meta in repr.meta {
    case lib.Image_Dims:
        return fmt.tprintf("[%s %dx%d %s]", repr.mimes[0], meta.width, meta.height, lib.human_readable_size(repr.size))
    }
    return fmt.tprintf("[%s %s]", repr.mimes[0], lib.human_readable_size(repr.size))
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
cmd_get_format_table :: proc(regs: ^[lib.MAX_REGS]lib.Resp_Reg) {
    table_top := "┌────────────┬─────────────────────┬────────────────────────────┬──────────────────────────────────────────┐"
    table_sep := "├────────────┼─────────────────────┼────────────────────────────┼──────────────────────────────────────────┤"
    table_bot := "└────────────┴─────────────────────┴────────────────────────────┴──────────────────────────────────────────┘"
    fmt.println(table_top)

    // Mime and content cells are pre-padded by `table_cell`, so the format string must not pad them again.
    DATA_FMT :: "│ % 10s │ % -19s │ %s │ %s │"
    MIME_COL_WIDTH :: 26 // 24 for the longest common mime, +2 for the `= `/`+ ` mark
    DATA_COL_WIDTH :: 40

    ts_buf: [lib.TIMESTAMP_LEN]u8
    // Timestamp stored as UTC epoch seconds, translate to local wall-clock time.
    tz := lib.local_timezone()
    defer lib.free_local_timezone(tz)

    // UTC/time zone offset
    offset_buf: [lib.UTC_OFFSET_LEN]u8
    fmt.printfln(
        "│  Register  │ Timestamp %s │ Mimes                      │ Data                                     │",
        lib.format_utc_offset(tz, time.to_unix_seconds(time.now()), &offset_buf),
    )
    any_printed := false
    for group in REG_GROUPS {
        group_printed := false
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            if lib.resp_reg_is_empty(entry) {continue}
            // Print a rule above each group that has at least one entry (also separates the header from the body)
            if !group_printed {
                fmt.println(table_sep)
            }

            // The first repr is the one chosen by the preference. If none matched, just show the first repr.
            head := int(entry.selected) if lib.resp_reg_selected(entry) != nil else 0
            fmt.printfln(
                DATA_FMT,
                lib.reg_id_to_string(id),
                lib.format_unix_timestamp(entry.timestamp, &ts_buf, tz),
                table_cell(fmt.tprintf("%c %s", REPR_MARK, entry.reprs[head].mimes[0]), MIME_COL_WIDTH),
                display_data(entry, DATA_COL_WIDTH),
            )

            // Remaining mimes, stacked below. Mimes belonging to the same repr group are indented.
            for repr, r in entry.reprs {
                for mime, m in repr.mimes {
                    if r == head && m == 0 {continue}
                    mark := REPR_MARK if m == 0 else ALIAS_MARK
                    label := fmt.tprintf("%c %s", mark, mime)
                    content := "" if m > 0 || r == head else describe_repr(repr)
                    fmt.printfln(
                        DATA_FMT,
                        "",
                        "",
                        table_cell(label, MIME_COL_WIDTH),
                        table_cell(content, DATA_COL_WIDTH),
                    )
                }
            }

            any_printed = true
            group_printed = true
        }
    }

    if !any_printed {
        fmt.println(
            "├────────────┴─────────────────────┴──────────────────────────┴──────────────────────────────────────────┤",
        )
        fmt.println(
            "│                                        No registers to display                                         │",
        )
        fmt.println(
            "└────────────────────────────────────────────────────────────────────────────────────────────────────────┘",
        )
        return
    }

    fmt.println(table_bot)
}

// Render `data` as a JSON value i.e a string when it is valid UTF-8, else base64 with a sibling `encoding` field.
json_content :: proc(data: []byte) -> (value: string, is_base64: bool) {
    str := string(data)
    if utf8.valid_string(str) {
        return fmt.tprintf(`"%s"`, lib.json_escape_string(str)), false
    }
    return fmt.tprintf(`"%s"`, base64.encode(data, allocator = context.temp_allocator)), true
}

// json format:
// `register`: char = register name
// `timestamp`: i64 = time of clipbender acquisition
// `data`: string = data blob associated with printable mime, or `"null"` if no printable mime
// `reprs`: list<object> = list of data representations for that register
//     `mimes`: list<string> = list of mimes for a single data representation
//     `size`: u64 = number of bytes in that data representation (using best-fitting units)
//     `selected`: bool = whether this data representation is the one the preference chose
//     `present`: bool = whether this representation's bytes were sent; a selected repr whose payload exceeded the
//                message cap is `selected` but not `present`, which is why both are reported
//     `width`: u32 = (images only) width of the image
//     `height`: u32 = (images only) height of the image
print_json_entry :: proc(entry: lib.Resp_Reg, id_str: string, printed: ^bool) {
    if printed^ {fmt.print(", ")}

    fmt.printf(`{{"register": "%s", "timestamp": %d`, id_str, entry.timestamp)

    fmt.print(`, "data": `)
    if !entry.data_sent {
        fmt.print("null")
    } else {
        value, is_base64 := json_content(entry.data)
        fmt.print(value)
        if is_base64 {fmt.print(`, "encoding": "base64"`)}
    }

    fmt.print(`, "reprs": [`)
    for repr, r in entry.reprs {
        if r > 0 {fmt.print(", ")}
        fmt.print(`{"mimes": [`)
        for mime, m in repr.mimes {
            if m > 0 {fmt.print(", ")}
            fmt.printf(`"%s"`, lib.json_escape_string(mime))
        }
        fmt.printf(`], "size": %d, "selected": %v`, repr.size, u8(r) == entry.selected)
        switch meta in repr.meta {
        case lib.Image_Dims:
            fmt.printf(`, "width": %d, "height": %d`, meta.width, meta.height)
        }
        fmt.print("}")
    }
    fmt.print("]}")

    printed^ = true
}

// Print `regs` register entries formatted as json.
cmd_get_format_json :: proc(regs: ^[lib.MAX_REGS]lib.Resp_Reg) {
    printed := false
    fmt.print("[")
    for group in REG_GROUPS {
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            if lib.resp_reg_is_empty(entry) {continue}
            print_json_entry(entry, lib.reg_id_to_string(id), &printed)
        }
    }
    fmt.print("]\n")
}

// Print just the raw content from `regs` register entries, NUL-separated.
//
// NOTE: separator, not terminator: a single-register dump must be byte-identical to the register, or `fmt=raw > file`
// and `fmt=raw | wl-copy` would append a stray NUL to the file/clipboard.
cmd_get_format_raw :: proc(regs: ^[lib.MAX_REGS]lib.Resp_Reg) {
    printed := false
    for group in REG_GROUPS {
        for id := group.start; id <= group.end; id += 1 {
            entry := regs[id]
            // Skip entries with no bytes, not just absent ones: a register whose content did not match the preference
            // would otherwise contribute a bare separator, which a consumer reads as an empty register.
            if len(entry.data) == 0 {continue}
            if printed {fmt.print("\x00")}
            fmt.print(string(entry.data))
            printed = true
        }
    }
}

// The first register that arrived described but with no repr selected.
unmatched_reg :: proc(regs: ^[lib.MAX_REGS]lib.Resp_Reg) -> (id: lib.Reg_Id, found: bool) {
    for reg_id in 0 ..< lib.Reg_Id(lib.MAX_REGS) {
        if !lib.resp_reg_is_empty(regs[reg_id]) && lib.resp_reg_selected(regs[reg_id]) == nil {
            return reg_id, true
        }
    }
    return 0, false
}

// The mime to ask for once a ranked policy has matched nothing. Ranks the descriptors with `VISUAL`, the broadest
// policy, so the result is the repr a `VISUAL` request would have selected -- without spending a round trip to ask.
//
// Reuses `resolve_repr` rather than reimplementing the ranking, which it can because that proc reads only mime names:
// a descriptor-only `Data_Repr` with a nil blob ranks identically to the real one. Falls back to the first repr the app
// advertised, its own preference signal, for content no policy covers (archives, documents).
raw_fallback_mime :: proc(reg: lib.Resp_Reg) -> string {
    reprs := make([]lib.Data_Repr, len(reg.reprs), context.temp_allocator)
    for repr, i in reg.reprs {
        reprs[i] = lib.Data_Repr {
            mimes = repr.mimes,
        }
    }
    entry := lib.Reg_Entry {
        reprs = reprs,
    }
    if i, ok := lib.resolve_repr(&entry, lib.Ranked_Policy.VISUAL); ok {
        return reg.reprs[i].mimes[0]
    }
    return reg.reprs[0].mimes[0]
}

// Re-request `regs` under `policy`, replacing them in-place. Leaves the previous response freed and `regs` zeroed when
// the groups cannot be rebuilt.
retry_get :: proc(
    args: []string,
    filter: lib.Cmd_Get_Filter,
    policy: lib.Mime_Policy,
    groups: ^[lib.MAX_REGS]lib.Cmd_Get_Group,
    regs: ^[lib.MAX_REGS]lib.Resp_Reg,
    client_fd: linux.Fd,
) {
    for &entry in regs {lib.free_resp_reg(&entry)}
    count, err := resolve_mime_groups(args, filter, policy, groups)
    if err == nil && count > 0 {
        regs^ = get_registers_or_exit(client_fd, groups[:count])
    }
}

// `args` includes everything after the `clipbender get` subcommand.
cmd_get :: proc(args: []string, client_fd: linux.Fd) {
    if len(args) < 1 {
        print_cmd_usage_and_exit(.GET, true)
    }

    filter, format, err := parse_cmd_get(args)
    if err != nil {
        fmt.eprintfln("Error: %v", err.?)
        print_cmd_usage_and_exit(.GET, true)
    }

    // Try to infer the output preference for a single-register request that isn't going to stdout.
    out_format, out_policy := infer_output(filter, format, lib.Ranked_Policy.TEXTUAL, has_flag(args, "fmt="))

    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    group_count, group_err := resolve_mime_groups(args, filter, out_policy, &groups)
    if group_err != nil {
        fmt.eprintfln("Error: %v", group_err.?)
        os.exit(1)
    }
    if group_count == 0 {
        // Every group must claim at least one register, so the daemon rejects an empty request.
        fmt.eprintln("Error: filter matches no registers")
        os.exit(1)
    }

    regs := get_registers_or_exit(client_fd, groups[:group_count])

    // A single register redirected to a file whose extension named nothing. Retry naming a mime the register actually
    // holds, which always resolves.
    if out_format == .RAW && card(filter) == 1 {
        if _, is_ranked := out_policy.(lib.Ranked_Policy); is_ranked {
            if id, found := unmatched_reg(&regs); found {
                retry_get(args, filter, lib.Exact_Mime(raw_fallback_mime(regs[id])), &groups, &regs, client_fd)
            }
        }
    }

    // At this point, we either have the data or have already errored and exited.
    // Handle printing + formatting the received register entries.
    switch out_format {
    case .TABLE:
        cmd_get_format_table(&regs)
    case .JSON:
        cmd_get_format_json(&regs)
    case .RAW:
        cmd_get_format_raw(&regs)
    }

    // Free register data
    for &entry in regs {
        lib.free_resp_reg(&entry)
    }
}

// One GET round trip. Exits on any failure, so callers never see a partial result.
get_registers_or_exit :: proc(client_fd: linux.Fd, groups: []lib.Cmd_Get_Group) -> [lib.MAX_REGS]lib.Resp_Reg {
    msg: [lib.MAX_MSG_SIZE]byte
    written := lib.marshal_cmd_get(groups, msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        fmt.eprintfln("Error: failed sending GET to daemon: errno %v", send_err)
        os.exit(1)
    }

    resp_buf: [lib.MAX_MSG_SIZE]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `get` command: errno %v", recv_err)
        os.exit(1)
    }

    regs: [lib.MAX_REGS]lib.Resp_Reg
    switch lib.Resp_Status(resp_buf[0]) {
    case .OK:
        fmt.eprintln("Error: unexpected OK response for `get` command")
        os.exit(1)
    case .ERROR:
        fmt.eprintfln("Error: %v", string(resp_buf[1:bytes_read]))
        os.exit(1)
    case .REGISTERS:
        _, unmarshal_err := lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &regs)
        if unmarshal_err != nil {
            fmt.eprintfln("Error: malformed response from daemon: %v", unmarshal_err.?)
            os.exit(1)
        }
    }
    return regs
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
        print_cmd_usage_and_exit(.CLEAR, true)
    }

    reg_id, err := parse_cmd_clear(args[0])
    if err != nil {
        fmt.eprintfln("Error: %v", err.?)
        print_cmd_usage_and_exit(.CLEAR, true)
    }

    // Send CLEAR message
    msg: [lib.CMD_CLEAR_SIZE]byte
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
        print_cmd_usage_and_exit(.SHUTDOWN, true)
    }

    // Send SHUTDOWN message
    msg: [lib.CMD_SHUTDOWN_SIZE]byte
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
    cmd_type: lib.Command_Type
    switch args[0] {
    case "set":
        cmd_type = .SET
    case "get":
        cmd_type = .GET
    case "clear":
        cmd_type = .CLEAR
    case "shutdown":
        cmd_type = .SHUTDOWN
    case:
        print_usage_and_exit(true)
    }

    // Check for `help` arg before dispatch.
    for arg in args[1:] {
        switch arg {
        case "-h", "--help", "help":
            print_cmd_usage_and_exit(cmd_type, false)
        }
    }

    switch cmd_type {
    case .SET:
        cmd_set(args[1:], client_fd)
    case .GET:
        cmd_get(args[1:], client_fd)
    case .CLEAR:
        cmd_clear(args[1:], client_fd)
    case .SHUTDOWN:
        cmd_shutdown(args[1:], client_fd)
    }
}
