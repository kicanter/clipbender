package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import lib "src:libclipbender"

// Format to use for `clipbenderd dump-state [fmt=stanza|json]`
Dump_Format :: enum {
    STANZA, // default in terminal
    JSON, // default when piped
}

// Data associated with a blob in the state file.
Blob_State_Info :: struct {
    tag:    lib.Blob_Tag,
    size:   u64, // amount of bytes the blob takes up in the blob table
    id:     lib.Bid, // meaningful only when `tag` is `.REF`
    offset: int, // file offset of the payload bytes, meaningful only when `tag` is `.INLINE`
}

DUMP_USAGE ::
    "Usage: clipbenderd dump-state [dir=<path>] [fmt=stanza|json]\n\n" +
    "Print a state directory's register state: the blob table and register table,\n" +
    "including every register's representations and which blob each one references.\n" +
    "A state file that cannot be parsed is still dumped as far as it decoded, then\n" +
    "reports where parsing stopped.\n\n" +
    "`dir=` reads an arbitrary state directory, or defaults to the one the daemon\n" +
    "itself would use.\n" +
    "`fmt=stanza` is the default when outputting to tty, `fmt=json` when piped.\n"

// Returns the process exit code.
@(require_results)
cmd_dump_state :: proc(args: []string) -> int {
    // Default to stanza during normal stdout, default to JSON when piping.
    format := Dump_Format.STANZA if os.is_tty(os.stdout) else Dump_Format.JSON
    dir_arg: Maybe(string)
    for arg in args {
        switch {
        case arg == "-h", arg == "--help", arg == "help":
            fmt.print(DUMP_USAGE)
            return 0
        case arg == "fmt=stanza":
            format = .STANZA
        case arg == "fmt=json":
            format = .JSON
        case strings.has_prefix(arg, "dir="):
            path := arg[len("dir="):]
            if len(path) == 0 {
                fmt.eprintln("Error: dir= needs a path")
                return 1
            }
            dir_arg = path
        case:
            fmt.eprintfln("Error: unknown argument %q to dump-state", arg)
            fmt.eprint(DUMP_USAGE)
            return 1
        }
    }

    dir: string
    if path, exists := dir_arg.?; exists {
        dir = path
    } else {
        resolved, ok := resolve_state_dir().? // allocates, need to free
        if !ok {
            fmt.eprintln("Error: no state directory to dump")
            return 1
        }
        dir = resolved
    }
    defer if dir_arg == nil {delete(dir)}     // we don't need to free if we're borrowing the dir from the cli arg

    state_path := state_file_path(dir)
    defer delete(state_path)
    blobs_dir := blobs_dir_path(dir)
    defer delete(blobs_dir)

    // Read the state file
    buf, read_err := os.read_entire_file(state_path, context.temp_allocator)
    if read_err != nil {
        fmt.eprintfln("Error: cannot read %s: %v", state_path, read_err)
        return 1
    }

    // Retrieve the tag, size, and offset (INLINE) or bid (REF) for each unique blob
    blob_state_infos, walk_err := get_blob_state_infos(buf) // don't immediately exit on failure, handle after unmarshal
    defer delete(blob_state_infos)

    regs: [lib.MAX_REGS]lib.Reg_Entry
    parse_err: Maybe(string)
    if walk_err == nil {
        // Load registers from state as if we were loading on startup.
        _, parse_err = lib.unmarshal_state(buf, &regs, blobs_dir) // don't immediately exit on failure, handle below
    }
    defer for &entry in regs {lib.free_reg_entry(&entry)}

    // Whichever stage errored first is the one worth reporting.
    stopped := walk_err if walk_err != nil else parse_err
    if stopped != nil {
        switch format {
        case .STANZA:
            dump_print_partial_stanza(state_path, blobs_dir, buf, blob_state_infos[:], stopped.?)
        case .JSON:
            dump_print_partial_json(state_path, blobs_dir, buf, blob_state_infos[:], stopped.?)
        }
        return 1
    }

    // Create a pointer for every non-empty register to build the blob table.
    reg_ptrs: [lib.MAX_REGS]^lib.Reg_Entry
    for &entry, i in regs {
        if len(entry.reprs) > 0 {reg_ptrs[i] = &entry}
    }
    unique_blobs := lib.unique_blobs(reg_ptrs, context.temp_allocator)

    switch format {
    case .STANZA:
        dump_print_stanza(state_path, blobs_dir, buf, blob_state_infos[:], unique_blobs[:], reg_ptrs)
    case .JSON:
        dump_print_json(state_path, blobs_dir, buf, blob_state_infos[:], unique_blobs[:], reg_ptrs)
    }
    return 0
}

// Mirrors `lib.read_blob_table`'s layout:
// [Tag][[8b INLINE length][length bytes]]|[[Bid][blob size]]
get_blob_state_infos :: proc(buf: []byte) -> (blobs: [dynamic]Blob_State_Info, err: Maybe(string)) {
    if len(buf) < lib.STATE_HEADER_SIZE + size_of(u16) {return nil, "state file has no blob count"}

    body := buf[lib.STATE_HEADER_SIZE:]
    offset := 0

    count_bytes: [size_of(u16)]byte
    copy(count_bytes[:], body[offset:][:size_of(u16)])
    count := int(transmute(u16)count_bytes)
    offset += size_of(u16)

    // Deliberately hands back the partially filled slice alongside the error.
    // Caller is responsible for freeing.
    acc := make([dynamic]Blob_State_Info, 0, count)

    for b in 0 ..< count {
        if offset + size_of(lib.Blob_Tag) > len(body) {
            return acc, fmt.tprintf("blob %d: missing tag", b)
        }
        tag := lib.Blob_Tag(body[offset])
        offset += size_of(lib.Blob_Tag)

        switch tag {
        case .INLINE:
            if offset + size_of(u64) > len(body) {
                return acc, fmt.tprintf("blob %d: missing data length", b)
            }
            size_bytes: [size_of(u64)]byte
            copy(size_bytes[:], body[offset:][:size_of(u64)])
            size := transmute(u64)size_bytes
            offset += size_of(u64)

            if size > u64(len(body) - offset) {
                return acc, fmt.tprintf("blob %d: data length %d exceeds the bytes remaining", b, size)
            }
            // File-relative, so the offset is pasteable into `xxd -s` / `dd skip=` directly.
            append(&acc, Blob_State_Info{tag = .INLINE, size = size, offset = lib.STATE_HEADER_SIZE + offset})
            offset += int(size)

        case .REF:
            if offset + size_of(lib.Bid) + size_of(u64) > len(body) {
                return acc, fmt.tprintf("blob %d: missing ID and size", b)
            }
            id_bytes: [size_of(lib.Bid)]byte
            copy(id_bytes[:], body[offset:][:size_of(lib.Bid)])
            offset += size_of(lib.Bid)

            size_bytes: [size_of(u64)]byte
            copy(size_bytes[:], body[offset:][:size_of(u64)])
            offset += size_of(u64)

            append(&acc, Blob_State_Info{tag = .REF, id = transmute(lib.Bid)id_bytes, size = transmute(u64)size_bytes})

        case:
            return acc, fmt.tprintf("blob %d: unknown tag %d", b, u8(tag))
        }
    }
    return acc, nil
}

// Stanza's last column: how a blob's bytes are stored.
//
// INLINE is `inline @<length>+<offset>` is offset plus length for hexdump viewing e.g. `xxd -s 41 -l 48 registers.iroh`
// REF is `blobs/<bid>`
dump_storage_field :: proc(blob: Blob_State_Info) -> string {
    switch blob.tag {
    case .INLINE:
        return fmt.tprintf("inline @%d+%d", blob.offset, blob.size)
    case .REF:
        name_buf: lib.Blob_Name
        return fmt.tprintf("%s/%s", BLOBS_SUBDIR, lib.blob_filename(name_buf[:], blob.id))
    }
    return "?"
}

// Stats for blobs directory
Blob_Dir_Stats :: struct {
    files:    uint, // num of unique large blobs
    bytes:    u64, // total amount of bytes across all unique large blobs
    orphaned: uint, // num of unique large blobs that are no longer referenced at all in the state file
}

// Count the files, bytes, and orphaned blob files in blobs dir.
//
// `ok` is false when blobs dir cannot be read, which is not necessarily an error. If clipbender has never had to write
// large blobs, this directory may not exist yet.
dump_blob_dir_stats :: proc(blobs_dir: string, disk_blobs: []Blob_State_Info) -> (stats: Blob_Dir_Stats, ok: bool) {
    fd, open_err := os.open(blobs_dir)
    if open_err != nil {return {}, false}
    defer os.close(fd)

    infos, read_err := os.read_dir(fd, -1, context.temp_allocator)
    if read_err != nil {return {}, false}

    for info in infos {
        stats.files += 1
        stats.bytes += u64(info.size)

        named := false
        if bid_val, parse_ok := strconv.parse_uint(info.name, 10); parse_ok {
            for blob in disk_blobs {
                if blob.tag == .REF && uint(blob.id) == bid_val {
                    named = true
                    break
                }
            }
        }
        if !named {stats.orphaned += 1}
    }
    return stats, true
}

DUMP_MIME_COL :: 26 // length of the mime column
DUMP_SIZE_COL :: 5 // length of number portion of size
DUMP_REG_COL :: 10 // `@selection` is the widest register label.
DUMP_REPR_COL :: DUMP_REG_COL + 2 // align with timestamp (2 spaces after end of register)
DUMP_SUMMARY_COL :: len("state file") + 2 // "state file" is the widest label of the summary + two spaces.

dump_print_stanza :: proc(
    state_path, blobs_dir: string,
    buf: []byte,
    blob_state_infos: []Blob_State_Info,
    unique_blobs: []^lib.Rc_Blob,
    regs: [lib.MAX_REGS]^lib.Reg_Entry,
) {
    total_reprs := 0
    total_regs := 0
    for entry in regs {
        if entry == nil {continue}
        total_regs += 1
        total_reprs += len(entry.reprs)
    }

    dump_print_header(state_path, blobs_dir)

    for entry, id in regs {
        if entry == nil {continue}
        ts_buf: [19]u8
        // <register>  <date> <time>
        fmt.printfln(
            "\n%*s  %s",
            DUMP_REG_COL,
            lib.reg_id_to_string(lib.Reg_Id(id)),
            lib.format_unix_timestamp(entry.timestamp, &ts_buf),
        )

        for repr in entry.reprs {
            index, found := lib.blob_index(unique_blobs, repr.blob)
            storage := "Not in blob table!"
            if found && int(index) < len(blob_state_infos) {
                storage = dump_storage_field(blob_state_infos[index])
            }

            size_num, size_unit := lib.human_readable_byte_count(u64(len(repr.blob.data)))
            // = <mime> <size_num> <size_unit> [<index>] x<refcount> <data loc>
            fmt.printfln(
                "%*s= %-*s%*s %-3s  [%d]  x%d  %s",
                DUMP_REPR_COL,
                "",
                DUMP_MIME_COL,
                repr.mimes[0] if len(repr.mimes) > 0 else "(no mime)",
                DUMP_SIZE_COL,
                size_num,
                size_unit,
                index,
                repr.blob.refcount,
                storage,
            )
            // Same as above, but uses "+" instead of "="
            for mime in repr.mimes[min(1, len(repr.mimes)):] {
                fmt.printfln("%*s+ %s", DUMP_REPR_COL, "", mime)
            }
        }
    }

    inline_count := 0
    shared := 0
    for blob in blob_state_infos {
        if blob.tag == .INLINE {inline_count += 1}
    }
    for blob in unique_blobs {
        if blob.refcount > 1 {shared += 1}
    }

    stats, have_blobs_dir := dump_blob_dir_stats(blobs_dir, blob_state_infos)

    // Start summary
    fmt.printfln("\n%-*s%d", DUMP_SUMMARY_COL, "Registers", total_regs)
    fmt.printfln("%-*s%d", DUMP_SUMMARY_COL, "Reprs", total_reprs)
    fmt.printfln(
        "%-*s%d  (%d inline, %d in blobs/, %d shared)",
        DUMP_SUMMARY_COL,
        "Blobs",
        len(blob_state_infos),
        inline_count,
        len(blob_state_infos) - inline_count,
        shared,
    )
    fmt.printfln("%-*s%s", DUMP_SUMMARY_COL, "State file", lib.human_readable_size(u64(len(buf))))
    if !have_blobs_dir {
        fmt.printfln("%-*s%s", DUMP_SUMMARY_COL, "Blobs dir", "absent")
    } else {
        fmt.printfln(
            "%-*s%s across %d files",
            DUMP_SUMMARY_COL,
            "Blobs dir",
            lib.human_readable_size(stats.bytes),
            stats.files,
        )
    }

    // Each anomaly on a `!` line.
    unreferenced := len(blob_state_infos) != len(unique_blobs)
    orphaned := have_blobs_dir && stats.orphaned > 0
    if unreferenced || orphaned {fmt.println()}
    if unreferenced {
        fmt.printfln(
            "! state file lists %d blobs, but only %d unique blobs were found",
            len(blob_state_infos),
            len(unique_blobs),
        )
    }
    if orphaned {
        fmt.printfln("! %d orphaned %s in blobs/", stats.orphaned, "file" if stats.orphaned == 1 else "files")
    }
}

// Mirrors the state file structure. Sizes are exact integers, `offset` and `id` are mutually exclusive (for INLINE and
// REF, respectively) and discriminated by `storage`, and timestamps are unix epoch times.
dump_print_json :: proc(
    state_path, blobs_dir: string,
    buf: []byte,
    disk_blobs: []Blob_State_Info,
    live_blobs: []^lib.Rc_Blob,
    regs: [lib.MAX_REGS]^lib.Reg_Entry,
) {
    dump_print_json_head(state_path, blobs_dir, buf, disk_blobs)

    // Blob list, effectively the blob table
    fmt.printf(`, "blobs": [`)
    for blob, i in disk_blobs {
        if i > 0 {fmt.print(", ")}
        refcount: uint = 0
        if i < len(live_blobs) {refcount = live_blobs[i].refcount}
        switch blob.tag {
        case .INLINE:
            fmt.printf(
                `{{"index": %d, "storage": "inline", "size": %d, "offset": %d, "refcount": %d}}`,
                i,
                blob.size,
                blob.offset,
                refcount,
            )
        case .REF:
            fmt.printf(
                `{{"index": %d, "storage": "file", "size": %d, "id": %d, "refcount": %d}}`,
                i,
                blob.size,
                u16(blob.id),
                refcount,
            )
        }
    }

    // Then the register table, where reprs reference a blob in the blob table by index.
    fmt.printf(`], "registers": [`)
    first := true
    for entry, id in regs {
        if entry == nil {continue}
        if !first {fmt.print(", ")}
        first = false
        fmt.printf(
            `{{"register": "%s", "timestamp": %d, "reprs": [`,
            lib.json_escape_string(lib.reg_id_to_string(lib.Reg_Id(id))),
            entry.timestamp,
        )
        for repr, r in entry.reprs {
            if r > 0 {fmt.print(", ")}
            index, found := lib.blob_index(live_blobs, repr.blob)
            if found {
                fmt.printf(`{{"blob": %d, "mimes": [`, index)
            } else {
                fmt.printf(`{{"blob": null, "mimes": [`)
            }
            for mime, m in repr.mimes {
                if m > 0 {fmt.print(", ")}
                fmt.printf(`"%s"`, lib.json_escape_string(mime))
            }
            fmt.print(`]}`)
        }
        fmt.print(`]}`)
    }

    fmt.printf(`]}`)
    fmt.println()
}

// Preliminary info in state dump. Used by the full and partial (failure) dumps.
dump_print_header :: proc(state_path, blobs_dir: string) {
    fmt.printfln("State v%d", lib.STATE_VERSION)
    fmt.printfln("State file:  %s", state_path)
    fmt.printfln("Blobs dir:   %s/", blobs_dir)
}

// Everything before the `"blobs"` list.
dump_print_json_head :: proc(state_path, blobs_dir: string, buf: []byte, disk_blobs: []Blob_State_Info) {
    stats, have_blobs_dir := dump_blob_dir_stats(blobs_dir, disk_blobs)

    fmt.printf(
        `{{"state_version": %d, "state_file": {{"path": "%s", "bytes": %d}}`,
        lib.STATE_VERSION,
        lib.json_escape_string(state_path),
        len(buf),
    )
    // The whole `blobs_dir` object is null when there is no blobs dir. This is not necessarily an error if the state
    // file only has inline blobs so the blob dir was never created.
    if have_blobs_dir {
        fmt.printf(
            `, "blobs_dir": {{"path": "%s", "bytes": %d, "files": %d, "orphaned": %d}}`,
            lib.json_escape_string(blobs_dir),
            stats.bytes,
            stats.files,
            stats.orphaned,
        )
    } else {
        fmt.printf(`, "blobs_dir": null`)
    }
}

// A state file that stopped decoding. Prints the blob entries that did decode and where parsing stopped. Register
// entries can't be printed because the load either never ran or discarded everything on failure.
dump_print_partial_stanza :: proc(
    state_path, blobs_dir: string,
    buf: []byte,
    blobs: []Blob_State_Info,
    stopped: string,
) {
    dump_print_header(state_path, blobs_dir)

    if len(blobs) > 0 {fmt.println()}
    for blob, i in blobs {
        num, unit := lib.human_readable_byte_count(blob.size)
        fmt.printfln("%*s[%d]  %*s %-3s  %s", DUMP_REPR_COL, "", i, DUMP_SIZE_COL, num, unit, dump_storage_field(blob))
    }

    fmt.printfln("\n%-*s%d decoded", DUMP_SUMMARY_COL, "Blobs", len(blobs))
    fmt.printfln("%-*s%s", DUMP_SUMMARY_COL, "State file", lib.human_readable_size(u64(len(buf))))
    fmt.printfln("\n! parsing stopped: %s", stopped)
}

// `registers` is null rather than `[]` to indicate failure instead of suggesting there are just no registers in the
// state. `error` key carries the same message the stanza prints.
dump_print_partial_json :: proc(
    state_path, blobs_dir: string,
    buf: []byte,
    blobs: []Blob_State_Info,
    stopped: string,
) {
    dump_print_json_head(state_path, blobs_dir, buf, blobs)

    fmt.printf(`, "blobs": [`)
    for blob, i in blobs {
        if i > 0 {fmt.print(", ")}
        switch blob.tag {
        case .INLINE:
            fmt.printf(`{{"index": %d, "storage": "inline", "size": %d, "offset": %d}}`, i, blob.size, blob.offset)
        case .REF:
            fmt.printf(`{{"index": %d, "storage": "file", "size": %d, "id": %d}}`, i, blob.size, u16(blob.id))
        }
    }
    fmt.printf(`], "registers": null, "error": "%s"}`, lib.json_escape_string(stopped))
    fmt.println()
}
