package libclipbender

import "core:fmt"
import "core:slice"
import "core:strings"
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
    testing.expect_value(t, n, CMD_SET_REG_SIZE)
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    testing.expect_value(t, Command_Type(body[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(body[1]), dest)
    testing.expect_value(t, Set_Mode(body[2]), mode)
    testing.expect_value(t, Source_Kind(body[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(body[4]), source)
}

@(test)
test_marshal_unmarshal_cmd_set_inline :: proc(t: ^testing.T) {
    buf: [256]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.APPEND
    mimes := []string{"application/rtf", "text/plain"}
    data := transmute([]byte)string("hello world")

    n := marshal_cmd_set_inline(dest, mode, mimes, data, buf[:])
    testing.expect_value(t, n, cmd_set_inline_size(mimes, data))
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    testing.expect_value(t, Set_Mode(body[2]), mode)
    testing.expect_value(t, Source_Kind(body[3]), Source_Kind.INLINE)
    testing.expect_value(t, int(body[4]), len(mimes))

    // unmarshal_cmd_set_inline expects buf starting after the Source_Kind byte
    dec_mimes, dec_data, dec_err := unmarshal_cmd_set_inline(buf[CMD_VERSION_SIZE + CMD_SET_HEADER_SIZE:n])
    defer {
        for mime in dec_mimes {delete(mime)}
        delete(dec_mimes)
    }
    defer delete(dec_data)
    testing.expect_value(t, dec_err, nil)

    testing.expect_value(t, len(dec_mimes), len(mimes))
    for mime, i in mimes {
        testing.expect_value(t, dec_mimes[i], mime)
    }
    testing.expect(t, slice.equal(dec_data, data))
}

@(test)
test_marshal_unmarshal_cmd_get_ranked :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    filter := CMD_GET_FILTER_NUMBERED + CMD_GET_FILTER_NAMED
    groups := [?]Cmd_Get_Group{{filter = filter, policy = Ranked_Policy.TEXTUAL}}

    // A ranked group carries no mime: [1b version][1b type][1b count][8b filter][1b tag]
    n := marshal_cmd_get(groups[:], buf[:])
    testing.expect_value(t, n, CMD_VERSION_SIZE + 11)
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    testing.expect_value(t, Command_Type(buf[CMD_VERSION_SIZE]), Command_Type.GET)
    testing.expect_value(t, buf[CMD_VERSION_SIZE + 1], u8(1))

    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[CMD_VERSION_SIZE + 1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, dec[0].filter, filter)
    testing.expect_value(t, dec[0].policy, Mime_Policy(Ranked_Policy.TEXTUAL))
}

@(test)
test_marshal_unmarshal_cmd_get_mixed_groups :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    a := reg_id_from_named_index(0)
    b := reg_id_from_named_index(1)
    groups := [?]Cmd_Get_Group {
        {filter = transmute(Cmd_Get_Filter)(u64(1) << u64(a)), policy = Exact_Mime("image/png")},
        {filter = transmute(Cmd_Get_Filter)(u64(1) << u64(b)), policy = Ranked_Policy.VISUAL},
    }

    // 2 header + (8+1+1+9) exact + (8+1) ranked
    n := marshal_cmd_get(groups[:], buf[:])
    testing.expect_value(t, n, CMD_VERSION_SIZE + 30)

    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[CMD_VERSION_SIZE + 1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 2)
    testing.expect_value(t, dec[0].policy, Mime_Policy(Exact_Mime("image/png")))
    testing.expect_value(t, dec[1].policy, Mime_Policy(Ranked_Policy.VISUAL))
    testing.expect_value(t, dec[0].filter, groups[0].filter)
    testing.expect_value(t, dec[1].filter, groups[1].filter)
}

@(test)
test_unmarshal_cmd_get_max_mime :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    long: [MAX_MIME_LEN]byte
    for &c in long {c = 'x'}
    groups := [?]Cmd_Get_Group{{filter = CMD_GET_FILTER_ALL, policy = Exact_Mime(string(long[:]))}}

    n := marshal_cmd_get(groups[:], buf[:])
    dec: [MAX_REGS]Cmd_Get_Group
    count, err := unmarshal_cmd_get(buf[CMD_VERSION_SIZE + 1:n], &dec)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, dec[0].policy, Mime_Policy(Exact_Mime(string(long[:]))))
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
    // One group whose policy tag is above EXACT_MIME_TAG. Group size depends on this byte, so it must be rejected
    // rather than defaulted -- otherwise the next group's filter is read as a mime length.
    msg: [10]byte
    msg[0] = 1 // group_count
    msg[9] = 99 // bogus policy tag
    dec: [MAX_REGS]Cmd_Get_Group
    _, err := unmarshal_cmd_get(msg[:], &dec)
    testing.expect(t, err != nil, "unknown policy tag should be rejected")
}

@(test)
test_unmarshal_cmd_get_rejects_truncated :: proc(t: ^testing.T) {
    buf: [MAX_MSG_SIZE]byte
    groups := [?]Cmd_Get_Group{{filter = CMD_GET_FILTER_ALL, policy = Exact_Mime("text/plain")}}
    n := marshal_cmd_get(groups[:], buf[:])
    dec: [MAX_REGS]Cmd_Get_Group

    // Chop the mime bytes: the declared length now exceeds what remains.
    _, err_mime := unmarshal_cmd_get(buf[CMD_VERSION_SIZE + 1:n - 4], &dec)
    testing.expect(t, err_mime != nil, "truncated mime should be rejected")

    // Chop mid-filter, before the policy byte is even reachable.
    _, err_filter := unmarshal_cmd_get(buf[CMD_VERSION_SIZE + 1:CMD_VERSION_SIZE + 6], &dec)
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

    m_plain := [?]string{"text/plain"}
    m_html := [?]string{"text/html"}
    b_first := [?]Data_Repr{data_repr_of("first", m_plain[:])}
    b_second := [?]Data_Repr{data_repr_of("second entry", m_html[:])}
    b_third := [?]Data_Repr{data_repr_of("third", m_plain[:])}

    regs: [MAX_REGS]Reg_Entry
    regs[clip0] = Reg_Entry {
        reprs     = b_first[:],
        timestamp = 1000,
    }
    regs[named3] = Reg_Entry {
        reprs     = b_second[:],
        timestamp = 2000,
    }
    regs[primary2] = Reg_Entry {
        reprs     = b_third[:],
        timestamp = 3000,
    }

    // marshal takes an array of pointers (borrows into the store); build one over `regs`.
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[clip0] = &regs[clip0]
    reg_ptrs[named3] = &regs[named3]
    reg_ptrs[primary2] = &regs[primary2]

    policies: [MAX_REGS]Mime_Policy // TEXTUAL is the zero value of the union's first variant
    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok, "response should fit")
    testing.expect(t, n > 0)
    testing.expect_value(t, Resp_Status(buf[0]), Resp_Status.REGISTERS)
    testing.expect_value(t, buf[1], u8(3))

    dec: [MAX_REGS]Resp_Reg
    defer for &reg in dec {free_resp_reg(&reg)}
    count, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)
    testing.expect_value(t, count, 3)

    // Entries land at their original Reg_Id slots, with the chosen repr's bytes in reprs[0].
    for id in ([]Reg_Id{clip0, named3, primary2}) {
        testing.expect_value(t, dec[id].timestamp, regs[id].timestamp)
        testing.expect_value(t, len(dec[id].reprs), 1)
        testing.expect_value(t, dec[id].selected, 0)
        testing.expect_value(t, dec[id].reprs[0].mimes[0], regs[id].reprs[0].mimes[0])
        testing.expect_value(t, dec[id].reprs[0].size, u64(len(regs[id].reprs[0].data)))
        testing.expect(t, slice.equal(dec[id].data, regs[id].reprs[0].data))
    }
}

@(test)
test_resp_registers_sent_mime_in_own_slot :: proc(t: ^testing.T) {
    // VISUAL picks the png at index 1, so it must be written first: `reprs[0]` is the one `data` belongs to, and the
    // client should never have to search for the repr with non-empty data.
    buf: [1024]byte
    m_html := [?]string{"text/html"}
    m_png := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("<p>hi</p>", m_html[:]), data_repr_of("PNGDATA", m_png[:])}
    entry := Reg_Entry {
        reprs     = reprs[:],
        timestamp = 42,
    }

    id := reg_id_from_named_index(0)
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[id] = &entry
    policies: [MAX_REGS]Mime_Policy
    policies[id] = Ranked_Policy.VISUAL

    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok)

    dec: [MAX_REGS]Resp_Reg
    defer for &r in dec {free_resp_reg(&r)}
    _, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)

    // Both reprs are described in their original order; `selected` names the one whose bytes travelled.
    testing.expect_value(t, len(dec[id].reprs), 2)
    testing.expect_value(t, dec[id].selected, 1)
    testing.expect_value(t, dec[id].reprs[1].mimes[0], "image/png")
    testing.expect_value(t, string(dec[id].data), "PNGDATA")
    // The unsent repr still carries its name and its size, which is the point of describing every repr.
    testing.expect_value(t, dec[id].reprs[0].mimes[0], "text/html")
    testing.expect_value(t, dec[id].reprs[0].size, u64(len("<p>hi</p>")))
}

@(test)
test_resp_registers_mime_preview_when_nothing_matched :: proc(t: ^testing.T) {
    // A PNG-only register under TEXTUAL: no bytes, but the mime still travels so the caller knows `image/png` is
    // there to request. Without that the client could not distinguish this from an empty register.
    buf: [1024]byte
    m_png := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("PNGDATA", m_png[:])}
    entry := Reg_Entry {
        reprs     = reprs[:],
        timestamp = 7,
    }

    id := reg_id_from_named_index(1)
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[id] = &entry
    policies: [MAX_REGS]Mime_Policy // TEXTUAL

    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok)

    dec: [MAX_REGS]Resp_Reg
    defer for &r in dec {free_resp_reg(&r)}
    count, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)
    testing.expect_value(t, count, 1)
    // Nothing was selected, but the repr is still fully described -- name, size, and dimensions if readable -- which is
    // what lets a client show the register instead of rendering it as empty.
    testing.expect(t, resp_reg_selected(dec[id]) == nil, "nothing should be selected")
    testing.expect_value(t, len(dec[id].data), 0)
    testing.expect_value(t, len(dec[id].reprs), 1)
    testing.expect_value(t, dec[id].reprs[0].mimes[0], "image/png")
    testing.expect_value(t, dec[id].reprs[0].size, u64(len("PNGDATA")))
}

@(test)
test_resp_registers_all_mimes_travel :: proc(t: ^testing.T) {
    // Every repr's every mime name reaches the client -- that is what the GUI's per-mime picker is built from.
    buf: [1024]byte
    m_text := [?]string{"text/plain;charset=utf-8", "text/plain", "STRING"}
    m_png := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("hi", m_text[:]), data_repr_of("PNGDATA", m_png[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    id := reg_id_from_named_index(2)
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[id] = &entry
    policies: [MAX_REGS]Mime_Policy // TEXTUAL picks the text repr

    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok)

    dec: [MAX_REGS]Resp_Reg
    defer for &r in dec {free_resp_reg(&r)}
    _, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)

    // Grouping survives the wire: the three text names stay together under one repr, so a client can tell they share a
    // payload and need not re-request to switch between them. The flat list this replaced could not express that.
    testing.expect_value(t, len(dec[id].reprs), 2)
    testing.expect_value(t, dec[id].selected, 0)
    testing.expect_value(t, string(dec[id].data), "hi")
    testing.expect_value(t, len(dec[id].reprs[0].mimes), 3)
    testing.expect_value(t, dec[id].reprs[0].mimes[0], "text/plain;charset=utf-8")
    testing.expect_value(t, dec[id].reprs[0].mimes[1], "text/plain")
    testing.expect_value(t, dec[id].reprs[0].mimes[2], "STRING")
    testing.expect_value(t, len(dec[id].reprs[1].mimes), 1)
    testing.expect_value(t, dec[id].reprs[1].mimes[0], "image/png")
    testing.expect_value(t, dec[id].reprs[1].size, u64(len("PNGDATA")))
}

@(test)
test_marshal_resp_registers_rejects_oversize :: proc(t: ^testing.T) {
    // Too small to hold the entry: refuse rather than truncate, since `data len` would otherwise lie about how much
    // followed and the client could not tell a fragment from a whole repr.
    small: [16]byte
    m_plain := [?]string{"text/plain"}
    reprs := [?]Data_Repr{data_repr_of("some data that will not fit", m_plain[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[reg_id_from_named_index(0)] = &entry
    policies: [MAX_REGS]Mime_Policy

    _, ok := marshal_resp_registers(reg_ptrs, policies, small[:])
    testing.expect(t, !ok, "oversize response should be rejected")
}

@(test)
test_unmarshal_resp_registers_rejects_malformed :: proc(t: ^testing.T) {
    dec: [MAX_REGS]Resp_Reg

    _, err_empty := unmarshal_resp_registers([]byte{}, &dec)
    testing.expect(t, err_empty != nil, "empty buffer should be rejected")

    _, err_count := unmarshal_resp_registers([]byte{MAX_REGS + 1}, &dec)
    testing.expect(t, err_count != nil, "entry count above MAX_REGS should be rejected")

    // count=1 then a header that runs off the end
    _, err_trunc := unmarshal_resp_registers([]byte{1, 0, 0, 0}, &dec)
    testing.expect(t, err_trunc != nil, "truncated entry header should be rejected")

    // count=1, reg_id=200 (invalid) -- would write past a [MAX_REGS] array
    bad_id := [?]byte{1, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0}
    _, err_id := unmarshal_resp_registers(bad_id[:], &dec)
    testing.expect(t, err_id != nil, "invalid register id should be rejected")
}

@(test)
test_reg_id_to_string :: proc(t: ^testing.T) {
    testing.expect_value(t, reg_id_to_string(reg_id_from_clipboard_index(0)), "0")
    testing.expect_value(t, reg_id_to_string(reg_id_from_clipboard_index(9)), "9")
    testing.expect_value(t, reg_id_to_string(reg_id_from_named_index(0)), "a")
    testing.expect_value(t, reg_id_to_string(reg_id_from_named_index(25)), "z")
    testing.expect_value(t, reg_id_to_string(reg_id_from_primary_index(0)), "@0")
    testing.expect_value(t, reg_id_to_string(reg_id_from_primary_index(9)), "@9")
    testing.expect_value(t, reg_id_to_string(SELECTION_CLIPBOARD), "selection")
    testing.expect_value(t, reg_id_to_string(SELECTION_PRIMARY), "@selection")
}

@(test)
test_marshal_cmd_set_reg_append :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(3)
    source := reg_id_from_clipboard_index(0)
    mode := Set_Mode.APPEND

    n := marshal_cmd_set_reg(dest, source, mode, buf[:])
    testing.expect_value(t, n, CMD_SET_REG_SIZE)
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    testing.expect_value(t, Command_Type(body[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(body[1]), dest)
    testing.expect_value(t, Set_Mode(body[2]), mode)
    testing.expect_value(t, Source_Kind(body[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(body[4]), source)
}

@(test)
test_unmarshal_cmd_set_reg :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(5)
    source := reg_id_from_primary_index(7)
    mode := Set_Mode.OVERWRITE

    marshal_cmd_set_reg(dest, source, mode, buf[:])
    decoded_source := unmarshal_cmd_set_reg(buf[CMD_VERSION_SIZE + CMD_SET_HEADER_SIZE:])
    testing.expect_value(t, decoded_source, source)
}

@(test)
test_marshal_unmarshal_cmd_clear :: proc(t: ^testing.T) {
    buf: [16]byte
    reg := reg_id_from_named_index(12)

    n := marshal_cmd_clear(reg, buf[:])
    testing.expect_value(t, n, CMD_CLEAR_SIZE)
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    testing.expect_value(t, Command_Type(buf[CMD_VERSION_SIZE]), Command_Type.CLEAR)

    decoded_reg := unmarshal_cmd_clear(buf[CMD_VERSION_SIZE + size_of(Command_Type):])
    testing.expect_value(t, decoded_reg, reg)
}

@(test)
test_marshal_cmd_shutdown :: proc(t: ^testing.T) {
    buf: [16]byte

    n := marshal_cmd_shutdown(buf[:])
    testing.expect_value(t, n, CMD_SHUTDOWN_SIZE)
    testing.expect_value(t, Monotonic_Version(buf[0]), PROTOCOL_VERSION)
    testing.expect_value(t, Command_Type(buf[CMD_VERSION_SIZE]), Command_Type.SHUTDOWN)
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
    mimes := []string{"text/plain"}
    data := []byte{}

    n := marshal_cmd_set_inline(dest, mode, mimes, data, buf[:])
    dec_mimes, dec_data, dec_err := unmarshal_cmd_set_inline(buf[CMD_VERSION_SIZE + CMD_SET_HEADER_SIZE:n])
    defer {
        for mime in dec_mimes {delete(mime)}
        delete(dec_mimes)
    }
    defer delete(dec_data)
    testing.expect_value(t, dec_err, nil)

    testing.expect_value(t, len(dec_mimes), 1)
    testing.expect_value(t, dec_mimes[0], mimes[0])
    testing.expect_value(t, len(dec_data), 0)
}

@(test)
test_marshal_unmarshal_cmd_set_inline_max_mime :: proc(t: ^testing.T) {
    buf: [512]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.OVERWRITE
    // `MAX_MIME_LEN` is the widest a single length byte can describe; both sides use `int` arithmetic now, so the
    // full 255 round-trips rather than wrapping.
    max_mime: [MAX_MIME_LEN]byte
    for &b in max_mime {b = 'x'}
    mimes := []string{string(max_mime[:])}
    data := transmute([]byte)string("test")

    n := marshal_cmd_set_inline(dest, mode, mimes, data, buf[:])
    dec_mimes, dec_data, dec_err := unmarshal_cmd_set_inline(buf[CMD_VERSION_SIZE + CMD_SET_HEADER_SIZE:n])
    defer {
        for mime in dec_mimes {delete(mime)}
        delete(dec_mimes)
    }
    defer delete(dec_data)
    testing.expect_value(t, dec_err, nil)

    testing.expect_value(t, len(dec_mimes), 1)
    testing.expect_value(t, dec_mimes[0], mimes[0])
    testing.expect(t, slice.equal(dec_data, data))
}

// resolve_repr tests. Entries are built by hand rather than through the register store so each case pins down one
// resolution rule in isolation.
//
// Mime name arrays are declared as named locals and sliced, never passed through a variadic: an `..string` parameter
// backs its slice with storage valid only for the duration of the call, so a `Data_Repr` built that way would hold a
// dangling `mimes` slice by the time the entry is used.
data_repr_of :: proc(data: string, mimes: []string) -> Data_Repr {
    return Data_Repr{data = transmute([]byte)data, mimes = mimes}
}

// resolve_repr returns (index, ok). These wrap the pair so each case reads as one assertion and a miss is checked as a
// miss rather than as a sentinel index.
expect_repr :: proc(t: ^testing.T, entry: ^Reg_Entry, policy: Mime_Policy, want: int, loc := #caller_location) {
    i, ok := resolve_repr(entry, policy)
    testing.expect(t, ok, "expected a repr to resolve", loc = loc)
    testing.expect_value(t, i, want, loc)
}

expect_no_repr :: proc(t: ^testing.T, entry: ^Reg_Entry, policy: Mime_Policy, loc := #caller_location) {
    _, ok := resolve_repr(entry, policy)
    testing.expect(t, !ok, "expected no repr to resolve", loc = loc)
}

@(test)
test_resolve_blob_ranked_beats_storage_order :: proc(t: ^testing.T) {
    // The ordering test: html is stored first, but VISUAL ranks images above markup. If the resolution loops were
    // inverted (reprs outer), this would return 0 -- and every single-repr test would still pass.
    html_mimes := [?]string{"text/html"}
    png_mimes := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("<p>hi</p>", html_mimes[:]), data_repr_of("\x89PNG", png_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.VISUAL, 1)
    // TEXTUAL excludes images entirely, so it takes the markup it can print.
    expect_repr(t, &entry, Ranked_Policy.TEXTUAL, 0)
}

@(test)
test_resolve_blob_both_policies_prefer_plain_over_markup :: proc(t: ^testing.T) {
    // The ghostty case: a terminal copy offers `text/html` alongside `text/plain`, holding the same content wrapped in
    // markup. *Both* policies must take the plain text -- markup is never the better answer for display when a
    // plain-text sibling exists. This previously asserted VISUAL took the markup, which encoded the bug.
    html_mimes := [?]string{"text/html"}
    plain_mimes := [?]string{"text/plain"}
    reprs := [?]Data_Repr{data_repr_of("<p>hi</p>", html_mimes[:]), data_repr_of("hi", plain_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.TEXTUAL, 1)
    expect_repr(t, &entry, Ranked_Policy.VISUAL, 1)
}

@(test)
test_resolve_blob_markup_is_the_last_resort :: proc(t: ^testing.T) {
    // Markup still resolves when it is all the register offers, under both policies -- demoting it must not make it
    // unreachable.
    html_mimes := [?]string{"text/html"}
    reprs := [?]Data_Repr{data_repr_of("<p>hi</p>", html_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.TEXTUAL, 0)
    expect_repr(t, &entry, Ranked_Policy.VISUAL, 0)
}

@(test)
test_resolve_blob_media_resolves_under_richest :: proc(t: ^testing.T) {
    // Audio and video are recognised by the magic table but had no ranking group, so a media-only register resolved to
    // nothing under every policy. VISUAL now ranks it; TEXTUAL still excludes it, as it does images.
    flac_mimes := [?]string{"audio/flac"}
    reprs := [?]Data_Repr{data_repr_of("fLaC", flac_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.VISUAL, 0)
    expect_no_repr(t, &entry, Ranked_Policy.TEXTUAL)
}

@(test)
test_resolve_blob_image_beats_media :: proc(t: ^testing.T) {
    flac_mimes := [?]string{"audio/flac"}
    png_mimes := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("fLaC", flac_mimes[:]), data_repr_of("\x89PNG", png_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.VISUAL, 1)
}

@(test)
test_resolve_blob_printable_empty_for_image_only :: proc(t: ^testing.T) {
    // A GIMP-style PNG-only register: TEXTUAL is a filter plus a ranking, so it legitimately matches nothing rather
    // than spraying binary into a terminal. VISUAL has no boundary and takes it.
    png_mimes := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("\x89PNG", png_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_no_repr(t, &entry, Ranked_Policy.TEXTUAL)
    expect_repr(t, &entry, Ranked_Policy.VISUAL, 0)
}

@(test)
test_resolve_blob_structured_only :: proc(t: ^testing.T) {
    // application/json has no text/plain form but is printable, so both policies must resolve it -- the case that would
    // return -1 if the structured category were missing from either policy.
    json_mimes := [?]string{"application/json"}
    reprs := [?]Data_Repr{data_repr_of(`{"a":1}`, json_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.TEXTUAL, 0)
    expect_repr(t, &entry, Ranked_Policy.VISUAL, 0)
}

@(test)
test_resolve_blob_app_private_never_wins_ranked :: proc(t: ^testing.T) {
    // Excluded by absence from every allowlist, not by a denylist predicate.
    chromium_mimes := [?]string{"chromium/x-web-custom-data"}
    moz_mimes := [?]string{"text/_moz_htmlcontext"}
    reprs := [?]Data_Repr{data_repr_of("junk", chromium_mimes[:]), data_repr_of("moz", moz_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_no_repr(t, &entry, Ranked_Policy.TEXTUAL)
    expect_no_repr(t, &entry, Ranked_Policy.VISUAL)

    // ...but an explicit request names the full string, so there is no accident to prevent.
    expect_repr(t, &entry, Exact_Mime("chromium/x-web-custom-data"), 0)
}

@(test)
test_resolve_blob_exact :: proc(t: ^testing.T) {
    plain_mimes := [?]string{"text/plain"}
    png_mimes := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("hi", plain_mimes[:]), data_repr_of("\x89PNG", png_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Exact_Mime("image/png"), 1)
    // An exact miss must not fall back: `+a=image/gif fmt=raw > out.gif` would otherwise write the wrong bytes.
    expect_no_repr(t, &entry, Exact_Mime("image/gif"))
}

@(test)
test_resolve_blob_matches_any_name_on_blob :: proc(t: ^testing.T) {
    // One byte stream, several names. Whichever name the policy hits first must resolve to the same repr.
    mimes := [?]string{"text/plain;charset=utf-8", "text/plain", "STRING"}
    reprs := [?]Data_Repr{data_repr_of("hi", mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_repr(t, &entry, Ranked_Policy.TEXTUAL, 0)
    expect_repr(t, &entry, Exact_Mime("STRING"), 0)
}

@(test)
test_resolve_blob_empty_entry :: proc(t: ^testing.T) {
    entry: Reg_Entry
    expect_no_repr(t, &entry, Ranked_Policy.TEXTUAL)
    expect_no_repr(t, &entry, Ranked_Policy.VISUAL)
    expect_no_repr(t, &entry, Exact_Mime("text/plain"))
}

@(test)
test_resolve_blob_svg_is_an_image_not_printable :: proc(t: ^testing.T) {
    // Deliberate: SVG source is text, but it is categorized as an image so a terminal gets a placeholder rather than
    // a screenful of XML. Documented on IMAGE_MIMES; this test is what fails if that decision is reversed.
    svg_mimes := [?]string{"image/svg+xml"}
    reprs := [?]Data_Repr{data_repr_of("<svg/>", svg_mimes[:])}
    entry := Reg_Entry {
        reprs = reprs[:],
    }

    expect_no_repr(t, &entry, Ranked_Policy.TEXTUAL)
    expect_repr(t, &entry, Ranked_Policy.VISUAL, 0)
}

@(test)
test_state_size_matches_marshal :: proc(t: ^testing.T) {
    // The whole point of `state_size` is that `save_registers_state` can allocate exactly enough, so an over- or
    // under-estimate is a bug even when the buffer happens to be big enough.
    m_text := [?]string{"text/plain", "text/plain;charset=utf-8"}
    m_png := [?]string{"image/png"}
    reprs := [?]Data_Repr{data_repr_of("hello", m_text[:]), data_repr_of("PNGDATA", m_png[:])}
    entry := Reg_Entry {
        reprs     = reprs[:],
        timestamp = 99,
    }

    regs: [MAX_REGS]^Reg_Entry
    regs[reg_id_from_named_index(0)] = &entry
    regs[reg_id_from_clipboard_index(3)] = &entry

    size := state_size(regs)
    buf := make([]u8, size)
    defer delete(buf)

    testing.expect_value(t, marshal_state(regs, buf), size)
}

@(test)
test_state_size_empty :: proc(t: ^testing.T) {
    regs: [MAX_REGS]^Reg_Entry
    testing.expect_value(t, state_size(regs), STATE_VERSION_SIZE + size_of(u8)) // version prefix + entry count
}

@(test)
test_unmarshal_cmd_set_inline_rejects_truncated :: proc(t: ^testing.T) {
    // Reachable from the daemon's reused `data_buf`: a short SET would otherwise read whatever the previous message left
    // behind, or slice past the end.
    _, _, err_empty := unmarshal_cmd_set_inline([]byte{})
    testing.expect(t, err_empty != nil, "empty buffer should be rejected")

    // Byte 0 is the mime *count*. Zero mimes leaves the payload unlabelled, which nothing downstream can resolve.
    no_mimes := [?]byte{0, 'h', 'i'}
    _, _, err_none := unmarshal_cmd_set_inline(no_mimes[:])
    testing.expect(t, err_none != nil, "zero mimes should be rejected")

    // count 1, then a mime length of 10 with only 3 bytes following
    short := [?]byte{1, 10, 'a', 'b', 'c'}
    _, _, err_short := unmarshal_cmd_set_inline(short[:])
    testing.expect(t, err_short != nil, "mime longer than the buffer should be rejected")

    // count 255 but only one mime present: the loop must fail on a later mime, not read past the end.
    over_count := [?]byte{255, 1, 'a'}
    _, _, err_count := unmarshal_cmd_set_inline(over_count[:])
    testing.expect(t, err_count != nil, "count exceeding the mimes present should be rejected")

    // A mime length of 255 with nothing after it: `int` arithmetic must catch this rather than wrapping.
    max_len := [?]byte{1, 255, 'a'}
    _, _, err_wrap := unmarshal_cmd_set_inline(max_len[:])
    testing.expect(t, err_wrap != nil, "over-long mime length should be rejected, not wrap")
}

// resolve_mimes tests. Pure byte inspection, so every case is a literal -- no compositor or filesystem needed, which
// is the point: this is the one part of the capture path that is cheap to pin down.

@(test)
test_resolve_mimes_binary_magics :: proc(t: ^testing.T) {
    png := [?]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0}
    testing.expect_value(t, resolve_mimes(png[:])[0], "image/png")

    jpeg := [?]byte{0xFF, 0xD8, 0xFF, 0xE0}
    testing.expect_value(t, resolve_mimes(jpeg[:])[0], "image/jpeg")

    gif := [?]byte{'G', 'I', 'F', '8', '9', 'a'}
    testing.expect_value(t, resolve_mimes(gif[:])[0], "image/gif")

    pdf := [?]byte{'%', 'P', 'D', 'F', '-', '1', '.', '4'}
    testing.expect_value(t, resolve_mimes(pdf[:])[0], "application/pdf")

    // Both TIFF byte orders are valid TIFF and share one mime.
    tiff_le := [?]byte{'I', 'I', '*', 0x00}
    tiff_be := [?]byte{'M', 'M', 0x00, '*'}
    testing.expect_value(t, resolve_mimes(tiff_le[:])[0], "image/tiff")
    testing.expect_value(t, resolve_mimes(tiff_be[:])[0], "image/tiff")
}

@(test)
test_resolve_mimes_rtf_is_also_plaintext :: proc(t: ^testing.T) {
    // RTF is ASCII, so it would satisfy the UTF-8 check too -- the magic must win, and both names must be claimed.
    rtf := transmute([]byte)string(`{\rtf1\ansi hello}`)
    mimes := resolve_mimes(rtf)
    testing.expect_value(t, len(mimes), 2)
    testing.expect_value(t, mimes[0], "application/rtf")
    testing.expect_value(t, mimes[1], "text/plain")
}

@(test)
test_resolve_mimes_text_and_binary_fallbacks :: proc(t: ^testing.T) {
    text := resolve_mimes(transmute([]byte)string("hello world"))
    testing.expect_value(t, len(text), 2)
    testing.expect_value(t, text[0], "text/plain;charset=utf-8")
    testing.expect_value(t, text[1], "text/plain")

    // Lone continuation byte: not valid UTF-8, matches no magic.
    binary := [?]byte{0x80, 0x01, 0x02}
    testing.expect_value(t, resolve_mimes(binary[:])[0], "application/octet-stream")
}

@(test)
test_resolve_mimes_short_input_does_not_panic :: proc(t: ^testing.T) {
    // Every magic is longer than these, and a clipboard holds two-byte selections routinely. An earlier version
    // sliced `data[:4]` unconditionally and panicked here.
    testing.expect_value(t, resolve_mimes([]byte{})[0], "text/plain;charset=utf-8")
    testing.expect_value(t, resolve_mimes(transmute([]byte)string("h"))[0], "text/plain;charset=utf-8")
    testing.expect_value(t, resolve_mimes(transmute([]byte)string("hi"))[0], "text/plain;charset=utf-8")

    // A prefix of a real magic must not match it.
    partial := [?]byte{0x89, 'P'}
    testing.expect_value(t, resolve_mimes(partial[:])[0], "application/octet-stream")
}

@(test)
test_resolve_mimes_containers :: proc(t: ^testing.T) {
    // RIFF: marker at 0, 4-byte size, form type at 8.
    webp := [?]byte{'R', 'I', 'F', 'F', 0x24, 0x01, 0, 0, 'W', 'E', 'B', 'P', 'V', 'P', '8', ' '}
    testing.expect_value(t, resolve_mimes(webp[:])[0], "image/webp")

    wav := [?]byte{'R', 'I', 'F', 'F', 0x24, 0x01, 0, 0, 'W', 'A', 'V', 'E'}
    testing.expect_value(t, resolve_mimes(wav[:])[0], "audio/wav")

    // ISO-BMFF: 4-byte box size first, so the marker sits at offset 4 and the brand at 8.
    avif := [?]byte{0, 0, 0, 0x1C, 'f', 't', 'y', 'p', 'a', 'v', 'i', 'f', 0, 0, 0, 0}
    testing.expect_value(t, resolve_mimes(avif[:])[0], "image/avif")

    mp4 := [?]byte{0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm'}
    testing.expect_value(t, resolve_mimes(mp4[:])[0], "video/mp4")
}

@(test)
test_resolve_mimes_container_edge_cases :: proc(t: ^testing.T) {
    // These all fall through the container check. They then land on `text/plain` rather than octet-stream because
    // NUL is valid UTF-8, so the bytes are technically valid text -- what matters is that no container mime is
    // claimed and the result is never the empty "nothing matched" sentinel.
    not_a_container :: proc(t: ^testing.T, data: []byte, why: string, loc := #caller_location) {
        mimes := resolve_mimes(data)
        testing.expect(t, len(mimes) > 0, why, loc = loc)
        for mime in mimes {
            testing.expect(t, mime != "", "a resolved mime must never be empty", loc = loc)
            testing.expect(t, mime != "image/webp" && mime != "audio/wav", why, loc = loc)
        }
    }

    // The marker must not be a candidate for its own discriminator: `RIFF....RIFF` once returned ok with an empty
    // mime, which would have stored a register labelled with the "nothing matched" sentinel.
    nested := [?]byte{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'R', 'I', 'F', 'F'}
    not_a_container(t, nested[:], "RIFF as its own form type must not resolve as a container")

    // Truncated mid-discriminator: 10 bytes, so the form type at 8..12 is not fully present.
    truncated := [?]byte{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E'}
    not_a_container(t, truncated[:], "a truncated form type must not match")

    // A RIFF container of an unknown form type falls through rather than guessing.
    unknown := [?]byte{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'Z', 'Z', 'Z', 'Z'}
    not_a_container(t, unknown[:], "an unknown form type must not match")
}

@(test)
test_resolve_mimes_result_is_borrowed_not_owned :: proc(t: ^testing.T) {
    // The contract is that results point into `.rodata`, so repeated calls hand back the identical backing array.
    // If this ever starts allocating, callers that only clone the strings would leak the slice.
    a := resolve_mimes(transmute([]byte)string("hello"))
    b := resolve_mimes(transmute([]byte)string("world"))
    testing.expect(t, raw_data(a) == raw_data(b), "plaintext results should share static storage")
}

// Table-level invariants. These walk the tables themselves rather than hand-picked inputs, so a newly added entry is
// covered without anyone remembering to write a case for it.

@(test)
test_magic_table_invariants :: proc(t: ^testing.T) {
    check :: proc(t: ^testing.T, m: Magic, what: string, loc := #caller_location) {
        testing.expect(t, len(m.bytes) > 0, "a magic with no bytes matches everything", loc = loc)
        testing.expect(t, len(m.mimes) > 0, "a magic must name at least one mime", loc = loc)
        for mime in m.mimes {
            // `""` is the "nothing matched" sentinel in `Resp_Reg`, so it must never reach a register as a label.
            testing.expect(t, mime != "", "a magic's mimes must never be empty", loc = loc)
        }
    }

    for m in MAGICS {check(t, m, "MAGICS")}

    // A container's discriminators are compared with `slice.equal` against exactly `magic_size` bytes, so an entry of
    // any other length can never match -- a mistake the compiler cannot catch.
    for container in ([?]Container_Magic{RIFF_CONTAINER, FTYP_CONTAINER}) {
        for m in container.magics {
            check(t, m, "container")
            testing.expect_value(t, len(m.bytes), container.magic_size)
        }
    }
}

@(test)
test_magic_table_no_shadowing :: proc(t: ^testing.T) {
    // Order in `MAGICS` is precedence, so an earlier entry that is a prefix of a later one makes the later one
    // unreachable. Only that direction shadows: a later, shorter entry still wins for input too short to match the
    // earlier, longer one.
    for earlier, i in MAGICS {
        for later in MAGICS[i + 1:] {
            testing.expect(
                t,
                !slice.has_prefix(later.bytes, earlier.bytes),
                fmt.tprintf("`%v` shadows the later `%v`", earlier.mimes[0], later.mimes[0]),
            )
        }
    }
}

@(test)
test_resolve_mimes_every_magic_self_matches :: proc(t: ^testing.T) {
    // Feeding an entry's own signature back in must yield that entry's mimes. Catches a transcription error in any
    // byte literal, including the entries no hand-written case above exercises.
    for m in MAGICS {
        got := resolve_mimes(m.bytes)
        testing.expect(
            t,
            slice.equal(got, m.mimes),
            fmt.tprintf("`%v` did not resolve to itself, got `%v`", m.mimes, got),
        )
    }
}

// unmarshal_state hardening. The state file is untrusted input e.g. hand-written, truncated by a crash mid-save, left
// over from an older format, or crafted by another local user if the state directory is ever reachable.

// Round-trip a single entry so the tests below can truncate and corrupt a *valid* encoding rather than a guess at one.
state_fixture :: proc(buf: []byte) -> int {
    data := transmute([]byte)string("hello")
    mimes := []string{"text/plain"}
    reprs := []Data_Repr{{data = data, mimes = mimes}}
    entry := Reg_Entry {
        reprs     = reprs,
        timestamp = 1234,
    }
    regs: [MAX_REGS]^Reg_Entry
    regs[reg_id_from_named_index(0)] = &entry
    return marshal_state(regs, buf)
}

@(test)
test_unmarshal_state_round_trips :: proc(t: ^testing.T) {
    buf: [256]byte
    n := state_fixture(buf[:])

    dec: [MAX_REGS]Reg_Entry
    count, err := unmarshal_state(buf[:n], &dec)
    defer for &entry in dec {free_reg_entry(&entry)}
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)

    entry := dec[reg_id_from_named_index(0)]
    testing.expect_value(t, entry.timestamp, 1234)
    testing.expect_value(t, len(entry.reprs), 1)
    testing.expect_value(t, string(entry.reprs[0].data), "hello")
    testing.expect_value(t, entry.reprs[0].mimes[0], "text/plain")
}

@(test)
test_unmarshal_state_rejects_empty :: proc(t: ^testing.T) {
    // `buf[0]` read the count unconditionally, so an empty file panicked on daemon startup.
    dec: [MAX_REGS]Reg_Entry
    _, err := unmarshal_state([]byte{}, &dec)
    testing.expect(t, err != nil, "empty state file should be rejected")
}

@(test)
test_unmarshal_state_rejects_version_mismatch :: proc(t: ^testing.T) {
    // A file written by a different format version must be reported, not decoded at the wrong offsets. Every non-current
    // version is rejected, in both directions, so a downgrade is caught as well as an upgrade.
    buf: [256]byte
    n := state_fixture(buf[:])

    for v in 0 ..= int(max(u8)) {
        if Monotonic_Version(v) == STATE_VERSION {continue}
        buf[0] = u8(v)

        dec: [MAX_REGS]Reg_Entry
        count, err := unmarshal_state(buf[:n], &dec)
        for &entry in dec {free_reg_entry(&entry)}
        testing.expect(t, err != nil, fmt.tprintf("state version %d should be rejected", v))
        testing.expect_value(t, count, 0)
    }
}

@(test)
test_unmarshal_state_accepts_current_version :: proc(t: ^testing.T) {
    // Guards the pairing: `marshal_state` must write exactly the byte `unmarshal_state` demands, so a bump to one
    // without the other fails here rather than at runtime.
    buf: [256]byte
    n := state_fixture(buf[:])
    testing.expect_value(t, Monotonic_Version(buf[0]), STATE_VERSION)

    dec: [MAX_REGS]Reg_Entry
    count, err := unmarshal_state(buf[:n], &dec)
    defer for &entry in dec {free_reg_entry(&entry)}
    testing.expect_value(t, err, nil)
    testing.expect_value(t, count, 1)
}

@(test)
test_marshal_cmds_all_carry_protocol_version :: proc(t: ^testing.T) {
    // Every command must be prefixed, not just the ones with dedicated round-trip tests: a marshal proc that forgets the
    // prefix sends a body byte as the version and gets the whole message rejected.
    dest := reg_id_from_named_index(0)
    source := reg_id_from_named_index(1)
    groups := []Cmd_Get_Group{{filter = CMD_GET_FILTER_NAMED, policy = Ranked_Policy.TEXTUAL}}

    buf: [MAX_MSG_SIZE]byte
    check :: proc(t: ^testing.T, buf: []byte, n: int, name: string) {
        testing.expectf(t, n > CMD_VERSION_SIZE, "%s: %d bytes is prefix-only", name, n)
        testing.expectf(
            t,
            Monotonic_Version(buf[0]) == PROTOCOL_VERSION,
            "%s: prefix is %d, expected %d",
            name,
            buf[0],
            PROTOCOL_VERSION,
        )
    }

    check(t, buf[:], marshal_cmd_set_reg(dest, source, .OVERWRITE, buf[:]), "SET (REGISTER)")
    check(t, buf[:], marshal_cmd_set_inline(dest, .OVERWRITE, []string{"text/plain"}, {'x'}, buf[:]), "SET (INLINE)")
    check(t, buf[:], marshal_cmd_get(groups, buf[:]), "GET")
    check(t, buf[:], marshal_cmd_clear(dest, buf[:]), "CLEAR")
    check(t, buf[:], marshal_cmd_shutdown(buf[:]), "SHUTDOWN")
}

@(test)
test_unmarshal_state_rejects_truncation_at_every_offset :: proc(t: ^testing.T) {
    // A crash mid-save leaves a prefix of a valid file, so every prefix must be rejected rather than crash. Exhaustive
    // because each truncation point exercises a different bounds check.
    buf: [256]byte
    n := state_fixture(buf[:])

    for cut in 1 ..< n {
        dec: [MAX_REGS]Reg_Entry
        _, err := unmarshal_state(buf[:cut], &dec)
        for &entry in dec {free_reg_entry(&entry)}
        testing.expect(t, err != nil, fmt.tprintf("truncation to %d of %d bytes should be rejected", cut, n))
    }
}

@(test)
test_unmarshal_state_rejects_invalid_reg_id :: proc(t: ^testing.T) {
    // `regs[reg_id]` indexed a fixed array with a byte straight from the file: 200 is past `MAX_REGS`.
    buf: [256]byte
    n := state_fixture(buf[:])
    buf[STATE_VERSION_SIZE + 1] = 200

    dec: [MAX_REGS]Reg_Entry
    _, err := unmarshal_state(buf[:n], &dec)
    for &entry in dec {free_reg_entry(&entry)}
    testing.expect(t, err != nil, "out-of-range register id should be rejected")
}

@(test)
test_unmarshal_state_rejects_oversized_data_len :: proc(t: ^testing.T) {
    // The case that motivated `int` arithmetic: a `data_len` of 0xFFFFFFFF must be caught by the bounds check rather
    // than wrapping it.
    buf: [256]byte
    n := state_fixture(buf[:])

    // Walk to the u32 data length: count + reg_id + timestamp + blob_count + mime_count + [len]"text/plain"
    data_len_at := STATE_VERSION_SIZE + 1 + 1 + size_of(i64) + 1 + 1 + 1 + len("text/plain")
    for i in 0 ..< size_of(u32) {buf[data_len_at + i] = 0xFF}

    dec: [MAX_REGS]Reg_Entry
    _, err := unmarshal_state(buf[:n], &dec)
    for &entry in dec {free_reg_entry(&entry)}
    testing.expect(t, err != nil, "data length beyond the buffer should be rejected")
}

@(test)
test_unmarshal_state_rejects_zero_mimes :: proc(t: ^testing.T) {
    // A repr with no mime cannot be resolved by anything downstream, and `mimes[0]` uses would panic on it.
    buf: [256]byte
    n := state_fixture(buf[:])
    mime_count_at := STATE_VERSION_SIZE + 1 + 1 + size_of(i64) + 1
    buf[mime_count_at] = 0

    dec: [MAX_REGS]Reg_Entry
    _, err := unmarshal_state(buf[:n], &dec)
    for &entry in dec {free_reg_entry(&entry)}
    testing.expect(t, err != nil, "a repr with zero mimes should be rejected")
}

@(test)
test_unmarshal_state_zeroes_regs_on_error :: proc(t: ^testing.T) {
    // The contract the caller relies on: a failed parse leaves nothing partially restored, so `main` can log and
    // continue with empty history rather than having to unpick a half-filled array.
    buf: [256]byte
    n := state_fixture(buf[:])

    dec: [MAX_REGS]Reg_Entry
    count, err := unmarshal_state(buf[:n - 1], &dec)
    testing.expect(t, err != nil)
    testing.expect_value(t, count, 0)
    for entry in dec {
        testing.expect_value(t, len(entry.reprs), 0)
    }
}

@(test)
test_marshal_state_clamps_over_long_mime :: proc(t: ^testing.T) {
    // `u8(len(mime))` wrapped a 256-byte name to 0, which wrote the bytes with a length of zero and desynced every
    // later field -- producing a file that then failed to parse. Clamping keeps the encoding self-consistent.
    long: [MAX_MIME_LEN + 1]byte
    for &c in long {c = 'x'}

    data := transmute([]byte)string("x")
    mimes := []string{string(long[:])}
    reprs := []Data_Repr{{data = data, mimes = mimes}}
    entry := Reg_Entry {
        reprs     = reprs,
        timestamp = 1,
    }
    regs: [MAX_REGS]^Reg_Entry
    regs[reg_id_from_named_index(0)] = &entry

    buf := make([]byte, state_size(regs))
    defer delete(buf)
    n := marshal_state(regs, buf)

    dec: [MAX_REGS]Reg_Entry
    _, err := unmarshal_state(buf[:n], &dec)
    defer for &e in dec {free_reg_entry(&e)}
    testing.expect_value(t, err, nil)
    testing.expect_value(t, len(dec[reg_id_from_named_index(0)].reprs[0].mimes[0]), MAX_MIME_LEN)
}

// Text sniffing. These formats have no byte signature, so they are recognised from opening markup -- and every result
// keeps `text/plain` at the end, so nothing a sniffer catches becomes *less* reachable than before.

sniffed :: proc(t: ^testing.T, text: string, want: string, loc := #caller_location) {
    mimes := resolve_mimes(transmute([]byte)text)
    testing.expect(t, len(mimes) > 0, "should resolve to something", loc = loc)
    testing.expect_value(t, mimes[0], want, loc = loc)
    // Every text result stays plaintext-reachable, so `get +a` never regresses to `[no printable mime]`.
    testing.expect_value(t, mimes[len(mimes) - 1], "text/plain", loc = loc)
}

@(test)
test_sniff_xml :: proc(t: ^testing.T) {
    sniffed(t, `<?xml version="1.0"?><root><a/></root>`, "application/xml")
}

@(test)
test_sniff_svg :: proc(t: ^testing.T) {
    // Both shapes: the root element directly, and behind an XML declaration.
    sniffed(t, `<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>`, "image/svg+xml")
    sniffed(t, `<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>`, "image/svg+xml")

    // SVG must beat XML: an SVG opens with `<?xml`, so testing XML first would classify it as plain XML and it would
    // never rank as an image under the VISUAL policy, which is the whole reason SVG sniffing is worth having.
    mimes := resolve_mimes(transmute([]byte)string(`<?xml version="1.0"?><svg/>`))
    testing.expect_value(t, mimes[0], "image/svg+xml")
    testing.expect_value(t, mimes[1], "application/xml")
}

@(test)
test_sniff_html :: proc(t: ^testing.T) {
    sniffed(t, "<!DOCTYPE html><html><body>hi</body></html>", "text/html")
    sniffed(t, "<html><body>hi</body></html>", "text/html")
    sniffed(t, "<head><title>x</title></head>", "text/html")
    // Case-insensitive, and leading whitespace must not defeat the prefix test.
    sniffed(t, "\n  <HTML><BODY>hi</BODY></HTML>", "text/html")
}

@(test)
test_sniff_json :: proc(t: ^testing.T) {
    sniffed(t, `{"a": 1, "b": [2, 3]}`, "application/json")
    sniffed(t, `[1, 2, 3]`, "application/json")
    sniffed(t, "  \n{\"nested\": {\"x\": null}}", "application/json")
}

@(test)
test_sniff_json_requires_validation_not_just_a_brace :: proc(t: ^testing.T) {
    // `{` alone is not evidence -- shell snippets, code, and prose all start with braces. The cheap first-byte gate
    // only decides whether to *attempt* a parse; the parse decides the answer.
    for text in ([]string{"{not json at all", "{ foo bar }", "[unclosed", "{"}) {
        mimes := resolve_mimes(transmute([]byte)text)
        testing.expect_value(t, mimes[0], "text/plain;charset=utf-8")
    }
}

@(test)
test_sniff_falls_through_to_plaintext :: proc(t: ^testing.T) {
    // Markdown is deliberately unsniffable (all plain text is valid markdown), and prose containing angle brackets or
    // commas must not be mistaken for markup or CSV.
    for text in ([]string {
            "# A heading\n\nsome *markdown* text",
            "plain old prose",
            "a, b, c\n1, 2, 3",
            "x < y and y > z",
            "",
        }) {
        mimes := resolve_mimes(transmute([]byte)text)
        testing.expect_value(t, mimes[0], "text/plain;charset=utf-8")
        testing.expect_value(t, len(mimes), 2)
    }
}

@(test)
test_sniff_does_not_run_on_binary :: proc(t: ^testing.T) {
    // Sniffing happens only after `utf8.valid_string`, so a payload that merely *starts* with markup but is not valid
    // UTF-8 stays octet-stream rather than being labelled text.
    data := [?]byte{'<', 'h', 't', 'm', 'l', '>', 0x80, 0xFF}
    testing.expect_value(t, resolve_mimes(data[:])[0], "application/octet-stream")
}

@(test)
test_sniff_loses_to_magic_bytes :: proc(t: ^testing.T) {
    // RTF is ASCII and would satisfy the UTF-8 check, but `MAGICS` runs first, so its specific mime wins.
    rtf := resolve_mimes(transmute([]byte)string(`{\rtf1\ansi hello}`))
    testing.expect_value(t, rtf[0], "application/rtf")
}

@(test)
test_sniff_window_is_bounded :: proc(t: ^testing.T) {
    // `<svg` past the window is not found: scanning a whole multi-megabyte document for a marker that only ever appears
    // near the front would make every large text paste pay for it.
    padding := make([]byte, SNIFF_WINDOW + 64)
    defer delete(padding)
    for &b in padding {b = ' '}

    far := fmt.tprintf("<?xml version=\"1.0\"?>%s<svg/>", string(padding))
    mimes := resolve_mimes(transmute([]byte)far)
    testing.expect_value(t, mimes[0], "application/xml") // XML, not SVG
}

// `image_dimensions`. Every format stores them at a different offset in a different width and endianness, so each needs
// its own case -- and a short buffer must report nothing rather than read past the end, since the magic table matches a
// 4-byte prefix and a register can be labelled `image/png` with fewer bytes than an IHDR needs.

@(test)
test_image_dimensions_png :: proc(t: ^testing.T) {
    // 8B signature, then [4B len][4B "IHDR"][4B width BE][4B height BE]
    data: [26]byte
    copy(data[:], []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})
    copy(data[8:], []byte{0, 0, 0, 13, 'I', 'H', 'D', 'R'})
    copy(data[16:], []byte{0x00, 0x00, 0x02, 0x58}) // 600
    copy(data[20:], []byte{0x00, 0x00, 0x01, 0x2c}) // 300
    dims, ok := image_dimensions(data[:], "image/png")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_gif :: proc(t: ^testing.T) {
    // "GIF89a" then width/height as little-endian u16
    data: [10]byte
    copy(data[:], []byte{'G', 'I', 'F', '8', '9', 'a', 0x58, 0x02, 0x2c, 0x01})
    dims, ok := image_dimensions(data[:], "image/gif")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_bmp_negative_height_is_top_down :: proc(t: ^testing.T) {
    // A negative height is legal and means the rows are stored top-down, so the magnitude is the dimension. Read as
    // unsigned it would come back as ~4 billion.
    data: [26]byte
    copy(data[:], []byte{'B', 'M'})
    copy(data[18:], []byte{0x58, 0x02, 0x00, 0x00}) // 600
    copy(data[22:], []byte{0xd4, 0xfe, 0xff, 0xff}) // -300
    dims, ok := image_dimensions(data[:], "image/bmp")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_qoi :: proc(t: ^testing.T) {
    data: [14]byte
    copy(data[:], []byte{'q', 'o', 'i', 'f'})
    copy(data[4:], []byte{0x00, 0x00, 0x02, 0x58})
    copy(data[8:], []byte{0x00, 0x00, 0x01, 0x2c})
    dims, ok := image_dimensions(data[:], "image/qoi")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_short_buffer_reports_nothing :: proc(t: ^testing.T) {
    // The case a real register hits: `printf '\x89PNG' > f` matches MAGIC_PNG but has no IHDR at all.
    four := [?]byte{0x89, 'P', 'N', 'G'}
    _, ok := image_dimensions(four[:], "image/png")
    testing.expect(t, !ok, "a 4-byte PNG has no IHDR and must report no dimensions")

    // Every truncation of a valid header must also be refused rather than read past the end.
    full: [26]byte
    copy(full[:], []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a})
    copy(full[16:], []byte{0x00, 0x00, 0x02, 0x58})
    copy(full[20:], []byte{0x00, 0x00, 0x01, 0x2c})
    for cut in 0 ..< 24 {
        _, cut_ok := image_dimensions(full[:cut], "image/png")
        testing.expectf(t, !cut_ok, "a %d-byte PNG must report no dimensions", cut)
    }

    _, empty_ok := image_dimensions({}, "image/png")
    testing.expect(t, !empty_ok, "an empty buffer must report no dimensions")
}

@(test)
test_image_dimensions_unknown_and_unparsed_formats :: proc(t: ^testing.T) {
    big: [64]byte
    _, text_ok := image_dimensions(big[:], "text/plain")
    testing.expect(t, !text_ok, "a non-image mime has no dimensions")
    // TIFF is tag/IFD based and the ISOBMFF formats need a box walk to reach `ispe`, so they report nothing rather than
    // guess. They are reachable mimes, so this is a deliberate gap and not an oversight.
    for mime in ([]string{"image/tiff", "image/jxl", "image/avif", "image/heic", "image/svg+xml"}) {
        _, ok := image_dimensions(big[:], mime)
        testing.expectf(t, !ok, "%s is not parsed and must report nothing rather than guess", mime)
    }
}

// JPEG: dimensions sit in a Start-Of-Frame segment at no fixed offset, so the walk has to skip whatever metadata
// precedes it. Validated against 40 real JPEGs on disk, all matching `file(1)`.

@(test)
test_image_dimensions_jpeg_skips_preceding_segments :: proc(t: ^testing.T) {
    // SOI, an APP0/JFIF segment, a DHT, then SOF0. DHT is 0xC4 -- inside the SOF marker range but not a frame header, so
    // a parser treating 0xC0-0xCF as contiguous reads its payload as dimensions and returns garbage.
    data := [?]byte {
        0xFF,
        0xD8, // SOI
        0xFF,
        0xE0,
        0x00,
        0x10, // APP0, length 16 (2 + 14 payload)
        'J',
        'F',
        'I',
        'F',
        0x00,
        0x01,
        0x02,
        0x00,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0xFF,
        0xC4,
        0x00,
        0x05, // DHT, length 5 (2 + 3 payload)
        0x00,
        0x00,
        0x00,
        0xFF,
        0xC0,
        0x00,
        0x11, // SOF0, length 17
        0x08, // precision
        0x01,
        0x2C, // height 300 -- height precedes width in SOF
        0x02,
        0x58, // width 600
        0x03, // components
        0x01,
        0x22,
        0x00,
        0x02,
        0x11,
        0x01,
        0x03,
        0x11,
        0x01,
    }
    dims, ok := image_dimensions(data[:], "image/jpeg")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_jpeg_progressive_sof2 :: proc(t: ^testing.T) {
    // SOF2 is progressive JPEG; the frame header layout is identical, so it must be accepted too.
    data := [?]byte {
        0xFF,
        0xD8,
        0xFF,
        0xC2,
        0x00,
        0x0B, // SOF2, length 11
        0x08,
        0x00,
        0x40,
        0x00,
        0x80,
        0x01,
        0x01,
        0x11,
        0x00,
    }
    dims, ok := image_dimensions(data[:], "image/jpeg")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(128))
    testing.expect_value(t, dims.height, u32(64))
}

@(test)
test_image_dimensions_jpeg_rejects_malformed :: proc(t: ^testing.T) {
    // No SOI
    not_jpeg := [?]byte{0x00, 0x01, 0x02, 0x03}
    _, ok1 := image_dimensions(not_jpeg[:], "image/jpeg")
    testing.expect(t, !ok1, "a buffer without SOI is not a JPEG")

    // SOI then a segment whose length cannot cover its own field, which would otherwise stall the walk
    bad_len := [?]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, 0x00, 0x00}
    _, ok2 := image_dimensions(bad_len[:], "image/jpeg")
    testing.expect(t, !ok2, "a segment length below 2 must be rejected")

    // SOI with no SOF anywhere: walks to the end and reports nothing instead of looping
    no_sof := [?]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9}
    _, ok3 := image_dimensions(no_sof[:], "image/jpeg")
    testing.expect(t, !ok3, "a JPEG with no frame header has no dimensions")

    // Every truncation of the valid fixture must be refused rather than read past the end
    full := [?]byte {
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x11,
        0x08,
        0x01,
        0x2C,
        0x02,
        0x58,
        0x03,
        0x01,
        0x22,
        0x00,
        0x02,
        0x11,
        0x01,
        0x03,
        0x11,
        0x01,
    }
    for cut in 0 ..< 11 {
        _, cut_ok := image_dimensions(full[:cut], "image/jpeg")
        testing.expectf(t, !cut_ok, "a %d-byte JPEG must report no dimensions", cut)
    }
}

// WebP: a RIFF container whose first chunk tag picks one of three encodings, none of which stores dimensions as a plain
// integer. VP8X is validated against real files; VP8 and VP8L are built from the spec here.

@(test)
test_image_dimensions_webp_vp8x :: proc(t: ^testing.T) {
    // Extended format: canvas dimensions are 24-bit little-endian and stored minus one.
    data := [?]byte {
        'R',
        'I',
        'F',
        'F',
        0x00,
        0x00,
        0x00,
        0x00,
        'W',
        'E',
        'B',
        'P',
        'V',
        'P',
        '8',
        'X',
        0x0A,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, // flags
        0x57,
        0x02,
        0x00, // width-1  = 599
        0x2B,
        0x01,
        0x00, // height-1 = 299
    }
    dims, ok := image_dimensions(data[:], "image/webp")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_webp_vp8_lossy :: proc(t: ^testing.T) {
    // Lossy: the top two bits of each 16-bit field are a scale factor, so they must be masked off.
    data := [?]byte {
        'R',
        'I',
        'F',
        'F',
        0x00,
        0x00,
        0x00,
        0x00,
        'W',
        'E',
        'B',
        'P',
        'V',
        'P',
        '8',
        ' ',
        0x0A,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, // frame tag
        0x9D,
        0x01,
        0x2A, // start code
        0x58,
        0xC2, // 600 with scale bits set in the top two
        0x2C,
        0x41, // 300 with a scale bit set
    }
    dims, ok := image_dimensions(data[:], "image/webp")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_webp_vp8l_lossless :: proc(t: ^testing.T) {
    // Lossless: 14 bits of width-1 then 14 bits of height-1, packed little-endian after a 0x2F signature.
    // 599 | (299 << 14) = 0x004AC257
    data := [?]byte {
        'R',
        'I',
        'F',
        'F',
        0x00,
        0x00,
        0x00,
        0x00,
        'W',
        'E',
        'B',
        'P',
        'V',
        'P',
        '8',
        'L',
        0x05,
        0x00,
        0x00,
        0x00,
        0x2F,
        0x57,
        0xC2,
        0x4A,
        0x00,
    }
    dims, ok := image_dimensions(data[:], "image/webp")
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_image_dimensions_webp_rejects_malformed :: proc(t: ^testing.T) {
    not_riff := [?]byte {
        'X',
        'X',
        'X',
        'X',
        0,
        0,
        0,
        0,
        'W',
        'E',
        'B',
        'P',
        'V',
        'P',
        '8',
        'X',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }
    _, ok1 := image_dimensions(not_riff[:], "image/webp")
    testing.expect(t, !ok1, "a non-RIFF container is not a WebP")

    unknown_chunk := [?]byte {
        'R',
        'I',
        'F',
        'F',
        0,
        0,
        0,
        0,
        'W',
        'E',
        'B',
        'P',
        'J',
        'U',
        'N',
        'K',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }
    _, ok2 := image_dimensions(unknown_chunk[:], "image/webp")
    testing.expect(t, !ok2, "an unrecognised first chunk yields no dimensions")

    short := [?]byte{'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B', 'P'}
    _, ok3 := image_dimensions(short[:], "image/webp")
    testing.expect(t, !ok3, "a header with no chunk payload yields no dimensions")
}

@(test)
test_qoi_magic_resolves :: proc(t: ^testing.T) {
    // The dimension reader is only reachable if the magic table can produce the mime in the first place.
    qoi := [?]byte{'q', 'o', 'i', 'f', 0x00, 0x00, 0x02, 0x58, 0x00, 0x00, 0x01, 0x2C, 0x04, 0x00}
    mimes := resolve_mimes(qoi[:])
    testing.expect(t, len(mimes) > 0, "qoif should match a magic")
    testing.expect_value(t, mimes[0], "image/qoi")
    dims, ok := image_dimensions(qoi[:], mimes[0])
    testing.expect(t, ok)
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

// `Repr_Meta` wire round trip.

@(test)
test_repr_meta_round_trips :: proc(t: ^testing.T) {
    buf: [32]byte
    n := write_repr_meta(buf[:], Image_Dims{600, 300})
    offset := 0
    meta, err := read_repr_meta(buf[:n], &offset)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, offset, n)
    dims, is_dims := meta.(Image_Dims)
    testing.expect(t, is_dims, "should decode as Image_Dims")
    testing.expect_value(t, dims.width, u32(600))
    testing.expect_value(t, dims.height, u32(300))
}

@(test)
test_repr_meta_none_round_trips :: proc(t: ^testing.T) {
    buf: [32]byte
    n := write_repr_meta(buf[:], nil)
    testing.expect_value(t, n, size_of(Repr_Meta_Tag) + size_of(u8))
    offset := 0
    meta, err := read_repr_meta(buf[:n], &offset)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, offset, n)
    testing.expect(t, meta == nil, "NONE should decode as no metadata")
}

@(test)
test_repr_meta_unknown_tag_is_skipped_not_fatal :: proc(t: ^testing.T) {
    // The reason the length byte exists: a tag a client does not know is stepped over, leaving the stream aligned for
    // whatever follows, rather than desyncing the rest of the entry.
    buf := [?]byte{200, 3, 0xAA, 0xBB, 0xCC, 'n', 'e', 'x', 't'}
    offset := 0
    meta, err := read_repr_meta(buf[:], &offset)
    testing.expect_value(t, err, nil)
    testing.expect(t, meta == nil, "an unknown tag yields no metadata")
    testing.expect_value(t, offset, 5)
    testing.expect_value(t, string(buf[offset:]), "next")
}

@(test)
test_repr_meta_rejects_truncation :: proc(t: ^testing.T) {
    buf: [32]byte
    n := write_repr_meta(buf[:], Image_Dims{1, 2})
    for cut in 0 ..< n {
        offset := 0
        _, err := read_repr_meta(buf[:cut], &offset)
        testing.expectf(t, err != nil, "a %d-byte meta field should be rejected", cut)
    }
}

@(test)
test_resp_registers_oversize_payload_degrades_to_descriptor :: proc(t: ^testing.T) {
    // The VISUAL-policy failure: a blob can exceed the response buffer on its own, and refusing the whole response left
    // the client with a zero-length message and no way to know why. The entry must still travel, described but
    // unselected, so it renders as `[image/png ...]` rather than vanishing.
    big := make([]byte, 4096)
    defer delete(big)
    m_png := [?]string{"image/png"}
    reprs := [?]Data_Repr{{data = big, mimes = m_png[:]}}
    entry := Reg_Entry {
        reprs     = reprs[:],
        timestamp = 11,
    }

    id := reg_id_from_named_index(0)
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[id] = &entry
    policies: [MAX_REGS]Mime_Policy
    policies[id] = Ranked_Policy.VISUAL

    // Room for the descriptors, nowhere near enough for the 4 KiB payload.
    buf: [128]byte
    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok, "descriptors alone fit, so the response should succeed")

    dec: [MAX_REGS]Resp_Reg
    defer for &r in dec {free_resp_reg(&r)}
    count, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)
    testing.expect_value(t, count, 1)

    testing.expect(t, resp_reg_selected(dec[id]) == nil, "payload did not fit, so nothing is selected")
    testing.expect_value(t, len(dec[id].data), 0)
    // The descriptor still reports the real size, so a client can say what it could not fetch.
    testing.expect_value(t, len(dec[id].reprs), 1)
    testing.expect_value(t, dec[id].reprs[0].mimes[0], "image/png")
    testing.expect_value(t, dec[id].reprs[0].size, u64(4096))
}

@(test)
test_resp_registers_oversize_payload_keeps_later_entries :: proc(t: ^testing.T) {
    // The symptom was total: one unfittable blob killed every register in the response. A small entry after a large one
    // must still arrive with its bytes.
    big := make([]byte, 4096)
    defer delete(big)
    small := transmute([]byte)string("hi")
    m_png := [?]string{"image/png"}
    m_txt := [?]string{"text/plain"}
    big_reprs := [?]Data_Repr{{data = big, mimes = m_png[:]}}
    small_reprs := [?]Data_Repr{{data = small, mimes = m_txt[:]}}
    big_entry := Reg_Entry {
        reprs = big_reprs[:],
    }
    small_entry := Reg_Entry {
        reprs = small_reprs[:],
    }

    big_id := reg_id_from_named_index(0)
    small_id := reg_id_from_named_index(1)
    reg_ptrs: [MAX_REGS]^Reg_Entry
    reg_ptrs[big_id] = &big_entry
    reg_ptrs[small_id] = &small_entry
    policies: [MAX_REGS]Mime_Policy
    policies[big_id] = Ranked_Policy.VISUAL
    policies[small_id] = Ranked_Policy.VISUAL

    buf: [256]byte
    n, ok := marshal_resp_registers(reg_ptrs, policies, buf[:])
    testing.expect(t, ok)

    dec: [MAX_REGS]Resp_Reg
    defer for &r in dec {free_resp_reg(&r)}
    count, derr := unmarshal_resp_registers(buf[1:n], &dec)
    testing.expect_value(t, derr, nil)
    testing.expect_value(t, count, 2)
    testing.expect(t, resp_reg_selected(dec[big_id]) == nil, "the oversize entry is described but unselected")
    testing.expect_value(t, string(dec[small_id].data), "hi")
}

// Every mime the magic table can emit is either rankable by a policy or deliberately not. This guards the gap that
// already bit twice: audio/video belonged to no group, and `image/avif`/`heic`/`jxl` were missing from `IMAGE_MIMES`,
// so a register holding one resolved to nothing under *every* policy.
//
// Archives and documents stay unrankable on purpose: there is no sensible display for a zip, and an unselected repr now
// renders as its descriptor (`[application/pdf 812 kiB]`) rather than as a blank row.
@(test)
test_every_detectable_image_and_media_mime_is_rankable :: proc(t: ^testing.T) {
    rankable :: proc(mime: string) -> bool {
        for group in ([][]string {
                IMAGE_MIMES[:],
                MEDIA_MIMES[:],
                URI_MIMES[:],
                TEXT_MIMES[:],
                STRUCTURED_MIMES[:],
                MARKUP_MIMES[:],
            }) {
            for m in group {
                if m == mime {return true}
            }
        }
        return false
    }

    check :: proc(t: ^testing.T, magics: []Magic, rankable: proc(_: string) -> bool, source: string) {
        for magic in magics {
            for mime in magic.mimes {
                is_visual :=
                    strings.has_prefix(mime, "image/") ||
                    strings.has_prefix(mime, "audio/") ||
                    strings.has_prefix(mime, "video/")
                if is_visual {
                    testing.expectf(t, rankable(mime), "%s (%s) is detectable but no policy can rank it", mime, source)
                }
            }
        }
    }

    check(t, MAGICS[:], rankable, "MAGICS")
    // Container magics are where this is most likely to go wrong: webp, wav, avi, avif and heic all live behind a RIFF
    // or ftyp marker rather than in the top-level table, so a check that only walked `MAGICS` would miss exactly the
    // mimes most prone to the gap. `image/avif` was in fact already missing when this test was first written.
    check(t, RIFF_CONTAINER.magics, rankable, "RIFF_CONTAINER")
    check(t, FTYP_CONTAINER.magics, rankable, "FTYP_CONTAINER")
}
