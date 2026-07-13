package main

import "core:testing"

import lib "src:libclipbender"

// parse_cmd_get tests

@(test)
test_parse_cmd_get_all :: proc(t: ^testing.T) {
    filter, format, err := parse_cmd_get({"++all"})
    testing.expect(t, err == nil)
    testing.expect_value(t, filter, lib.CMD_GET_FILTER_ALL)
    testing.expect_value(t, format, Get_Cmd_Format.TABLE)
}

@(test)
test_parse_cmd_get_all_minus_numbered :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"++all", "--numbered"})
    testing.expect(t, err == nil)
    expected :=
        lib.CMD_GET_FILTER_NAMED +
        lib.CMD_GET_FILTER_PRIMARY_NUMBERED +
        lib.CMD_GET_FILTER_SELECTION +
        lib.CMD_GET_FILTER_PRIMARY_SELECTION
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_named_group :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"+abc"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {10, 11, 12} // a=10, b=11, c=12
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_clipboard_range :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"+0:5"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {0, 1, 2, 3, 4, 5}
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_primary_range :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"+@0:3"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {36, 37, 38, 39} // PRIMARY_START=36
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_exclusion_wins :: proc(t: ^testing.T) {
    // -a ++named should give all named minus a
    filter, _, err := parse_cmd_get({"-a", "++named"})
    testing.expect(t, err == nil)
    // bit 10 (a) should not be set
    testing.expect(t, 10 not_in filter)
    // bit 11 (b) should be set
    testing.expect(t, 11 in filter)
}

@(test)
test_parse_cmd_get_order_independent :: proc(t: ^testing.T) {
    filter1, _, err1 := parse_cmd_get({"++all", "-a"})
    filter2, _, err2 := parse_cmd_get({"-a", "++all"})
    testing.expect(t, err1 == nil)
    testing.expect(t, err2 == nil)
    testing.expect_value(t, filter1, filter2)
}

@(test)
test_parse_cmd_get_format_json :: proc(t: ^testing.T) {
    _, format, err := parse_cmd_get({"++all", "fmt=json"})
    testing.expect(t, err == nil)
    testing.expect_value(t, format, Get_Cmd_Format.JSON)
}

@(test)
test_parse_cmd_get_format_raw :: proc(t: ^testing.T) {
    _, format, err := parse_cmd_get({"++all", "fmt=raw"})
    testing.expect(t, err == nil)
    testing.expect_value(t, format, Get_Cmd_Format.RAW)
}

@(test)
test_parse_cmd_get_duplicate_format_error :: proc(t: ^testing.T) {
    _, _, err := parse_cmd_get({"++all", "fmt=json", "fmt=raw"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_bare_token_error :: proc(t: ^testing.T) {
    _, _, err := parse_cmd_get({"abc"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_invalid_format_error :: proc(t: ^testing.T) {
    _, _, err := parse_cmd_get({"++all", "fmt=xml"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_incomplete_token_error :: proc(t: ^testing.T) {
    _, _, err := parse_cmd_get({"+"})
    testing.expect(t, err != nil)
}

// truncate_content tests

CONTENT_COL_WIDTH :: 40

@(test)
test_truncate_content_short :: proc(t: ^testing.T) {
    result := truncate_content("hello", CONTENT_COL_WIDTH)
    testing.expect_value(t, result, "hello")
}

@(test)
test_truncate_content_exact :: proc(t: ^testing.T) {
    // exactly CONTENT_COL_WIDTH chars
    s := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 40 chars
    result := truncate_content(s, CONTENT_COL_WIDTH)
    testing.expect_value(t, result, s)
}

@(test)
test_truncate_content_long :: proc(t: ^testing.T) {
    s := "this string is definitely longer than forty characters and should be truncated"
    result := truncate_content(s, CONTENT_COL_WIDTH)
    testing.expect(t, len(result) == CONTENT_COL_WIDTH)
    // should end with "..."
    testing.expect_value(t, result[CONTENT_COL_WIDTH - 3:], "...")
}

@(test)
test_truncate_content_newline :: proc(t: ^testing.T) {
    result := truncate_content("hello\nworld", CONTENT_COL_WIDTH)
    // newline should be replaced with visible \n
    testing.expect_value(t, result, `hello\nworld`)
}

@(test)
test_truncate_content_tab :: proc(t: ^testing.T) {
    result := truncate_content("hello\tworld", CONTENT_COL_WIDTH)
    testing.expect_value(t, result, `hello\tworld`)
}

// json_escape_string tests

@(test)
test_json_escape_string_plain :: proc(t: ^testing.T) {
    result := json_escape_string("hello world")
    testing.expect_value(t, result, "hello world")
}

@(test)
test_json_escape_string_quotes :: proc(t: ^testing.T) {
    result := json_escape_string(`he said "hi"`)
    testing.expect_value(t, result, `he said \"hi\"`)
}

@(test)
test_json_escape_string_backslash :: proc(t: ^testing.T) {
    result := json_escape_string(`path\to\file`)
    testing.expect_value(t, result, `path\\to\\file`)
}

@(test)
test_json_escape_string_newline :: proc(t: ^testing.T) {
    result := json_escape_string("line1\nline2")
    testing.expect_value(t, result, `line1\nline2`)
}

@(test)
test_json_escape_string_tab :: proc(t: ^testing.T) {
    result := json_escape_string("col1\tcol2")
    testing.expect_value(t, result, `col1\tcol2`)
}

@(test)
test_json_escape_string_mixed :: proc(t: ^testing.T) {
    result := json_escape_string("\"hello\"\n\t\\end")
    testing.expect_value(t, result, `\"hello\"\n\t\\end`)
}

// parse_cmd_set_dest_reg tests

@(test)
test_parse_cmd_set_dest_reg_named :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("a")
    testing.expect(t, err == nil)
    testing.expect_value(t, dest, lib.reg_id_from_named_index(0))
    testing.expect_value(t, mode, lib.Set_Mode.OVERWRITE)
}

@(test)
test_parse_cmd_set_dest_reg_append :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("A")
    testing.expect(t, err == nil)
    testing.expect_value(t, dest, lib.reg_id_from_named_index(0))
    testing.expect_value(t, mode, lib.Set_Mode.APPEND)
}

@(test)
test_parse_cmd_set_dest_reg_clipboard :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("clipboard")
    testing.expect(t, err == nil)
    testing.expect_value(t, dest, lib.SELECTION_CLIPBOARD)
    testing.expect_value(t, mode, lib.Set_Mode.OVERWRITE)
}

@(test)
test_parse_cmd_set_dest_reg_primary :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("primary")
    testing.expect(t, err == nil)
    testing.expect_value(t, dest, lib.SELECTION_PRIMARY)
    testing.expect_value(t, mode, lib.Set_Mode.OVERWRITE)
}

@(test)
test_parse_cmd_set_dest_reg_invalid :: proc(t: ^testing.T) {
    _, _, err := parse_cmd_set_dest_reg("9")
    testing.expect(t, err != nil)
}

// parse_cmd_set_source_reg tests

@(test)
test_parse_cmd_set_source_reg_clipboard_num :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("3")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.reg_id_from_clipboard_index(3))
}

@(test)
test_parse_cmd_set_source_reg_primary_num :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("@5")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.reg_id_from_primary_index(5))
}

@(test)
test_parse_cmd_set_source_reg_named :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("z")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.reg_id_from_named_index(25))
}

@(test)
test_parse_cmd_set_source_reg_clipboard_keyword :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("clipboard")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.SELECTION_CLIPBOARD)
}

@(test)
test_parse_cmd_set_source_reg_primary_keyword :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("primary")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.SELECTION_PRIMARY)
}

@(test)
test_parse_cmd_set_source_reg_uppercase_error :: proc(t: ^testing.T) {
    _, err := parse_cmd_set_source_reg("A")
    testing.expect(t, err != nil)
}

// parse_cmd_get additional tests

@(test)
test_parse_cmd_get_named_range :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"+a:f"})
    testing.expect(t, err == nil)
    // a=10, b=11, c=12, d=13, e=14, f=15
    for bit in 10 ..= 15 {
        testing.expect(t, bit in filter)
    }
}

@(test)
test_parse_cmd_get_primary_specific :: proc(t: ^testing.T) {
    filter, _, err := parse_cmd_get({"+@038"})
    testing.expect(t, err == nil)
    // PRIMARY_START=36, so @0=36, @3=39, @8=44
    testing.expect(t, 36 in filter)
    testing.expect(t, 39 in filter)
    testing.expect(t, 44 in filter)
}
