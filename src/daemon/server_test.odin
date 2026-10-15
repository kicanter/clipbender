package main

import "core:slice"
import "core:sys/linux"
import "core:testing"

import lib "src:libclipbender"

// `handle_recv` writes its response to `client_fd`, so tests hand it a pipe. The read end is returned so the caller can
// close both; nothing asserts on the response here, only on the resulting store.
set_inline_via_handler :: proc(
    server: ^Server_State,
    dest: lib.Reg_Id,
    mimes: []string,
    data: []byte,
) -> (
    running: bool,
    dirty: bool,
) {
    // A socketpair, not a pipe: `send_resp` uses `send`, which returns ENOTSOCK on a pipe fd.
    fds: [2]linux.Fd
    linux.socketpair(.UNIX, .SEQPACKET, .HOPOPT, &fds)
    defer linux.close(fds[0])
    defer linux.close(fds[1])

    written := lib.marshal_cmd_set_inline(dest, .OVERWRITE, mimes, data, data_buf[:])
    return handle_recv(server, written, fds[1])
}

// SET INLINE dedups against the store, so two registers set to identical bytes share one blob. Without it the handler
// allocated a second copy of content it already held -- and an earlier version computed the shared blob but then built
// the repr from a freshly wrapped (and already freed) payload, which returned garbage for the second register rather
// than failing.
//
// Both halves live in one test on purpose: `data_buf` is a package-level global (the event loop is single-threaded and
// owns one receive buffer), so two tests driving `handle_recv` in parallel would race on it. Any future test that calls
// `handle_recv` belongs here too, or needs its own serialization.
@(test)
test_set_inline_dedups_by_content :: proc(t: ^testing.T) {
    server: Server_State
    defer cleanup_registers(&server.registers)

    mimes := []string{"text/plain"}
    payload := transmute([]byte)string("duplicate content")
    reg_a := lib.reg_id_from_named_index(0)
    reg_b := lib.reg_id_from_named_index(1)
    reg_c := lib.reg_id_from_named_index(2)

    set_inline_via_handler(&server, reg_a, mimes, payload)
    set_inline_via_handler(&server, reg_b, mimes, payload)
    set_inline_via_handler(&server, reg_c, mimes, transmute([]byte)string("something else"))

    a := get_reg(&server.registers, reg_a)
    b := get_reg(&server.registers, reg_b)
    c := get_reg(&server.registers, reg_c)
    testing.expect(t, a != nil && b != nil && c != nil, "all three registers should be set")

    // The payload must survive. The use-after-free showed up exactly here, as garbage in the second register.
    testing.expect(t, slice.equal(entry_data(a), payload), "first register holds its content")
    testing.expect(t, slice.equal(entry_data(b), payload), "second register holds its content")
    testing.expect_value(t, string(entry_data(c)), "something else")

    // Identical content shares one blob; distinct content does not.
    testing.expect(t, a.reprs[0].blob == b.reprs[0].blob, "identical content should share one blob")
    testing.expect_value(t, a.reprs[0].blob.refcount, 2)
    testing.expect(t, c.reprs[0].blob != a.reprs[0].blob, "different content should not share a blob")

    // Two unique blobs across three registers.
    table := lib.build_blob_table(get_registers(&server.registers, lib.CMD_GET_FILTER_ALL), context.temp_allocator)
    testing.expect_value(t, len(table), 2)
}
