package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import lib "src:libclipbender"

// Build a one-register state buffer so the walk below is checked against the real marshaller rather than a
// hand-assembled byte string. Returns the marshalled bytes and the entry, which the caller frees.
// Two registers with distinct payloads, so the blob table has two entries and a cut can land inside the second.
dump_marshal_two :: proc(a, b: []byte) -> (buf: []byte, entries: [2]lib.Reg_Entry) {
    entries[0] = lib.Reg_Entry {
        reprs     = lib.data_repr_single(slice.clone(a), strings.clone("text/plain")),
        timestamp = 1,
    }
    entries[1] = lib.Reg_Entry {
        reprs     = lib.data_repr_single(slice.clone(b), strings.clone("text/plain")),
        timestamp = 2,
    }

    regs: [lib.MAX_REGS]^lib.Reg_Entry
    regs[lib.NAMED_START] = &entries[0]
    regs[lib.NAMED_START + 1] = &entries[1]

    buf = make([]byte, lib.state_size(regs))
    written := lib.marshal_state(regs, buf)
    return buf[:written], entries
}

dump_marshal_one :: proc(
    data: []byte,
    mime: string,
    bid: Maybe(lib.Bid) = nil,
) -> (
    buf: []byte,
    entry: lib.Reg_Entry,
) {
    entry = lib.Reg_Entry {
        reprs     = lib.data_repr_single(slice.clone(data), strings.clone(mime)),
        timestamp = 1,
    }
    entry.reprs[0].blob.id = bid

    regs: [lib.MAX_REGS]^lib.Reg_Entry
    regs[lib.NAMED_START] = &entry

    buf = make([]byte, lib.state_size(regs))
    written := lib.marshal_state(regs, buf)
    return buf[:written], entry
}

@(test)
test_dump_walk_blob_table_locates_inline_payload :: proc(t: ^testing.T) {
    // The format stores a tag and a length, never an offset, so the offset is arithmetic the dump performs. The point
    // of the test is that the arithmetic lands on the payload: `xxd -s <offset> -l <size>` has to work.
    payload := transmute([]byte)string("hello world")
    buf, entry := dump_marshal_one(payload, "text/plain")
    defer delete(buf)
    defer {entry := entry; lib.free_reg_entry(&entry)}

    blobs, err := get_blob_state_infos(buf)
    defer delete(blobs)
    testing.expect_value(t, err, nil)
    if !testing.expect_value(t, len(blobs), 1) {return}

    testing.expect_value(t, blobs[0].tag, lib.Blob_Tag.INLINE)
    testing.expect_value(t, blobs[0].size, u64(len(payload)))
    testing.expect(t, blobs[0].offset > 0, "inline offset should be past the header")
    testing.expect_value(t, string(buf[blobs[0].offset:][:blobs[0].size]), "hello world")
}

@(test)
test_dump_walk_blob_table_reports_file_blobs_by_id :: proc(t: ^testing.T) {
    // Over `BLOB_INLINE_MAX` the entry is `[tag][Bid][size]` with the bytes living in `blobs/<id>`, so the walk must
    // report the ID rather than an offset -- there is no payload in the state file to point at.
    payload := make([]byte, lib.BLOB_INLINE_MAX + 1)
    defer delete(payload)
    buf, entry := dump_marshal_one(payload, "application/octet-stream", lib.Bid(7))
    defer delete(buf)
    defer {entry := entry; lib.free_reg_entry(&entry)}

    blobs, err := get_blob_state_infos(buf)
    defer delete(blobs)
    testing.expect_value(t, err, nil)
    if !testing.expect_value(t, len(blobs), 1) {return}

    testing.expect_value(t, blobs[0].tag, lib.Blob_Tag.REF)
    testing.expect_value(t, blobs[0].id, lib.Bid(7))
    testing.expect_value(t, blobs[0].size, u64(len(payload)))
    testing.expect_value(t, dump_storage_field(blobs[0]), "blobs/00007")
}

@(test)
test_dump_walk_blob_table_rejects_truncation :: proc(t: ^testing.T) {
    // The walk runs before the load, so a truncated file reaches it first and it cannot assume its own bounds.
    buf, entry := dump_marshal_one(transmute([]byte)string("hello world"), "text/plain")
    defer delete(buf)
    defer {entry := entry; lib.free_reg_entry(&entry)}

    // Cut mid-payload, which means cutting inside the blob table rather than off the tail -- the blob table comes
    // first, so trimming the end only loses the register table and the walk would still succeed.
    mid_payload :: lib.STATE_HEADER_SIZE + size_of(u16) + size_of(lib.Blob_Tag) + size_of(u64) + 4
    short, err := get_blob_state_infos(buf[:mid_payload])
    defer delete(short)
    testing.expect(t, err != nil, "a truncated blob table should be rejected")

    // Shorter than the header plus the blob count.
    empty, empty_err := get_blob_state_infos(buf[:4])
    defer delete(empty)
    testing.expect(t, empty_err != nil, "a buffer with no blob count should be rejected")
}

@(test)
test_dump_storage_field_offset_is_exact :: proc(t: ^testing.T) {
    // The size column is rounded, so it cannot drive a `dd`. The storage field carries the exact length for that.
    field := dump_storage_field(Blob_State_Info{tag = .INLINE, size = 3174, offset = 372})
    testing.expect_value(t, field, "inline @372+3174")
}

@(test)
test_dump_blob_dir_stats_counts_orphans :: proc(t: ^testing.T) {
    dir := "test_dump_blobs"
    lib.make_private_directory(dir)
    defer os.remove_all(dir)

    named := strings.concatenate({dir, "/00003"}, context.temp_allocator)
    orphan := strings.concatenate({dir, "/00009"}, context.temp_allocator)
    not_a_bid := strings.concatenate({dir, "/notours"}, context.temp_allocator)
    testing.expect_value(t, os.write_entire_file(named, []byte{1, 2, 3}), nil)
    testing.expect_value(t, os.write_entire_file(orphan, []byte{4, 5}), nil)
    testing.expect_value(t, os.write_entire_file(not_a_bid, []byte{6}), nil)

    // Only `00003` is named by the table, so the other two are orphans -- including the unparseable name, which no
    // blob-table entry can be naming either.
    table := []Blob_State_Info{{tag = .REF, id = lib.Bid(3), size = 3}}
    stats, ok := dump_blob_dir_stats(dir, table)
    testing.expect(t, ok, "a readable blobs directory should report ok")
    testing.expect_value(t, stats.files, uint(3))
    testing.expect_value(t, stats.bytes, u64(6))
    testing.expect_value(t, stats.orphaned, uint(2))
}

@(test)
test_dump_blob_dir_stats_tolerates_missing_dir :: proc(t: ^testing.T) {
    // A store holding only inline blobs never creates `blobs/`, which is not an error -- hence `ok` rather than a
    // negative count, so no field has to double as a sentinel.
    stats, ok := dump_blob_dir_stats("test_dump_blobs_absent", nil)
    testing.expect(t, !ok, "a missing blobs directory should report not-ok")
    testing.expect_value(t, stats, Blob_Dir_Stats{})
}

// A state file that stops decoding partway must still hand back the entries that *did* decode -- that is the whole
// point of the partial dump, and it is the opposite of the usual "discard everything on error" contract, so pin it.
@(test)
test_get_blob_state_infos_returns_partial_results :: proc(t: ^testing.T) {
    // Two blobs, the second truncated: `dump_marshal_one` only makes one, so build the pair by hand.
    first := transmute([]byte)string("hello world")
    buf, entries := dump_marshal_two(first, transmute([]byte)string("second"))
    defer delete(buf)
    defer {entries := entries; for &e in entries {lib.free_reg_entry(&e)}}

    // Cut inside the second entry: past the first blob's payload, but short of the second's length prefix.
    cut ::
        lib.STATE_HEADER_SIZE +
        size_of(u16) +
        size_of(lib.Blob_Tag) +
        size_of(u64) +
        len("hello world") +
        size_of(lib.Blob_Tag) +
        2
    blobs, err := get_blob_state_infos(buf[:cut])
    defer delete(blobs)

    testing.expect(t, err != nil, "a truncated second entry should report an error")
    if !testing.expect_value(t, len(blobs), 1) {return}
    testing.expect_value(t, blobs[0].tag, lib.Blob_Tag.INLINE)
    testing.expect_value(t, blobs[0].size, u64(len(first)))
}

// `dir=` plus the exit codes, which is the whole contract `main.odin` relies on: 0 for a readable state dir, 1 for one
// that will not parse -- while still having printed what it could.
@(test)
test_cmd_dump_state_honours_dir_and_exit_codes :: proc(t: ^testing.T) {
    dir := fmt.tprintf("/tmp/clipbender-dumpcli-%d", os.get_pid())
    lib.make_private_directory(dir)
    defer os.remove_all(dir)

    buf, entry := dump_marshal_one(transmute([]byte)string("hello world"), "text/plain")
    defer delete(buf)
    defer {entry := entry; lib.free_reg_entry(&entry)}

    path := state_file_path(dir)
    defer delete(path)
    testing.expect_value(t, os.write_entire_file(path, buf), nil)

    dir_arg := fmt.tprintf("dir=%s", dir)
    testing.expect_value(t, cmd_dump_state({dir_arg, "fmt=json"}), 0)

    // Truncated inside the blob table: still dumped, but a non-zero code so a script can tell.
    testing.expect_value(t, os.write_entire_file(path, buf[:len(buf) - 4]), nil)
    testing.expect_value(t, cmd_dump_state({dir_arg, "fmt=json"}), 1)

    // A `dir=` with no path is a usage error, not an empty dump.
    testing.expect_value(t, cmd_dump_state({"dir="}), 1)
    testing.expect_value(t, cmd_dump_state({"fmt=yaml"}), 1)
}

// Covers the branch `dir=` bypasses: with no argument, the directory comes from `resolve_state_dir`, which hands back
// an *owned* string -- so this is the only path where `cmd_dump_state`'s conditional `defer delete(dir)` actually
// frees anything. Without this the ASan run never exercises it, and a leak or a bad free there would go unnoticed.
//
// `$XDG_RUNTIME_DIR` is process-global and the runner is multi-threaded, so this is only safe because no other test
// reads it: `resolve_state_dir` has exactly two callers, this command and `main`.
@(test)
test_cmd_dump_state_defaults_to_resolved_state_dir :: proc(t: ^testing.T) {
    root := fmt.tprintf("/tmp/clipbender-dumpenv-%d", os.get_pid())
    lib.make_private_directory(root)
    defer os.remove_all(root)

    // `ephemeral_state_dir` appends the subdir to `$XDG_RUNTIME_DIR`, so the state file has to land inside it.
    state_dir := fmt.tprintf("%s/%s", root, lib.CLIPBENDER_SUBDIR)
    lib.make_private_directory(state_dir)

    buf, entry := dump_marshal_one(transmute([]byte)string("hello world"), "text/plain")
    defer delete(buf)
    defer {entry := entry; lib.free_reg_entry(&entry)}

    path := state_file_path(state_dir)
    defer delete(path)
    testing.expect_value(t, os.write_entire_file(path, buf), nil)

    saved := os.get_env(lib.RUNTIME_ENV_VAR, context.temp_allocator)
    testing.expect_value(t, os.set_env(lib.RUNTIME_ENV_VAR, root), nil)
    defer if len(saved) > 0 {
        os.set_env(lib.RUNTIME_ENV_VAR, saved)
    } else {
        os.unset_env(lib.RUNTIME_ENV_VAR)
    }

    testing.expect_value(t, cmd_dump_state({"fmt=json"}), 0)
}
