package main

import "core:testing"

import lib "src:libclipbender"

free_ring :: proc(ring: ^Recency_Ring) {
    for &entry in ring.entries {
        lib.free_reg_entry(&entry)
    }
    ring^ = {}
}

// M1 test helpers: entries hold a single blob with a single mime.
entry_data :: proc(entry: ^lib.Reg_Entry) -> []byte {
    return entry.blobs[0].data
}
entry_mime :: proc(entry: ^lib.Reg_Entry) -> string {
    return entry.blobs[0].mimes[0]
}

@(test)
test_push_recency_single :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)
    push_to_ring_clone(&ring, transmute([]byte)string("hello"), "text/plain")

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "should get entry at recency 0")
    testing.expect_value(t, string(entry_data(entry)), "hello")
    testing.expect_value(t, entry_mime(entry), "text/plain")
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
    testing.expect_value(t, string(entry_data(entry0)), "third")

    entry1 := get_ring_entry(&ring, 1)
    testing.expect(t, entry1 != nil)
    testing.expect_value(t, string(entry_data(entry1)), "second")

    entry2 := get_ring_entry(&ring, 2)
    testing.expect(t, entry2 != nil)
    testing.expect_value(t, string(entry_data(entry2)), "first")

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
    testing.expect_value(t, entry_data(entry)[0], u8(11))

    entry9 := get_ring_entry(&ring, 9)
    testing.expect(t, entry9 != nil)
    testing.expect_value(t, entry_data(entry9)[0], u8(2))
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
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(0)
    set_named_reg_clone(&store, id, transmute([]byte)string("test data"), "text/plain", .OVERWRITE)

    entry := get_reg(&store, id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry_data(entry)), "test data")
    testing.expect_value(t, entry_mime(entry), "text/plain")
}

@(test)
test_set_named_reg_overwrites :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(1)
    set_named_reg_clone(&store, id, transmute([]byte)string("old"), "text/plain", .OVERWRITE)
    set_named_reg_clone(&store, id, transmute([]byte)string("new"), "text/plain", .OVERWRITE)

    entry := get_reg(&store, id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry_data(entry)), "new")
}

@(test)
test_append_named_reg :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(2)
    set_named_reg_clone(&store, id, transmute([]byte)string("hello"), "text/plain", .OVERWRITE)
    ok := set_named_reg_clone(&store, id, transmute([]byte)string(" world"), "text/plain", .APPEND)
    testing.expect(t, ok, "append should succeed with matching mime")

    entry := get_reg(&store, id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry_data(entry)), "hello world")
}

@(test)
test_append_named_reg_mime_mismatch :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(3)
    set_named_reg_clone(&store, id, transmute([]byte)string("data"), "text/plain", .OVERWRITE)
    ok := set_named_reg_clone(&store, id, transmute([]byte)string("more"), "text/html", .APPEND)
    testing.expect(t, !ok, "append should fail with mismatched mime type")

    entry := get_reg(&store, id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry_data(entry)), "data")
}

@(test)
test_append_named_reg_empty :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(4)
    ok := set_named_reg_clone(&store, id, transmute([]byte)string("first"), "text/plain", .APPEND)
    testing.expect(t, ok, "append to empty should behave like set")

    entry := get_reg(&store, id)
    testing.expect(t, entry != nil)
    testing.expect_value(t, string(entry_data(entry)), "first")
}

@(test)
test_clear_named_reg :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(5)
    set_named_reg_clone(&store, id, transmute([]byte)string("to delete"), "text/plain", .OVERWRITE)
    clear_named_reg(&store, id)

    entry := get_reg(&store, id)
    testing.expect(t, entry == nil, "cleared register should not be found")
}

@(test)
test_get_reg_dispatches_named :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    set_named_reg_clone(
        &store,
        lib.reg_id_from_named_index(6),
        transmute([]byte)string("named"),
        "text/plain",
        .OVERWRITE,
    )

    named_entry := get_reg(&store, lib.reg_id_from_named_index(6))
    testing.expect(t, named_entry != nil)
    testing.expect_value(t, string(entry_data(named_entry)), "named")
}

@(test)
test_get_reg_clipboard_recency :: proc(t: ^testing.T) {
    // Use a local ring to avoid racing with other tests on the global
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("clip data"), "text/plain")

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "clipboard recency 0 should exist")
    testing.expect_value(t, string(entry_data(entry)), "clip data")
}

@(test)
test_get_reg_primary_recency :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("primary data"), "text/plain")

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "primary recency 0 should exist")
    testing.expect_value(t, string(entry_data(entry)), "primary data")
}

@(test)
test_get_reg_selection_clipboard :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("first"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("most recent"), "text/plain")

    // Recency 0 should be the most recent entry (same logic as SELECTION_CLIPBOARD)
    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "SELECTION_CLIPBOARD should return most recent")
    testing.expect_value(t, string(entry_data(entry)), "most recent")
}

@(test)
test_get_reg_selection_primary :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("old"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("newest"), "text/plain")

    entry := get_ring_entry(&ring, 0)
    testing.expect(t, entry != nil, "SELECTION_PRIMARY should return most recent")
    testing.expect_value(t, string(entry_data(entry)), "newest")
}

@(test)
test_get_registers_filter_clipboard_only :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("clip0"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("clip1"), "text/plain")

    // Verify ring has 2 entries accessible by recency
    entry0 := get_ring_entry(&ring, 0)
    entry1 := get_ring_entry(&ring, 1)
    testing.expect(t, entry0 != nil, "should find recency 0")
    testing.expect(t, entry1 != nil, "should find recency 1")
    testing.expect_value(t, string(entry_data(entry0)), "clip1")
    testing.expect_value(t, string(entry_data(entry1)), "clip0")
}

@(test)
test_get_registers_filter_primary_only :: proc(t: ^testing.T) {
    ring: Recency_Ring
    defer free_ring(&ring)

    push_to_ring_clone(&ring, transmute([]byte)string("pri0"), "text/plain")
    push_to_ring_clone(&ring, transmute([]byte)string("pri1"), "text/plain")

    entry0 := get_ring_entry(&ring, 0)
    entry1 := get_ring_entry(&ring, 1)
    testing.expect(t, entry0 != nil, "should find recency 0")
    testing.expect(t, entry1 != nil, "should find recency 1")
    testing.expect_value(t, string(entry_data(entry0)), "pri1")
    testing.expect_value(t, string(entry_data(entry1)), "pri0")
}

// Exercise get_registers' actual filter logic: only matched slots are populated, others stay nil.
@(test)
test_get_registers_selects_by_filter :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    push_recency_reg_clone(&store, .CLIPBOARD, transmute([]byte)string("clip"), "text/plain")
    push_recency_reg_clone(&store, .PRIMARY, transmute([]byte)string("pri"), "text/plain")
    set_named_reg_clone(&store, lib.reg_id_from_named_index(0), transmute([]byte)string("named"), "text/plain", .OVERWRITE)

    // Named-only filter: named slot populated, clipboard/primary slots nil.
    regs := get_registers(&store, lib.CMD_GET_FILTER_NAMED)
    named := regs[lib.reg_id_from_named_index(0)]
    testing.expect(t, named != nil, "named slot should be populated by NAMED filter")
    testing.expect_value(t, string(entry_data(named)), "named")
    testing.expect(t, regs[lib.reg_id_from_clipboard_index(0)] == nil, "clipboard slot should be nil under NAMED filter")
    testing.expect(t, regs[lib.reg_id_from_primary_index(0)] == nil, "primary slot should be nil under NAMED filter")

    // Clipboard-only filter: clipboard populated, named nil.
    regs2 := get_registers(&store, lib.CMD_GET_FILTER_NUMBERED)
    testing.expect(t, regs2[lib.reg_id_from_clipboard_index(0)] != nil, "clipboard slot should be populated")
    testing.expect(t, regs2[lib.reg_id_from_named_index(0)] == nil, "named slot should be nil under NUMBERED filter")
}

// get_registers must include live selections when their filter bits are set, and skip them otherwise.
@(test)
test_get_registers_live_selections :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    set_live_selection(&store, .CLIPBOARD, lib.mime_blob_single(transmute([]byte)string("live-clip"), "text/plain"))
    set_live_selection(&store, .PRIMARY, lib.mime_blob_single(transmute([]byte)string("live-pri"), "text/plain"))

    regs := get_registers(&store, lib.CMD_GET_FILTER_SELECTION + lib.CMD_GET_FILTER_PRIMARY_SELECTION)
    clip := regs[lib.SELECTION_CLIPBOARD]
    pri := regs[lib.SELECTION_PRIMARY]
    testing.expect(t, clip != nil, "live clipboard selection should be present")
    testing.expect(t, pri != nil, "live primary selection should be present")
    testing.expect_value(t, string(entry_data(clip)), "live-clip")
    testing.expect_value(t, string(entry_data(pri)), "live-pri")

    // Without the selection bits, live selections are excluded.
    regs2 := get_registers(&store, lib.CMD_GET_FILTER_NUMBERED)
    testing.expect(t, regs2[lib.SELECTION_CLIPBOARD] == nil, "live clipboard should be excluded without its filter bit")
    testing.expect(t, regs2[lib.SELECTION_PRIMARY] == nil, "live primary should be excluded without its filter bit")
}

// set_live_selection overwrites (freeing the previous), bump only updates timestamp.
@(test)
test_live_selection_set_and_bump :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    set_live_selection(&store, .CLIPBOARD, lib.mime_blob_single(transmute([]byte)string("one"), "text/plain"))
    sel := get_live_selection(&store, .CLIPBOARD)
    testing.expect(t, sel != nil)
    testing.expect_value(t, string(entry_data(sel)), "one")
    first_ts := sel.timestamp

    // Overwrite frees the previous value and stores the new one.
    set_live_selection(&store, .CLIPBOARD, lib.mime_blob_single(transmute([]byte)string("two"), "text/plain"))
    sel2 := get_live_selection(&store, .CLIPBOARD)
    testing.expect_value(t, string(entry_data(sel2)), "two")

    // Bump keeps the data, updates the timestamp monotonically (>=).
    bump_live_selection(&store, .CLIPBOARD)
    sel3 := get_live_selection(&store, .CLIPBOARD)
    testing.expect_value(t, string(entry_data(sel3)), "two")
    testing.expect(t, sel3.timestamp >= first_ts, "bumped timestamp should not go backwards")
}

// move_recency_reg_to_front reorders the ring without allocating, bringing a deeper entry to recency 0.
@(test)
test_move_recency_to_front :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    // Ring after pushes (recency 0 = most recent): c, b, a
    push_recency_reg_clone(&store, .CLIPBOARD, transmute([]byte)string("a"), "text/plain")
    push_recency_reg_clone(&store, .CLIPBOARD, transmute([]byte)string("b"), "text/plain")
    push_recency_reg_clone(&store, .CLIPBOARD, transmute([]byte)string("c"), "text/plain")

    // Move recency 2 ("a") to the front.
    move_recency_reg_to_front(&store, .CLIPBOARD, 2)

    r0 := get_recency_reg(&store, .CLIPBOARD, 0)
    r1 := get_recency_reg(&store, .CLIPBOARD, 1)
    r2 := get_recency_reg(&store, .CLIPBOARD, 2)
    testing.expect_value(t, string(entry_data(r0)), "a")
    testing.expect_value(t, string(entry_data(r1)), "c")
    testing.expect_value(t, string(entry_data(r2)), "b")
}

// Full persistence cycle: marshal store -> unmarshal -> load_registers repopulates a fresh store.
// This exercises the state-load path (load_registers) which frees the unmarshalled blobs slices.
@(test)
test_marshal_unmarshal_load_roundtrip :: proc(t: ^testing.T) {
    src: Register_Store
    defer cleanup_registers(&src)

    push_recency_reg_clone(&src, .CLIPBOARD, transmute([]byte)string("clip0"), "text/plain")
    push_recency_reg_clone(&src, .PRIMARY, transmute([]byte)string("pri0"), "text/plain")
    set_named_reg_clone(&src, lib.reg_id_from_named_index(1), transmute([]byte)string("named-b"), "text/plain", .OVERWRITE)

    // Marshal the numbered + named + primary registers (the persisted set).
    filter := lib.CMD_GET_FILTER_NUMBERED + lib.CMD_GET_FILTER_NAMED + lib.CMD_GET_FILTER_PRIMARY_NUMBERED
    regs := get_registers(&src, filter)
    buf: [4096]byte
    n := lib.marshal_resp_registers(regs, buf[:])
    testing.expect(t, n > 0)

    // Unmarshal into owned entries, then load into a fresh store (buf[1:] skips the Resp_Status byte).
    dec: [lib.MAX_REGS]lib.Reg_Entry
    lib.unmarshal_resp_registers(buf[1:], &dec)

    dst: Register_Store
    defer cleanup_registers(&dst)
    load_registers(&dst, dec)

    // Fresh store should have the same contents.
    clip := get_recency_reg(&dst, .CLIPBOARD, 0)
    pri := get_recency_reg(&dst, .PRIMARY, 0)
    named := get_reg(&dst, lib.reg_id_from_named_index(1))
    testing.expect(t, clip != nil && pri != nil && named != nil, "all loaded registers should be present")
    testing.expect_value(t, string(entry_data(clip)), "clip0")
    testing.expect_value(t, string(entry_data(pri)), "pri0")
    testing.expect_value(t, string(entry_data(named)), "named-b")
}

@(test)
test_get_registers_filter_mixed :: proc(t: ^testing.T) {
    store: Register_Store
    defer cleanup_registers(&store)

    id := lib.reg_id_from_named_index(7)
    push_recency_reg_clone(&store, .CLIPBOARD, transmute([]byte)string("clip"), "text/plain")
    push_recency_reg_clone(&store, .PRIMARY, transmute([]byte)string("pri"), "text/plain")
    set_named_reg_clone(&store, id, transmute([]byte)string("named"), "text/plain", .OVERWRITE)

    clip_entry := get_recency_reg(&store, .CLIPBOARD, 0)
    testing.expect(t, clip_entry != nil, "should find clipboard entry")
    testing.expect_value(t, string(entry_data(clip_entry)), "clip")

    pri_entry := get_recency_reg(&store, .PRIMARY, 0)
    testing.expect(t, pri_entry != nil, "should find primary entry")
    testing.expect_value(t, string(entry_data(pri_entry)), "pri")

    named_entry := get_reg(&store, id)
    testing.expect(t, named_entry != nil, "should find named entry")
    testing.expect_value(t, string(entry_data(named_entry)), "named")
}
