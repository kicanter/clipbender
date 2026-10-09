package main

import "core:log"
import "core:slice"
import "core:sys/linux"
import "core:testing"
import "core:thread"

import lib "src:libclipbender"

// `read_pipe_blob` tests. This loop is the one part of the capture path that needs no compositor -- the compositor's
// only contribution is the fd -- and it is where two hangs and a buffer-padding bug have lived while the whole suite
// passed. Driving it with an ordinary `pipe2` makes all of that reachable.

// Write `chunks` into a fresh pipe from a worker thread, closing the write end when done, and return the read end.
// Threaded because a payload larger than the kernel's pipe buffer (~64 KiB) blocks the writer until a reader drains it.
pipe_with :: proc(chunks: [][]byte) -> linux.Fd {
    fds: [2]linux.Fd
    if linux.pipe2(&fds, {.CLOEXEC}) != nil {return -1}

    Writer :: struct {
        fd:     linux.Fd,
        chunks: [][]byte,
    }
    write_chunks :: proc(w: Writer) {
        for chunk in w.chunks {
            sent := 0
            for sent < len(chunk) {
                n, err := linux.write(w.fd, chunk[sent:])
                if err != .NONE || n <= 0 {break}
                sent += n
            }
        }
        linux.close(w.fd)
    }

    // `Writer` goes by value and `self_cleanup` releases the thread, so nothing here is freed by hand. Freeing either
    // one from the thread leaked: its default context frees through a different allocator than the test runner's
    // tracking one allocated from.
    thread.create_and_start_with_poly_data(Writer{fd = fds[1], chunks = chunks}, write_chunks, self_cleanup = true)

    return fds[0]
}

@(test)
test_read_pipe_blob_single_chunk :: proc(t: ^testing.T) {
    payload := transmute([]byte)string("hello world")
    got := read_pipe_blob(pipe_with({payload}), "text/plain")
    defer delete(got)
    testing.expect(t, slice.equal(got, payload), "payload should round-trip")
}

@(test)
test_read_pipe_blob_reassembles_short_reads :: proc(t: ^testing.T) {
    // Several writes arrive as separate reads, so the loop must concatenate rather than keep only the last chunk.
    got := read_pipe_blob(
        pipe_with(
            {transmute([]byte)string("one "), transmute([]byte)string("two "), transmute([]byte)string("three")},
        ),
        "text/plain",
    )
    defer delete(got)
    testing.expect_value(t, string(got), "one two three")
}

@(test)
test_read_pipe_blob_has_no_trailing_padding :: proc(t: ^testing.T) {
    // The loop resizes by `PIPE_READ_SIZE` then trims to what arrived. An earlier version never trimmed, so every blob
    // carried up to 64 KiB of zeroes -- which `slice.equal` dedup and every consumer would have seen as real content.
    payload := transmute([]byte)string("tiny")
    got := read_pipe_blob(pipe_with({payload}), "text/plain")
    defer delete(got)
    testing.expect_value(t, len(got), len(payload))
}

@(test)
test_read_pipe_blob_spans_kernel_buffer :: proc(t: ^testing.T) {
    // Larger than both `PIPE_READ_SIZE` (64 KiB) and the kernel's pipe buffer, so this genuinely exercises multiple
    // read iterations against a writer that has to block partway.
    size := lib.PIPE_READ_SIZE * 3 + 7
    payload := make([]byte, size)
    defer delete(payload)
    for &b, i in payload {b = byte(i % 251)}

    got := read_pipe_blob(pipe_with({payload}), "application/octet-stream")
    defer delete(got)
    testing.expect_value(t, len(got), size)
    testing.expect(t, slice.equal(got, payload), "a multi-chunk payload should reassemble byte-exactly")
}

@(test)
test_read_pipe_blob_empty_payload_is_nil :: proc(t: ^testing.T) {
    // A source that closes without writing offered nothing, which is distinct from offering zero-length content: the
    // caller skips the repr rather than storing an empty one.
    got := read_pipe_blob(pipe_with({}), "text/plain")
    testing.expect_value(t, len(got), 0)
}

@(test)
test_read_pipe_blob_terminates_on_eof :: proc(t: ^testing.T) {
    // The regression guard that matters most: an earlier version resized back on EOF but never `break`ed, so it spun
    // forever after every successful read. If this test hangs rather than fails, that bug is back.
    for _ in 0 ..< 20 {
        got := read_pipe_blob(pipe_with({transmute([]byte)string("x")}), "text/plain")
        delete(got)
    }
}

@(test)
test_read_pipe_blob_times_out_on_silent_writer :: proc(t: ^testing.T) {
    // Write end left open with nothing written: `poll` must time out rather than block forever. Deliberately not
    // closing the fd here is the point -- a hung source app is exactly this shape.
    //
    // The logger is silenced because the timeout logs at error level by design, and Odin's test runner fails any test
    // that emits one. Takes `READ_TIMEOUT_MS`, so this is the slowest test in the suite.
    context.logger = log.nil_logger()

    fds: [2]linux.Fd
    if linux.pipe2(&fds, {.CLOEXEC}) != nil {
        testing.fail_now(t, "pipe2 failed")
    }
    defer linux.close(fds[1])

    got := read_pipe_blob(fds[0], "text/plain")
    testing.expect_value(t, len(got), 0)
}

// `write_pipe_blob` tests. The mirror of the above, and the place a bug hid twice: passing the whole slice to every
// write yields the correct byte *count* with the wrong bytes, so these assert content rather than length.

// `write_pipe_blob` tests. Worker writes, test reads: whichever side writes a payload larger than the pipe buffer
// blocks until the other drains. Arguments go by value because the runner installs a per-test tracking allocator, so
// allocating on one thread and freeing on another wedges it.
send_async :: proc(mime: string, data: []byte) -> (read_fd: linux.Fd, worker: ^thread.Thread, ok: bool) {
    fds: [2]linux.Fd
    if linux.pipe2(&fds, {.CLOEXEC}) != nil {return -1, nil, false}

    worker = thread.create_and_start_with_poly_data3(
    fds[1],
    mime,
    data,
    proc(write_fd: linux.Fd, mime: string, data: []byte) {
        // `uds_serve` installs this in the daemon; the test runner never calls it, and without it a write to a
        // closed reader kills the test binary with exit 141.
        ignore_sigpipe()
        write_pipe_blob(write_fd, mime, data)
        linux.close(write_fd)
    },
    )
    return fds[0], worker, true
}

// Read to EOF in the caller's context, then join the writer. Caller deletes the result.
recv_all :: proc(read_fd: linux.Fd, worker: ^thread.Thread) -> []byte {
    got: [dynamic]byte
    chunk: [4096]byte
    for {
        n, err := linux.read(read_fd, chunk[:])
        if err != .NONE || n <= 0 {break}
        append(&got, ..chunk[:n])
    }
    linux.close(read_fd)
    thread.join(worker)
    thread.destroy(worker)
    return got[:]
}

@(test)
test_write_pipe_blob_single_chunk :: proc(t: ^testing.T) {
    payload := transmute([]byte)string("hello world")
    read_fd, worker, ok := send_async("text/plain", payload)
    testing.expect(t, ok, "pipe2 failed")
    if !ok {return}

    got := recv_all(read_fd, worker)
    defer delete(got)
    testing.expect(t, slice.equal(got, payload), "payload should round-trip")
}

@(test)
test_write_pipe_blob_spans_kernel_buffer :: proc(t: ^testing.T) {
    // Larger than the 64 KiB pipe buffer, so the write resumes from `total_written`. Passing the whole slice each
    // iteration gave the right byte count and the wrong bytes, so this compares content.
    size := 64 * 1024 * 3 + 1234
    payload := make([]byte, size)
    defer delete(payload)
    for &b, i in payload {b = byte((i * 7 + i / 251) % 251)}

    read_fd, worker, ok := send_async("image/png", payload)
    testing.expect(t, ok, "pipe2 failed")
    if !ok {return}

    got := recv_all(read_fd, worker)
    defer delete(got)
    testing.expect_value(t, len(got), size)
    testing.expect(t, slice.equal(got, payload), "must reassemble byte-exactly")
}

@(test)
test_write_pipe_blob_empty_payload :: proc(t: ^testing.T) {
    read_fd, worker, ok := send_async("text/plain", []byte{})
    testing.expect(t, ok, "pipe2 failed")
    if !ok {return}

    got := recv_all(read_fd, worker)
    defer delete(got)
    testing.expect_value(t, len(got), 0)
}

@(test)
test_write_pipe_blob_survives_closed_reader :: proc(t: ^testing.T) {
    // Writing to a pipe whose reader is gone must yield EPIPE, not kill the process.
    ignore_sigpipe()
    context.logger = log.nil_logger()

    fds: [2]linux.Fd
    if linux.pipe2(&fds, {.CLOEXEC}) != nil {
        testing.fail_now(t, "pipe2 failed")
    }
    defer linux.close(fds[1])
    linux.close(fds[0])

    payload := make([]byte, 128 * 1024)
    defer delete(payload)
    write_pipe_blob(fds[1], "text/plain", payload)
}

@(test)
test_write_pipe_blob_times_out_on_stalled_receiver :: proc(t: ^testing.T) {
    // Reader open but never reading, payload larger than the buffer: `poll` must time out rather than block forever.
    // Requires O_NONBLOCK, since a blocking pipe write never returns short. Takes `PIPE_TIMEOUT_MS`.
    context.logger = log.nil_logger()

    fds: [2]linux.Fd
    if linux.pipe2(&fds, {.CLOEXEC}) != nil {
        testing.fail_now(t, "pipe2 failed")
    }
    defer linux.close(fds[0])
    defer linux.close(fds[1])

    payload := make([]byte, 512 * 1024)
    defer delete(payload)
    write_pipe_blob(fds[1], "image/png", payload)
}

// `reprs_are_equal` dedup comparison. Mime order is not semantically load-bearing, so two offers naming the same mimes
// in a different order are the same representation and must not both be stored.
@(test)
test_reprs_are_equal_ignores_mime_order :: proc(t: ^testing.T) {
    data := transmute([]byte)string("hello")
    a := []lib.Data_Repr{{data = data, mimes = []string{"text/plain;charset=utf-8", "text/plain"}}}
    b := []lib.Data_Repr{{data = data, mimes = []string{"text/plain", "text/plain;charset=utf-8"}}}
    testing.expect(t, reprs_are_equal(a, b), "same mimes in a different order should compare equal")
    testing.expect(t, reprs_are_equal(b, a), "comparison should be symmetric")
}

@(test)
test_reprs_are_equal_rejects_differences :: proc(t: ^testing.T) {
    data := transmute([]byte)string("hello")
    base := []lib.Data_Repr{{data = data, mimes = []string{"text/plain", "text/html"}}}

    diff_bytes := []lib.Data_Repr {
        {data = transmute([]byte)string("hellO"), mimes = []string{"text/plain", "text/html"}},
    }
    testing.expect(t, !reprs_are_equal(base, diff_bytes), "differing data should not compare equal")

    diff_mime := []lib.Data_Repr{{data = data, mimes = []string{"text/plain", "text/xml"}}}
    testing.expect(t, !reprs_are_equal(base, diff_mime), "a differing mime name should not compare equal")

    fewer := []lib.Data_Repr{{data = data, mimes = []string{"text/plain"}}}
    testing.expect(t, !reprs_are_equal(base, fewer), "a differing mime count should not compare equal")

    two_reprs := []lib.Data_Repr {
        {data = data, mimes = []string{"text/plain", "text/html"}},
        {data = data, mimes = []string{"image/png"}},
    }
    testing.expect(t, !reprs_are_equal(base, two_reprs), "a differing repr count should not compare equal")
}

// A trailing-whitespace difference is a real byte difference and must keep comparing unequal -- the terminal-selection
// duplicate bug is not to be "fixed" by normalising content here.
@(test)
test_reprs_are_equal_whitespace_is_significant :: proc(t: ^testing.T) {
    mimes := []string{"text/plain"}
    a := []lib.Data_Repr{{data = transmute([]byte)string("foo"), mimes = mimes}}
    b := []lib.Data_Repr{{data = transmute([]byte)string("foo "), mimes = mimes}}
    c := []lib.Data_Repr{{data = transmute([]byte)string("foo  "), mimes = mimes}}
    testing.expect(t, !reprs_are_equal(a, b), "one trailing space is a real difference")
    testing.expect(t, !reprs_are_equal(b, c), "two trailing spaces differ from one")
}
