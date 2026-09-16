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

print_usage_and_exit :: proc() {
    fmt.eprintln(
        "Usage: clipbender [command] \n\n" +
        "Commands:\n" +
        "\t(none)                                  Launch the clipbender GUI\n" +
        "\tset <dest-reg> [source-reg]             Set the `dest-reg` with the content from `source-reg` or stdin.\n" +
        "\tget <filter...> [fmt=<table|json|raw>]  Retrieve the content, mime type, and timestamp of the registers matching `filter`.\n" +
        "\tclear <reg-id>                          Clear the data stored in register `reg-id`.\n" +
        "\tshutdown                                Shutdown the `clipbenderd` daemon.\n\n" +
        "Examples:\n" +
        "\tclipbender                              Open GUI popup.\n" +
        "\tclipbender shutdown                     Stop daemon.\n" +
        "\tclipbender set a selection              Set register `a` from the live clipboard selection.\n" +
        "\tclipbender set selection 1              Set the live clipboard selection from clipboard register `1`.\n" +
        "\tclipbender set a @selection             Set register `a` from the live primary selection.\n" +
        "\tclipbender set A selection              Append the live clipboard selection to register `a`.\n" +
        "\tclipbender set @selection @5            Set the live primary selection from primary register `5`.\n" +
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
            "\tselection                          Live clipboard selection (dest/source).\n" +
            "\t@selection                         Live primary selection (dest/source).\n\n" +
            "Examples:\n" +
            "\tclipbender set a selection         Set register `a` from the live clipboard selection\n" +
            "\tclipbender set selection 1         Set the live clipboard selection from clipboard register `1`\n" +
            "\tclipbender set a @selection        Set register `a` from the live primary selection\n" +
            "\tclipbender set A selection         Append the live clipboard selection to register `a`\n" +
            "\tclipbender set @selection @5       Set the live primary selection from primary register `5`\n" +
            "\t<cmd> | clipbender set a           Set register `a` from stdin pipe\n" +
            "\tclipbender set a < <file>          Set register `a` from stdin redirection\n",
        )
    case .GET:
        fmt.eprintln(
            "Usage: clipbender get <filter...> [fmt=<table|json|raw>] [pref=<printable|richest>]\n\n" +
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
            "\t'+a=text/plain;charset=utf-8'                        Quote it: `;` ends the command otherwise\n\n" +
            "Register tokens (single prefix `+`/`-`):\n" +
            "\t+adz, +038, +@038                                    Include specific registers\n" +
            "\t-adz, -038, -@038                                    Exclude specific registers\n" +
            "\t+0:5, +a:f, +@0:5                                    Include range\n" +
            "\t-0:5, -a:f, -@0:5                                    Exclude range\n\n" +
            "Examples:\n" +
            "\tclipbender get ++all                                 Print all registers.\n" +
            "\tclipbender get ++all --@selection                    Print all registers except the live primary selection.\n" +
            "\tclipbender get ++named -adz                          Print named registers except `a`, `d`, `z`.\n" +
            "\tclipbender get +@012 +012                            Print the first three numbered registers from primary and clipboard.\n" +
            "\tclipbender get +0:5 +@0:3                            Print clipboard registers in range 0-5 and primary registers in range 0-3.\n" +
            "\tclipbender get ++numbered fmt=json                   Print clipboard recency registers as structured JSON.\n" +
            "\tclipbender get ++selection                           Print the live clipboard selection.\n" +
            "\tclipbender get +a fmt=raw | wl-copy                  Pipe only the contents of register `a` into wl-copy.\n" +
            "\tclipbender get +a fmt=raw > <file>                   Redirect the contents of register `a` to `file`.\n" +
            "\tclipbender get ++all pref=richest                    Prefer the highest-fidelity representation of each register.\n" +
            "\tclipbender get +a=image/png fmt=raw > out.png        Write register `a`'s PNG representation to a file.\n",
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

// Live selections are named `selection`/`@selection` rather than `clipboard`/`primary` so the `@`-marks-primary
// convention holds everywhere: `5`/`@5` for recency, `selection`/`@selection` for the live selections, matching the
// `++selection`/`++@selection` keywords GET uses.
SELECTION_ARG :: "selection"
PRIMARY_SELECTION_ARG :: "@selection"

// destination register can be a lowercase/uppercase named register, `selection`, or `@selection`
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
            return {}, {}, fmt.tprintf("destination register must be a-z, A-Z, `selection`, or `@selection` (got `%v`)", dest_arg)
        }
    } else if dest_arg == SELECTION_ARG {     // live clipboard selection
        dest = lib.SELECTION_CLIPBOARD
        set_mode = .OVERWRITE
    } else if dest_arg == PRIMARY_SELECTION_ARG {     // live primary selection
        dest = lib.SELECTION_PRIMARY
        set_mode = .OVERWRITE
    } else {
        return {}, {}, fmt.tprintf("destination register must be a-z, A-Z, `selection`, or `@selection` (got `%v`)", dest_arg)
    }

    return dest, set_mode, {}
}

// source register can be a lowercase named register, numbered register, `selection`, or `@selection`
parse_cmd_set_source_reg :: proc(source_arg: string) -> (source: lib.Reg_Id, err: Maybe(string)) {
    if len(source_arg) == 1 {
        ch := source_arg[0]
        if ch >= 'a' && ch <= 'z' {     // lowercase named reg
            source = lib.reg_id_from_named_index(ch - 'a')
        } else if ch >= '0' && ch <= '9' {     // clipboard numbered reg
            source = lib.reg_id_from_clipboard_index(ch - '0')
        } else {
            return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `selection`, or `@selection` (got `%v`)", source_arg)
        }
    } else if len(source_arg) == 2 && source_arg[0] == '@' {     // primary numbered reg
        ch := source_arg[1]
        if ch >= '0' && ch <= '9' {
            source = lib.reg_id_from_primary_index(ch - '0')
        } else {
            return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `selection`, or `@selection` (got `%v`)", source_arg)
        }
    } else if source_arg == SELECTION_ARG {     // live clipboard selection
        source = lib.SELECTION_CLIPBOARD
    } else if source_arg == PRIMARY_SELECTION_ARG {     // live primary selection
        source = lib.SELECTION_PRIMARY
    } else {
        return {}, fmt.tprintf("source register must be 0-9, a-z, @0-@9, `selection`, or `@selection` (got `%v`)", source_arg)
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
    os_err: os.Error
    data, os_err = os.read_entire_file(stdin, context.allocator)
    if os_err != nil {
        return {}, {}, {}, {}, fmt.tprintf("could not read stdin: %v", os_err)
    }

    // Derived from the bytes, so necessarily after the read.
    mime = strings.clone(lib.resolve_mime(data))
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
// * An exact mime attaches to any `+`/`++` token with `=`, e.g. `+a=image/png` or `++named=text/html`.
// * Flags are `key=value`: `fmt=table|json|raw` (output shape) and `pref=printable|richest` (mime ranking).
parse_cmd_get :: proc(
    filter_args: []string,
) -> (
    filter: lib.Cmd_Get_Filter,
    format: Get_Cmd_Format,
    pref: lib.Ranked_Mime,
    err: Maybe(string),
) {
    incl: lib.Cmd_Get_Filter
    excl: lib.Cmd_Get_Filter

    // Flags
    format = .TABLE // fmt= default TODO: make user-configurable
    format_set := false
    pref = .PRINTABLE // pref= default TODO: make user-configurable
    pref_set := false

    for &arg in filter_args {
        if len(arg) == 0 {     // empty string arg should just be skipped, no-op
            continue
        }

        if len(arg) == 1 {
            return {}, {}, {}, "incomplete token"
        }

        switch arg[0] {     // every arg must start with one of the prefix tokens
        case '+':
            // Strip any `=mime` before dispatching so neither register nor keyword parsing has to know about it. The
            // mime itself is re-read by `resolve_mime_groups`; validated here so a bad one is rejected once, up front.
            token, mime, has_mime := split_mime_suffix(arg)
            if has_mime {
                if err = validate_exact_mime(mime); err != nil {return {}, {}, {}, err}
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
                return {}, {}, {}, fmt.tprintf("cannot attach a mime to an exclusion token (got `%v`)", arg)
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
                return {}, {}, {}, fmt.tprintf("invalid arg, expected key=value flag (got `%v`)", arg)
            }
            key := arg[:eq_idx]
            value := arg[eq_idx + 1:]
            switch key {
            case "fmt":
                if format_set {return {}, {}, {}, "you may only specify one format flag"}
                switch value {
                case "table":
                    format = .TABLE
                case "json":
                    format = .JSON
                case "raw":
                    format = .RAW
                case:
                    return {}, {}, {}, fmt.tprintf("invalid format value, expected `table`, `json`, or `raw` (got `%v`)", value)
                }
                format_set = true
            case "pref":
                if pref_set {return {}, {}, {}, "you may only specify one pref flag"}
                switch value {
                case "printable":
                    pref = .PRINTABLE
                case "richest":
                    pref = .RICHEST
                case:
                    return {}, {}, {}, fmt.tprintf("invalid pref value, expected `printable` or `richest` (got `%v`)", value)
                }
                pref_set = true
            case:
                return {}, {}, {}, fmt.tprintf("unknown flag `%v`", key)
            }
        case:
            return {}, {}, {}, fmt.tprintf("invalid arg, each arg should start with `+`, `-`, or be a key=value flag (got `%v`)", arg)
        }

        if err != nil {return {}, {}, {}, err}
    }

    filter = incl & ~excl
    return filter, format, pref, {}
}

// Split a register token from a trailing `=mime`. Splits on the first `=` because mimes can contain them (e.g.
// `text/plain;charset=utf-8`).
split_mime_suffix :: proc(arg: string) -> (token: string, mime: string, has_mime: bool) {
    eq_idx := strings.index_byte(arg, '=')
    if eq_idx < 0 {return arg, "", false}
    return arg[:eq_idx], arg[eq_idx + 1:], true
}

validate_exact_mime :: proc(mime: string) -> Maybe(string) {
    if len(mime) == 0 {
        return "empty mime after `=`"
    }
    if len(mime) > lib.MAX_MIME_LEN {
        return fmt.tprintf("mime is %d bytes, the maximum is %d (got `%v`)", len(mime), lib.MAX_MIME_LEN, mime)
    }
    if !strings.contains(mime, "/") {
        // Deliberately no prefix matching, unlike wl-paste's `-t image`: that discards the ranked order `pref=richest`
        // exists to provide, since alphabetically `image/gif` would beat `image/png`.
        return fmt.tprintf("mime must be a full `type/subtype` (got `%v`)", mime)
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
    default_pref: lib.Mime_Pref,
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

        pref: lib.Mime_Pref = default_pref if mime == "" else lib.Exact_Mime(mime)
        groups[count] = lib.Cmd_Get_Group {
            filter = set,
            pref   = pref,
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
    pref: lib.Mime_Pref,
    format_stated: bool,
    pref_stated: bool,
) -> (
    Get_Cmd_Format,
    lib.Mime_Pref,
) {
    if card(filter) != 1 || stdout_is_terminal() {return format, pref}

    format := format
    pref := pref
    if !format_stated {format = .RAW}

    // Only override the preference when the output is actually raw bytes.
    if !pref_stated && format == .RAW {
        // An unrecognised or absent extension leaves RICHEST, which still gets the bytes out -- it just cannot honour
        // the extension when a register holds several image formats.
        if mime := mime_for_path(stdout_path()); mime != "" {
            pref = lib.Exact_Mime(mime)
        } else {
            pref = lib.Ranked_Mime.RICHEST
        }
    }
    return format, pref
}

// Whether the user wrote a `key=` flag.
has_flag :: proc(args: []string, key: string) -> bool {
    for arg in args {
        if strings.has_prefix(arg, key) {return true}
    }
    return false
}

// Format unix epoch timestamp as date time
format_unix_timestamp :: proc(timestamp: i64, buf: ^[19]u8) -> string {
    t := time.unix(timestamp, 0)
    y, m, d := time.date(t)
    h, min, s := time.clock(t)
    return fmt.bprintf(buf[:], "%04d-%02d-%02d %02d:%02d:%02d", y, int(m), d, h, min, s)
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
        if runes >= width - 3 {
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
        cell = fmt.tprintf("%s...", cell)
        runes += 3
    }
    if runes >= width {return cell}
    return fmt.tprintf("%s%s", cell, strings.repeat(" ", width - runes, context.temp_allocator))
}

// The content cell for one register. Non-text content is described rather than rendered: replacement characters are
// noise, and their widths would skew the column even after escaping.
display_content :: proc(entry: lib.Resp_Reg, width: int) -> string {
    if entry.mime == "" {
        return table_cell("[no printable mime]", width)
    }
    if !utf8.valid_string(string(entry.data)) {
        return table_cell(fmt.tprintf("[%d bytes of binary data]", len(entry.data)), width)
    }
    return table_cell(string(entry.data), width)
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
    table_top := "┌────────────┬─────────────────────┬──────────────────────────┬──────────────────────────────────────────┐"
    table_sep := "├────────────┼─────────────────────┼──────────────────────────┼──────────────────────────────────────────┤"
    table_bot := "└────────────┴─────────────────────┴──────────────────────────┴──────────────────────────────────────────┘"
    fmt.println(table_top)
    fmt.println(
        "│  Register  │ Timestamp           │ Mimes                    │ Content                                  │",
    )

    // Mime and content cells are pre-padded by `table_cell`, so the format string must not pad them again.
    CONTENT_FMT :: "│ % 10s │ % -19s │ %s │ %s │"
    MIME_COL_WIDTH :: 24
    CONTENT_COL_WIDTH :: 40

    ts_buf: [19]u8
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

            // The representation that was actually fetched heads the mime column, sharing the line with its content. A
            // blank content cell would read like a bug next to a populated mime list, so say why the bytes are absent.
            mime := entry.mime
            if mime == "" {mime = entry.other_mimes[0]}
            fmt.printfln(
                CONTENT_FMT,
                lib.reg_id_to_string(id),
                format_unix_timestamp(entry.timestamp, &ts_buf),
                table_cell(mime, MIME_COL_WIDTH),
                display_content(entry, CONTENT_COL_WIDTH),
            )

            // Every other name the register advertises, stacked below. Not truncated: there is no other view that would
            // show what was hidden, so a `+N more` would be a dead end.
            others := entry.other_mimes if entry.mime != "" else entry.other_mimes[1:]
            for other in others {
                fmt.printfln(CONTENT_FMT, "", "", table_cell(other, MIME_COL_WIDTH), table_cell("", CONTENT_COL_WIDTH))
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

// Escape a string for a JSON string literal. Caller must have established the input is valid UTF-8 -- this iterates
// runes, so invalid bytes would silently become U+FFFD. See `json_content` for that check.
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
        case 0 ..< 0x20:
            // Valid UTF-8 but illegal unescaped in JSON, and clipboard text really does carry these (form feed, vertical
            // tab, NUL from a botched copy). Without this a single stray byte makes the whole document unparseable.
            fmt.sbprintf(&escaped, "\\u%04x", int(ch))
        case:
            strings.write_rune(&escaped, ch)
        }
    }
    return strings.to_string(escaped)
}

// Render `data` as a JSON value: a string when it is valid UTF-8, else base64 with a sibling `content_encoding` field.
json_content :: proc(data: []byte) -> (value: string, is_base64: bool) {
    str := string(data)
    if utf8.valid_string(str) {
        return fmt.tprintf(`"%s"`, json_escape_string(str)), false
    }
    return fmt.tprintf(`"%s"`, base64.encode(data, allocator = context.temp_allocator)), true
}

// `mime` is the representation `content` holds; both are null when nothing matched the preference. `other_mimes` lists
// the register's remaining names, any of which a consumer can pass back as `=mime` to fetch that representation.
print_json_entry :: proc(entry: lib.Resp_Reg, id_str: string, printed: ^bool) {
    if printed^ {fmt.print(", ")}

    fmt.printf(`{{"register": "%s", "timestamp": %d, "mime": `, id_str, entry.timestamp)
    if entry.mime == "" {
        fmt.print("null")
    } else {
        fmt.printf(`"%s"`, json_escape_string(entry.mime))
    }

    fmt.print(`, "content": `)
    if entry.mime == "" {
        fmt.print("null")
    } else {
        value, is_base64 := json_content(entry.data)
        fmt.print(value)
        if is_base64 {fmt.print(`, "content_encoding": "base64"`)}
    }

    fmt.print(`, "other_mimes": [`)
    for other, i in entry.other_mimes {
        if i > 0 {fmt.print(", ")}
        fmt.printf(`"%s"`, json_escape_string(other))
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

// `args` includes everything after the `clipbender get` subcommand.
cmd_get :: proc(args: []string, client_fd: linux.Fd) {
    if len(args) < 1 {
        print_cmd_usage_and_exit(.GET)
    }

    filter, format, pref, err := parse_cmd_get(args)
    if err != nil {
        fmt.eprintfln("Error: %v", err.?)
        print_cmd_usage_and_exit(.GET)
    }

    // Try to infer the output preference for a single-register request that isn't going to stdout.
    out_format, out_pref := infer_output(filter, format, pref, has_flag(args, "fmt="), has_flag(args, "pref="))

    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    group_count, group_err := resolve_mime_groups(args, filter, out_pref, &groups)
    if group_err != nil {
        fmt.eprintfln("Error: %v", group_err.?)
        os.exit(1)
    }
    if group_count == 0 {
        // Every group must claim at least one register, so the daemon rejects an empty request.
        fmt.eprintln("Error: filter matches no registers")
        os.exit(1)
    }

    // Send GET message
    msg: [lib.MAX_MSG_SIZE]byte
    written := lib.marshal_cmd_get(groups[:group_count], msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        fmt.eprintfln("Error: failed sending GET to daemon: errno %v", send_err)
        os.exit(1)
    }

    // Receive response from daemon
    resp_buf: [lib.MAX_MSG_SIZE]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        fmt.eprintfln("Error: no response from daemon for `get` command: errno %v", recv_err)
        os.exit(1)
    }

    regs: [lib.MAX_REGS]lib.Resp_Reg // buffer to store the response data, indexed by Reg_Id
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
        _, unmarshal_err := lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &regs)
        if unmarshal_err != nil {
            fmt.eprintfln("Error: malformed response from daemon: %v", unmarshal_err.?)
            os.exit(1)
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
        print_cmd_usage_and_exit(.SHUTDOWN)
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
