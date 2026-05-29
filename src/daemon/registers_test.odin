package main

import "core:testing"

import "../lib"

free_ring :: proc(ring: ^Recency_Ring) {
    for &entry in ring.entries {
        free_reg_entry(&entry)
    }
    ring^ = {}
}

@(test)
test_push_recency_single :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_recency_reg(&ring, lib.Reg_Entry{data = transmute([]byte)string("hello"), mime_type = "text/plain", timestamp = 1000})

    entry, ok := get_recency_reg(&ring, 0)
    testing.expect(t, ok, "should get entry at recency 0")
    testing.expect_value(t, string(entry.data), "hello")
    testing.expect_value(t, entry.mime_type, "text/plain")
    testing.expect_value(t, entry.timestamp, i64(1000))
    testing.expect_value(t, ring.count, u8(1))
}

@(test)
test_push_recency_ordering :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_recency_reg(&ring, lib.Reg_Entry{data = transmute([]byte)string("first"), mime_type = "text/plain", timestamp = 1})
    push_recency_reg(&ring, lib.Reg_Entry{data = transmute([]byte)string("second"), mime_type = "text/plain", timestamp = 2})
    push_recency_reg(&ring, lib.Reg_Entry{data = transmute([]byte)string("third"), mime_type = "text/plain", timestamp = 3})

    entry0, ok0 := get_recency_reg(&ring, 0)
    testing.expect(t, ok0)
    testing.expect_value(t, string(entry0.data), "third")

    entry1, ok1 := get_recency_reg(&ring, 1)
    testing.expect(t, ok1)
    testing.expect_value(t, string(entry1.data), "second")

    entry2, ok2 := get_recency_reg(&ring, 2)
    testing.expect(t, ok2)
    testing.expect_value(t, string(entry2.data), "first")

    testing.expect_value(t, ring.count, u8(3))
}

@(test)
test_push_recency_overflow :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    for i in 0 ..< 12 {
        buf := make([]byte, 1)
        buf[0] = u8(i)
        push_recency_reg(&ring, lib.Reg_Entry{data = buf, mime_type = "text/plain", timestamp = i64(i)})
        delete(buf)
    }

    testing.expect_value(t, ring.count, u8(lib.RECENCY_SIZE))

    entry, ok := get_recency_reg(&ring, 0)
    testing.expect(t, ok)
    testing.expect_value(t, entry.data[0], u8(11))

    entry9, ok9 := get_recency_reg(&ring, 9)
    testing.expect(t, ok9)
    testing.expect_value(t, entry9.data[0], u8(2))
}

@(test)
test_get_recency_out_of_bounds :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_recency_reg(&ring, lib.Reg_Entry{data = transmute([]byte)string("one"), mime_type = "text/plain", timestamp = 1})

    _, ok := get_recency_reg(&ring, 1)
    testing.expect(t, !ok, "recency 1 should fail when only 1 entry exists")

    _, ok2 := get_recency_reg(&ring, 10)
    testing.expect(t, !ok2, "recency 10 should always fail")
}

@(test)
test_set_named_reg :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(0))

    id := lib.reg_id_from_named_index(0)
    set_named_reg(id, transmute([]byte)string("test data"), "text/plain")

    entry, ok := get_reg(id)
    testing.expect(t, ok)
    testing.expect_value(t, string(entry.data), "test data")
    testing.expect_value(t, entry.mime_type, "text/plain")
}

@(test)
test_set_named_reg_overwrites :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(1))

    id := lib.reg_id_from_named_index(1)
    set_named_reg(id, transmute([]byte)string("old"), "text/plain")
    set_named_reg(id, transmute([]byte)string("new"), "text/plain")

    entry, ok := get_reg(id)
    testing.expect(t, ok)
    testing.expect_value(t, string(entry.data), "new")
}

@(test)
test_append_named_reg :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(2))

    id := lib.reg_id_from_named_index(2)
    set_named_reg(id, transmute([]byte)string("hello"), "text/plain")
    ok := append_named_reg(id, transmute([]byte)string(" world"), "text/plain")
    testing.expect(t, ok, "append should succeed with matching mime")

    entry, got := get_reg(id)
    testing.expect(t, got)
    testing.expect_value(t, string(entry.data), "hello world")
}

@(test)
test_append_named_reg_mime_mismatch :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(3))

    id := lib.reg_id_from_named_index(3)
    set_named_reg(id, transmute([]byte)string("data"), "text/plain")
    ok := append_named_reg(id, transmute([]byte)string("more"), "text/html")
    testing.expect(t, !ok, "append should fail with mismatched mime type")

    entry, got := get_reg(id)
    testing.expect(t, got)
    testing.expect_value(t, string(entry.data), "data")
}

@(test)
test_append_named_reg_empty :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(4))

    id := lib.reg_id_from_named_index(4)
    ok := append_named_reg(id, transmute([]byte)string("first"), "text/plain")
    testing.expect(t, ok, "append to empty should behave like set")

    entry, got := get_reg(id)
    testing.expect(t, got)
    testing.expect_value(t, string(entry.data), "first")
}

@(test)
test_clear_named_reg :: proc(t: ^testing.T) {
    id := lib.reg_id_from_named_index(5)
    set_named_reg(id, transmute([]byte)string("to delete"), "text/plain")
    clear_named_reg(id)

    _, ok := get_reg(id)
    testing.expect(t, !ok, "cleared register should not be found")
}

@(test)
test_get_reg_dispatches_correctly :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(6))
    defer free_ring(&clipboard_registers)
    defer free_ring(&primary_registers)

    set_clipboard_reg(transmute([]byte)string("clip"), "text/plain")
    set_primary_reg(transmute([]byte)string("prim"), "text/plain")
    set_named_reg(lib.reg_id_from_named_index(6), transmute([]byte)string("named"), "text/plain")

    clip_entry, clip_ok := get_reg(lib.reg_id_from_clipboard_index(0))
    testing.expect(t, clip_ok)
    testing.expect_value(t, string(clip_entry.data), "clip")

    prim_entry, prim_ok := get_reg(lib.reg_id_from_primary_index(0))
    testing.expect(t, prim_ok)
    testing.expect_value(t, string(prim_entry.data), "prim")

    named_entry, named_ok := get_reg(lib.reg_id_from_named_index(6))
    testing.expect(t, named_ok)
    testing.expect_value(t, string(named_entry.data), "named")
}
