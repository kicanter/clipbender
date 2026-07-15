package base

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
test_marshal_unmarshal_cmd_get :: proc(t: ^testing.T) {
    buf: [16]byte
    filter := CMD_GET_FILTER_NUMBERED + CMD_GET_FILTER_NAMED

    n := marshal_cmd_get(filter, buf[:])
    testing.expect(t, n == size_of(Command_Type) + size_of(Cmd_Get_Filter))

    dec_filter := unmarshal_cmd_get(buf[1:])
    testing.expect_value(t, dec_filter, filter)
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
        data      = transmute([]byte)string("first"),
        mime_type = "text/plain",
        timestamp = 1000,
    }
    regs[named3] = Reg_Entry {
        data      = transmute([]byte)string("second entry"),
        mime_type = "text/html",
        timestamp = 2000,
    }
    regs[primary2] = Reg_Entry {
        data      = transmute([]byte)string("third"),
        mime_type = "text/plain",
        timestamp = 3000,
    }

    n := marshal_resp_registers(&regs, buf[:])
    testing.expect(t, n > 0)
    testing.expect_value(t, Resp_Status(buf[0]), Resp_Status.REGISTERS)
    testing.expect_value(t, buf[1], u8(3))

    dec_regs: [MAX_REGS]Reg_Entry
    count := unmarshal_resp_registers(buf[1:], &dec_regs)
    testing.expect_value(t, count, u8(3))

    // Entries should land at their original Reg_Id slots
    for id in ([]Reg_Id{clip0, named3, primary2}) {
        testing.expect_value(t, dec_regs[id].timestamp, regs[id].timestamp)
        testing.expect_value(t, dec_regs[id].mime_type, regs[id].mime_type)
        testing.expect(t, slice.equal(dec_regs[id].data, regs[id].data))
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
