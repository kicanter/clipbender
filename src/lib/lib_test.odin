package lib

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

