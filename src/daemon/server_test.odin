package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"

import lib "src:libclipbender"

// `data_buf` is a package-level global (the event loop is single-threaded and owns one receive buffer), so every test
// that drives `handle_recv` has to hold this for the duration. The test runner is parallel; without it two such tests
// scribble over each other's request bytes.
handler_lock: sync.Mutex

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

// As above, but returns the response the client would read rather than the resulting store state.
set_inline_response :: proc(
    server: ^Server_State,
    dest: lib.Reg_Id,
    mimes: []string,
    data: []byte,
    resp: []byte,
) -> (
    status: lib.Resp_Status,
    message: string,
) {
    fds: [2]linux.Fd
    linux.socketpair(.UNIX, .SEQPACKET, .HOPOPT, &fds)
    defer linux.close(fds[0])
    defer linux.close(fds[1])

    written := lib.marshal_cmd_set_inline(dest, .OVERWRITE, mimes, data, data_buf[:])
    handle_recv(server, written, fds[1])

    read, errno := linux.recv(fds[0], resp, linux.Socket_Msg{})
    if errno != .NONE || read < size_of(lib.Resp_Status) {return {}, ""}
    return lib.Resp_Status(resp[0]), string(resp[size_of(lib.Resp_Status):read])
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
    sync.lock(&handler_lock)
    defer sync.unlock(&handler_lock)

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
    table := lib.unique_blobs(get_registers(&server.registers, lib.CMD_GET_FILTER_ALL), context.temp_allocator)
    testing.expect_value(t, len(table), 2)
}

// The whole point of the classification is that a persistent ring failure must not be retried: a loop that logs and
// continues through `EBADF` spins hot against a broken ring forever. Retryable errnos are the ones that carry no
// information beyond "call again".
@(test)
test_classify_loop_errno_retryable :: proc(t: ^testing.T) {
    for errno in ([?]linux.Errno{.EINTR, .EAGAIN, .EBUSY}) {
        testing.expect_value(t, uring_error_is_fatal(errno), false)
    }
}

@(test)
test_classify_loop_errno_fatal :: proc(t: ^testing.T) {
    // Every errno `io_uring_enter` can report that will not heal on a retry.
    for errno in ([?]linux.Errno{.EBADF, .EINVAL, .ENXIO, .EOPNOTSUPP, .EFAULT}) {
        testing.expect_value(t, uring_error_is_fatal(errno), true)
    }
}

// Setting a live selection with no backend has to come back as an error. There is nobody to own the selection, so an
// OK response would tell the user a copy happened when the data went nowhere -- which it did, reporting
// "Success: overwrote dest reg `.`" immediately after logging that it could not.
@(test)
test_set_selection_without_backend_reports_error :: proc(t: ^testing.T) {
    sync.lock(&handler_lock)
    defer sync.unlock(&handler_lock)

    // The missing backend is the condition under test, so its `log.error` is expected output rather than a failure --
    // the test runner counts logged errors as failures otherwise.
    context.logger = log.nil_logger()

    server: Server_State // no backend
    defer cleanup_registers(&server.registers)

    resp: [256]u8
    status, message := set_inline_response(
        &server,
        lib.SELECTION_CLIPBOARD,
        {"text/plain"},
        transmute([]byte)string("hi"),
        resp[:],
    )

    testing.expect_value(t, status, lib.Resp_Status.ERROR)
    testing.expect(
        t,
        strings.contains(message, "no active clipboard backend"),
        fmt.tprintf("the error should name the missing backend, got %q", message),
    )
}

// The same request to a named register still succeeds without a backend: named registers are stored by the daemon and
// do not need one. Guards against the fix above turning into a blanket failure.
@(test)
test_set_named_without_backend_still_succeeds :: proc(t: ^testing.T) {
    sync.lock(&handler_lock)
    defer sync.unlock(&handler_lock)

    server: Server_State // no backend
    defer cleanup_registers(&server.registers)

    resp: [256]u8
    status, _ := set_inline_response(
        &server,
        lib.reg_id_from_named_index(0),
        {"text/plain"},
        transmute([]byte)string("hi"),
        resp[:],
    )

    testing.expect_value(t, status, lib.Resp_Status.OK)
}
