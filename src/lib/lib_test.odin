package lib

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
    for i in u8(0) ..< 26 {
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
test_encode_cmd_set_reg :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(5)
    source := SELECTION_CLIPBOARD
    mode := Set_Mode.OVERWRITE

    n := encode_cmd_set_reg(dest, source, mode, buf[:])
    testing.expect_value(t, n, 5)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(buf[1]), dest)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(buf[4]), source)
}

@(test)
test_encode_decode_cmd_set_inline :: proc(t: ^testing.T) {
    buf: [256]byte
    dest := reg_id_from_named_index(0)
    mode := Set_Mode.APPEND
    mime := "text/plain"
    data := transmute([]byte)string("hello world")

    n := encode_cmd_set_inline(dest, mode, mime, data, buf[:])
    expected_size := size_of(Command_Type) + size_of(Reg_Id) + size_of(Set_Mode) + size_of(Source_Kind) + size_of(u8) + len(mime) + len(data)
    testing.expect_value(t, n, expected_size)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.INLINE)

    // decode_cmd_set_inline expects buf starting after Source_Kind byte
    dec_mime, dec_data := decode_cmd_set_inline(buf[4:n])
    defer delete(dec_mime)
    defer delete(dec_data)

    testing.expect_value(t, dec_mime, mime)
    testing.expect(t, slice.equal(dec_data, data))
}

@(test)
test_encode_decode_cmd_get :: proc(t: ^testing.T) {
    buf: [16]byte
    filter := CMD_GET_FILTER_CLIPBOARD + CMD_GET_FILTER_NAMED

    n := encode_cmd_get(filter, buf[:])
    testing.expect(t, n == size_of(Command_Type) + size_of(Cmd_Get_Filter))

    dec_filter := decode_cmd_get(buf[1:])
    testing.expect_value(t, dec_filter, filter)
}

@(test)
test_encode_decode_resp_data :: proc(t: ^testing.T) {
    buf: [1024]byte

    regs := []Resp_Reg{
        {id = reg_id_from_clipboard_index(0), entry = Reg_Entry{data = transmute([]byte)string("first"), mime_type = "text/plain", timestamp = 1000}},
        {id = reg_id_from_named_index(3), entry = Reg_Entry{data = transmute([]byte)string("second entry"), mime_type = "text/html", timestamp = 2000}},
        {id = reg_id_from_primary_index(2), entry = Reg_Entry{data = transmute([]byte)string("third"), mime_type = "text/plain", timestamp = 3000}},
    }

    n := encode_resp_data(regs, buf[:])
    testing.expect(t, n > 0)
    testing.expect_value(t, Resp_Status(buf[0]), Resp_Status.DATA)
    testing.expect_value(t, buf[1], u8(3))

    dec_regs: [46]Resp_Reg
    count := decode_resp_data(buf[1:], &dec_regs)
    testing.expect_value(t, count, u8(3))

    for i in 0 ..< int(count) {
        testing.expect_value(t, dec_regs[i].id, regs[i].id)
        testing.expect_value(t, dec_regs[i].entry.timestamp, regs[i].entry.timestamp)
        testing.expect_value(t, dec_regs[i].entry.mime_type, regs[i].entry.mime_type)
        testing.expect(t, slice.equal(dec_regs[i].entry.data, regs[i].entry.data))
    }

    for i in 0 ..< int(count) {
        free_reg_entry(&dec_regs[i].entry)
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
test_encode_cmd_set_reg_append :: proc(t: ^testing.T) {
    buf: [64]byte
    dest := reg_id_from_named_index(3)
    source := reg_id_from_clipboard_index(0)
    mode := Set_Mode.APPEND

    n := encode_cmd_set_reg(dest, source, mode, buf[:])
    testing.expect_value(t, n, 5)
    testing.expect_value(t, Command_Type(buf[0]), Command_Type.SET)
    testing.expect_value(t, Reg_Id(buf[1]), dest)
    testing.expect_value(t, Set_Mode(buf[2]), mode)
    testing.expect_value(t, Source_Kind(buf[3]), Source_Kind.REGISTER)
    testing.expect_value(t, Reg_Id(buf[4]), source)
}
