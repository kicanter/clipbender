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
    w := new(Writer)
    w^ = Writer {
        fd     = fds[1],
        chunks = chunks,
    }

    thread.create_and_start_with_poly_data(w, proc(w: ^Writer) {
        for chunk in w.chunks {
            sent := 0
            for sent < len(chunk) {
                n, err := linux.write(w.fd, chunk[sent:])
                if err != .NONE || n <= 0 {break}
                sent += n
            }
        }
        linux.close(w.fd)
        free(w)
    })

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
            {
                transmute([]byte)string("one "),
                transmute([]byte)string("two "),
                transmute([]byte)string("three"),
            },
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
