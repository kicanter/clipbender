package main

import "core:slice"
import "core:strings"
import "core:testing"

import lib "src:libclipbender"

free_ring :: proc(ring: ^Recency_Ring) {
    for &entry in ring.entries {
        lib.free_reg_entry(&entry)
    }
    ring^ = {}
}

@(test)
test_push_recency_single :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_to_ring_clone(&ring, transmute([]byte)string("hello"), "text/plain")

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "should get entry at recency 0")
    testing.expect_value(t, string(entry.data), "hello")
    testing.expect_value(t, entry.mime_type, "text/plain")
    testing.expect_value(t, ring.count, u8(1))
}

@(test)
test_push_recency_ordering :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_to_ring_clone(&ring, transmute([]byte)string("first"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("second"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("third"), "text/plain")

    entry0 := get_ring_entry(&ring, 0)
    testing.expect(t, entry0 != nil)
    testing.expect_value(t, string(entry0.data), "third")

    entry1 := get_ring_entry(&ring, 1)
    testing.expect(t, entry1 != nil)
    testing.expect_value(t, string(entry1.data), "second")

    entry2 := get_ring_entry(&ring, 2)
    testing.expect(t, entry2 != nil)
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
        push_to_ring_clone(&ring, buf, "text/plain")
        delete(buf)
    }

    testing.expect_value(t, ring.count, u8(lib.RECENCY_SIZE))

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil)
    testing.expect_value(t, entry.data[0], u8(11))

    entry9 := get_ring_entry(&ring, 9)
    testing.expect(t, entry9 != nil)
    testing.expect_value(t, entry9.data[0], u8(2))
}

@(test)
test_get_recency_out_of_bounds :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_to_ring_clone(&ring, transmute([]byte)string("one"), "text/plain")

    entry := get_ring_entry(&ring, 1)
    testing.expect(t, entry == nil, "recency 1 should fail when only 1 entry exists")

    entry2 := get_ring_entry(&ring, 10)
    testing.expect(t, entry2 == nil, "recency 10 should always fail")
}

@(test)
test_set_named_reg :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(0))

    id := lib.reg_id_from_named_index(0)
    set_named_reg_clone(id, transmute([]byte)string("test data"), "text/plain", .OVERWRITE)

    entry := get_reg(id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry.data), "test data")
    testing.expect_value(t, entry.mime_type, "text/plain")
}

@(test)
test_set_named_reg_overwrites :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(1))

    id := lib.reg_id_from_named_index(1)
    set_named_reg_clone(id, transmute([]byte)string("old"), "text/plain", .OVERWRITE)
    set_named_reg_clone(id, transmute([]byte)string("new"), "text/plain", .OVERWRITE)

    entry := get_reg(id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry.data), "new")
}

@(test)
test_append_named_reg :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(2))

    id := lib.reg_id_from_named_index(2)
    set_named_reg_clone(id, transmute([]byte)string("hello"), "text/plain", .OVERWRITE)
    ok := set_named_reg(id, slice.clone(transmute([]byte)string(" world")), strings.clone("text/plain"), .APPEND)
    testing.expect(t, ok, "append should succeed with matching mime")

    entry := get_reg(id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry.data), "hello world")
}

@(test)
test_append_named_reg_mime_mismatch :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(3))

    id := lib.reg_id_from_named_index(3)
    set_named_reg_clone(id, transmute([]byte)string("data"), "text/plain", .OVERWRITE)
    ok := set_named_reg(id, slice.clone(transmute([]byte)string("more")), strings.clone("text/html"), .APPEND)
    testing.expect(t, !ok, "append should fail with mismatched mime type")

    entry := get_reg(id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry.data), "data")
}

@(test)
test_append_named_reg_empty :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(4))

    id := lib.reg_id_from_named_index(4)
    ok := set_named_reg(id, slice.clone(transmute([]byte)string("first")), strings.clone("text/plain"), .APPEND)
    testing.expect(t, ok, "append to empty should behave like set")

    entry := get_reg(id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry.data), "first")
}

@(test)
test_clear_named_reg :: proc(t: ^testing.T) {
    id := lib.reg_id_from_named_index(5)
    set_named_reg_clone(id, transmute([]byte)string("to delete"), "text/plain", .OVERWRITE)
    clear_named_reg(id)

    entry := get_reg(id)
    testing.expect(t, entry == nil, "cleared register should not be found")
}

@(test)
test_get_reg_dispatches_named :: proc(t: ^testing.T) {
    defer clear_named_reg(lib.reg_id_from_named_index(6))

    set_named_reg_clone(lib.reg_id_from_named_index(6), transmute([]byte)string("named"), "text/plain", .OVERWRITE)

    named_entry := get_reg(lib.reg_id_from_named_index(6))
    testing.expect(t, named_entry != nil)
    testing.expect_value(t, string(named_entry.data), "named")
}
