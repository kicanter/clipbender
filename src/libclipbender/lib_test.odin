package libclipbender

import "core:slice"
import "core:testing"

@(test)
test_reg_id_validity :: proc(t: ^testing.T) {
    testing.expect(t, reg_id_is_valid(CLIPBOARD_START), "CLIPBOARD_START should be valid")
    testing.expect(t, reg_id_is_valid(CLIPBOARD_END), "CLIPBOARD_END should be valid")
    testing.expect(t, reg_id_is_valid(NAMED_START), "NAMED_START should be valid")
    testing.expect(t, reg_id_is_valid(NAMED_END), "NAMED_END should be valid")
    testing.expect(t, reg_id_is_valid(PRIMARY_START), "PRIMARY_START should be valid")
    testing.expect(t, reg_id_is_valid(PRIMARY_END), "PRIMARY_END should be valid")
    testing.expect(t, reg_id_is_valid(SELECTION_CLIPBOARD), "SELECTION_CLIPBOARD should be valid")
    testing.expect(t, reg_id_is_valid(SELECTION_PRIMARY), "SELECTION_PRIMARY should be valid")

    testing.expect(t, !reg_id_is_valid(Reg_Id(46)), "46 should be invalid")
    testing.expect(t, !reg_id_is_valid(Reg_Id(100)), "100 should be invalid")
    testing.expect(t, !reg_id_is_valid(Reg_Id(253)), "253 should be invalid")
}

@(test)
test_reg_id_classification :: proc(t: ^testing.T) {
    for i in u8(0) ..= 9 {
        id := Reg_Id(i)
        testing.expect(t, reg_id_is_clipboard_num(id))
        testing.expect(t, !reg_id_is_named(id))
        testing.expect(t, !reg_id_is_primary_num(id))
    }

    for i in u8(10) ..= 35 {
        id := Reg_Id(i)
        testing.expect(t, !reg_id_is_clipboard_num(id))
        testing.expect(t, reg_id_is_named(id))
        testing.expect(t, !reg_id_is_primary_num(id))
    }

    for i in u8(36) ..= 45 {
        id := Reg_Id(i)
        testing.expect(t, !reg_id_is_clipboard_num(id))
        testing.expect(t, !reg_id_is_named(id))
        testing.expect(t, reg_id_is_primary_num(id))
    }
}

@(test)
test_reg_id_read_only :: proc(t: ^testing.T) {
    testing.expect(t, reg_id_is_read_only(CLIPBOARD_START))
    testing.expect(t, reg_id_is_read_only(CLIPBOARD_END))
    testing.expect(t, reg_id_is_read_only(PRIMARY_START))
    testing.expect(t, reg_id_is_read_only(PRIMARY_END))

    testing.expect(t, !reg_id_is_read_only(NAMED_START))
    testing.expect(t, !reg_id_is_read_only(NAMED_END))
    testing.expect(t, !reg_id_is_read_only(SELECTION_CLIPBOARD))
    testing.expect(t, !reg_id_is_read_only(SELECTION_PRIMARY))
}

@(test)
test_reg_id_clipboard_roundtrip :: proc(t: ^testing.T) {
    for i in u8(0) ..< RECENCY_SIZE {
        id := reg_id_from_clipboard_index(i)
        testing.expect_value(t, reg_id_to_clipboard_index(id), i)
    }
}

@(test)
test_reg_id_named_roundtrip :: proc(t: ^testing.T) {
    for i in u8(0) ..< NAMED_SIZE {
        id := reg_id_from_named_index(i)
        testing.expect_value(t, reg_id_to_named_index(id), i)
    }
}

@(test)
test_reg_id_primary_roundtrip :: proc(t: ^testing.T) {
    for i in u8(0) ..< RECENCY_SIZE {
        id := reg_id_from_primary_index(i)
        testing.expect_value(t, reg_id_to_primary_index(id), i)
    }
}

@(test)
test_marshal_cmd_set_reg :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(5)
    source := SELECTION_CLIPBOARD
    mode := Set_Mode.OVERWRITE

    n := marshal_cmd_set_reg(dest, source, mode, buf[:])
    testing.expect_value(t, n, 5)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(buf[1]), dest)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(buf[4]), source)
}

@(test)
test_marshal_unmarshal_cmd_set_inline :: proc(t: ^testing.T) {
    buf: [256]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.APPEND
    mime := "text/plain"
    data := transmute([]byte)string("hello world")

    n := marshal_cmd_set_inline(dest, mode, mime, data, buf[:])
    expected_size :=
        size_of(Command_Type) +
        size_of(Reg_Id) +
        size_of(Set_Mode) +
        size_of(Source_Kind) +
        size_of(u8) +
        len(mime) +
        len(data)
    testing.expect_value(t, n, expected_size)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.INLINE)

    // decode_cmd_set_inline expects buf starting after Source_Kind byte
    dec_mime, dec_data := unmarshal_cmd_set_inline(buf[4:n])
    defer delete(dec_mime)
    defer delete(dec_data)

    testing.expect_value(t, dec_mime, mime)
    testing.expect(t, slice.equal(dec_data, data))
}

@(test)
test_marshal_unmarshal_cmd_get_ranked :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    filter := CMD_GET_FILTER_NUMBERED + CMD_GET_FILTER_NAMED
    groups := [?]Cmd_Get_Group{{filter = filter, pref = Ranked_Mime.SIMPLEST}}

    // A ranked group carries no mime, so it is 9 bytes: [1b type][1b count][8b filter][1b tag]
    n := marshal_cmd_get(groups[:], buf[:])
    testing.expect_value(t, n, 11)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.GET)
    testing.expect_value(t, buf[1], u8(1))

    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, dec[0].filter, filter)
    testing.expect_value(t, dec[0].pref, Mime_Pref(Ranked_Mime.SIMPLEST))
}

@(test)
test_marshal_unmarshal_cmd_get_mixed_groups :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    a := reg_id_from_named_index(0)
    b := reg_id_from_named_index(1)
    groups := [?]Cmd_Get_Group {
        {filter = transmute(Cmd_Get_Filter)(u64(1) << u64(a)), pref = Exact_Mime("image/png")},
        {filter = transmute(Cmd_Get_Filter)(u64(1) << u64(b)), pref = Ranked_Mime.RICHEST},
    }

    // 2 header + (8+1+1+9) exact + (8+1) ranked
    n := marshal_cmd_get(groups[:], buf[:])
    testing.expect_value(t, n, 30)

    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 2)
    testing.expect_value(t, dec[0].pref, Mime_Pref(Exact_Mime("image/png")))
    testing.expect_value(t, dec[1].pref, Mime_Pref(Ranked_Mime.RICHEST))
    testing.expect_value(t, dec[0].filter, groups[0].filter)
    testing.expect_value(t, dec[1].filter, groups[1].filter)
}

@(test)
test_unmarshal_cmd_get_max_mime :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    long: [MAX_MIME_LEN]byte
    for &c in long {c = 'x'}
    groups := [?]Cmd_Get_Group{{filter = CMD_GET_FILTER_ALL, pref = Exact_Mime(string(long[:]))}}

    n := marshal_cmd_get(groups[:], buf[:])
    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, dec[0].pref, Mime_Pref(Exact_Mime(string(long[:]))))
}

@(test)
test_unmarshal_cmd_get_rejects_bad_group_count :: proc(t: ^testing.T) {
    dec: [MAX_REGS]Cmd_Get_Group

    // Zero groups is meaningless; a count above MAX_REGS cannot be satisfied since each group needs a register bit.
    _, err_zero := unmarshal_cmd_get([]byte{0}, &dec)
    testing.expect(t, err_zero != nil, "group count 0 should be rejected")

    _, err_over := unmarshal_cmd_get([]byte{MAX_REGS + 1}, &dec)
    testing.expect(t, err_over != nil, "group count above MAX_REGS should be rejected")

    _, err_empty := unmarshal_cmd_get([]byte{}, &dec)
    testing.expect(t, err_empty != nil, "empty buffer should be rejected")
}

@(test)
test_unmarshal_cmd_get_rejects_unknown_pref :: proc(t: ^testing.T) {
    // One group whose pref tag is above EXACT_MIME_TAG. Group size depends on this byte, so it must be rejected
    // rather than defaulted -- otherwise the next group's filter is read as a mime length.
    msg: [10]byte
    msg[0] = 1 // group_count
    msg[9] = 99 // bogus pref tag
    dec: [MAX_REGS]Cmd_Get_Group
    _, err := unmarshal_cmd_get(msg[:], &dec)
    testing.expect(t, err != nil, "unknown pref tag should be rejected")
}

@(test)
test_unmarshal_cmd_get_rejects_truncated :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    groups := [?]Cmd_Get_Group{{filter = CMD_GET_FILTER_ALL, pref = Exact_Mime("text/plain")}}
    n := marshal_cmd_get(groups[:], buf[:])
    dec: [MAX_REGS]Cmd_Get_Group

    // Chop the mime bytes: the declared length now exceeds what remains.
    _, err_mime := unmarshal_cmd_get(buf[1:n - 4], &dec)
    testing.expect(t, err_mime != nil, "truncated mime should be rejected")

    // Chop mid-filter, before the pref byte is even reachable.
    _, err_filter := unmarshal_cmd_get(buf[1:6], &dec)
    testing.expect(t, err_filter != nil, "truncated filter should be rejected")
}

@(test)
test_unmarshal_cmd_get_rejects_empty_exact_mime :: proc(t: ^testing.T) {
    // EXACT with mime_len 0 would match nothing; reject it rather than return an unmatchable group.
    msg: [11]byte
    msg[0] = 1
    msg[9] = EXACT_MIME_TAG
    msg[10] = 0
    dec: [MAX_REGS]Cmd_Get_Group
    _, err := unmarshal_cmd_get(msg[:], &dec)
    testing.expect(t, err != nil, "empty exact mime should be rejected")
}

@(test)
test_marshal_unmarshal_resp_registers :: proc(t: ^testing.T) {
    buf: [1024]byte

    // Source array is indexed by Reg_Id; populate a few non-adjacent slots
    clip0 := reg_id_from_clipboard_index(0)
    named3 := reg_id_from_named_index(3)
    primary2 := reg_id_from_primary_index(2)

    regs: [MAX_REGS]Reg_Entry
    regs[clip0] = Reg_Entry {
        blobs     = []Mime_Blob{{data = transmute([]byte)string("first"), mimes = []string{"text/plain"}}},
        timestamp = 1000,
    }
    regs[named3] = Reg_Entry {
        blobs     = []Mime_Blob{{data = transmute([]byte)string("second entry"), mimes = []string{"text/html"}}},
        timestamp = 2000,
    }
    regs[primary2] = Reg_Entry {
        blobs     = []Mime_Blob{{data = transmute([]byte)string("third"), mimes = []string{"text/plain"}}},
        timestamp = 3000,
    }

    // marshal takes an array of pointers (borrows into the store); build one over `regs`.
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[clip0] = &regs[clip0]
    reg_ptrs[named3] = &regs[named3]
    reg_ptrs[primary2] = &regs[primary2]

    n := marshal_resp_registers(reg_ptrs, buf[:])
    testing.expect(t, n > 0)
    testing.expect_value(t, Resp_Status(buf[0]), Resp_Status.REGISTERS)
    testing.expect_value(t, buf[1], u8(3))

    dec_regs: [MAX_REGS]Reg_Entry
    count := unmarshal_resp_registers(buf[1:], &dec_regs)
    testing.expect_value(t, count, u8(3))

    // Entries should land at their original Reg_Id slots (M1: single blob, single mime)
    for id in ([]Reg_Id{clip0, named3, primary2}) {
        testing.expect_value(t, dec_regs[id].timestamp, regs[id].timestamp)
        testing.expect_value(t, dec_regs[id].blobs[0].mimes[0], regs[id].blobs[0].mimes[0])
        testing.expect(t, slice.equal(dec_regs[id].blobs[0].data, regs[id].blobs[0].data))
    }

    for &entry in dec_regs {
        free_reg_entry(&entry)
    }
}

@(test)
test_reg_id_to_string :: proc(t: ^testing.T) {
    testing.expect_value(t, reg_id_to_string(reg_id_from_clipboard_index(0)), "0")
    testing.expect_value(t, reg_id_to_string(reg_id_from_clipboard_index(9)), "9")
    testing.expect_value(t, reg_id_to_string(reg_id_from_named_index(0)), "a")
    testing.expect_value(t, reg_id_to_string(reg_id_from_named_index(25)), "z")
    testing.expect_value(t, reg_id_to_string(reg_id_from_primary_index(0)), "@0")
    testing.expect_value(t, reg_id_to_string(reg_id_from_primary_index(9)), "@9")
    testing.expect_value(t, reg_id_to_string(SELECTION_CLIPBOARD), "clipboard")
    testing.expect_value(t, reg_id_to_string(SELECTION_PRIMARY), "primary")
}

@(test)
test_marshal_cmd_set_reg_append :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(3)
    source := reg_id_from_clipboard_index(0)
    mode := Set_Mode.APPEND

    n := marshal_cmd_set_reg(dest, source, mode, buf[:])
    testing.expect_value(t, n, 5)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(buf[1]), dest)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(buf[4]), source)
}

@(test)
test_unmarshal_cmd_set_reg :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(5)
    source := reg_id_from_primary_index(7)
    mode := Set_Mode.OVERWRITE

    marshal_cmd_set_reg(dest, source, mode, buf[:])
    decoded_source := unmarshal_cmd_set_reg(buf[4:])
    testing.expect_value(t, decoded_source, source)
}

@(test)
test_marshal_unmarshal_cmd_clear :: proc(t: ^testing.T) {
    buf: [16]byte
    reg := reg_id_from_named_index(12)

    n := marshal_cmd_clear(reg, buf[:])
    testing.expect_value(t, n, 2)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.CLEAR)

    decoded_reg := unmarshal_cmd_clear(buf[1:])
    testing.expect_value(t, decoded_reg, reg)
}

@(test)
test_marshal_cmd_shutdown :: proc(t: ^testing.T) {
    buf: [16]byte

    n := marshal_cmd_shutdown(buf[:])
    testing.expect_value(t, n, 1)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.SHUTDOWN)
}

@(test)
test_marshal_unmarshal_resp_ok :: proc(t: ^testing.T) {
    buf: [16]byte

    n := marshal_resp_ok(buf[:])
    testing.expect_value(t, n, 1)
    testing.expect_value(t, Resp_Status(buf[0]), Resp_Status.OK)

    status := unmarshal_resp_ok(buf[:])
    testing.expect_value(t, status, Resp_Status.OK)
}

@(test)
test_marshal_unmarshal_resp_error :: proc(t: ^testing.T) {
    buf: [256]byte
    message := "source register `a` is empty"

    n := marshal_resp_error(message, buf[:])
    testing.expect_value(t, n, 1 + len(message))

    decoded_msg := unmarshal_resp_error(buf[1:n])
    testing.expect_value(t, decoded_msg, message)
}

@(test)
test_marshal_unmarshal_cmd_set_inline_empty_data :: proc(t: ^testing.T) {
    buf: [256]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.OVERWRITE
    mime := "text/plain"
    data := []byte{}

    n := marshal_cmd_set_inline(dest, mode, mime, data, buf[:])
    dec_mime, dec_data := unmarshal_cmd_set_inline(buf[4:n])
    defer delete(dec_mime)
    defer delete(dec_data)

    testing.expect_value(t, dec_mime, mime)
    testing.expect_value(t, len(dec_data), 0)
}

@(test)
test_marshal_unmarshal_cmd_set_inline_max_mime :: proc(t: ^testing.T) {
    buf: [512]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.OVERWRITE
    // 254 characters: the practical max before u8 arithmetic overflow in unmarshal_cmd_set_inline
    // (255 triggers a bug where `1 + u8(255)` wraps to 0, causing invalid slice indices)
    max_mime: [254]byte
    for &b in max_mime {b = 'x'}
    mime := string(max_mime[:])
    data := transmute([]byte)string("test")

    n := marshal_cmd_set_inline(dest, mode, mime, data, buf[:])
    dec_mime, dec_data := unmarshal_cmd_set_inline(buf[4:n])
    defer delete(dec_mime)
    defer delete(dec_data)

    testing.expect_value(t, dec_mime, mime)
    testing.expect(t, slice.equal(dec_data, data))
}
