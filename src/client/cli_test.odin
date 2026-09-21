package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import lib "src:libclipbender"

// parse_cmd_get tests

@(test)
test_parse_cmd_get_all :: proc(t: ^testing.T) {
    filter, format, _, err := parse_cmd_get({"++all"})
    testing.expect(t, err == nil)
    testing.expect_value(t, filter, lib.CMD_GET_FILTER_ALL)
    testing.expect_value(t, format, Get_Cmd_Format.TABLE)
}

@(test)
test_parse_cmd_get_all_minus_numbered :: proc(t: ^testing.T) {
    filter, _, _, err := parse_cmd_get({"++all", "--numbered"})
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
    filter, _, _, err := parse_cmd_get({"+abc"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {10, 11, 12} // a=10, b=11, c=12
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_clipboard_range :: proc(t: ^testing.T) {
    filter, _, _, err := parse_cmd_get({"+0:5"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {0, 1, 2, 3, 4, 5}
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_primary_range :: proc(t: ^testing.T) {
    filter, _, _, err := parse_cmd_get({"+@0:3"})
    testing.expect(t, err == nil)
    expected: lib.Cmd_Get_Filter
    expected += {36, 37, 38, 39} // PRIMARY_START=36
    testing.expect_value(t, filter, expected)
}

@(test)
test_parse_cmd_get_exclusion_wins :: proc(t: ^testing.T) {
    // -a ++named should give all named minus a
    filter, _, _, err := parse_cmd_get({"-a", "++named"})
    testing.expect(t, err == nil)
    // bit 10 (a) should not be set
    testing.expect(t, 10 not_in filter)
    // bit 11 (b) should be set
    testing.expect(t, 11 in filter)
}

@(test)
test_parse_cmd_get_order_independent :: proc(t: ^testing.T) {
    filter1, _, _, err1 := parse_cmd_get({"++all", "-a"})
    filter2, _, _, err2 := parse_cmd_get({"-a", "++all"})
    testing.expect(t, err1 == nil)
    testing.expect(t, err2 == nil)
    testing.expect_value(t, filter1, filter2)
}

@(test)
test_parse_cmd_get_format_json :: proc(t: ^testing.T) {
    _, format, _, err := parse_cmd_get({"++all", "fmt=json"})
    testing.expect(t, err == nil)
    testing.expect_value(t, format, Get_Cmd_Format.JSON)
}

@(test)
test_parse_cmd_get_format_raw :: proc(t: ^testing.T) {
    _, format, _, err := parse_cmd_get({"++all", "fmt=raw"})
    testing.expect(t, err == nil)
    testing.expect_value(t, format, Get_Cmd_Format.RAW)
}

@(test)
test_parse_cmd_get_duplicate_format_error :: proc(t: ^testing.T) {
    _, _, _, err := parse_cmd_get({"++all", "fmt=json", "fmt=raw"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_bare_token_error :: proc(t: ^testing.T) {
    _, _, _, err := parse_cmd_get({"abc"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_invalid_format_error :: proc(t: ^testing.T) {
    _, _, _, err := parse_cmd_get({"++all", "fmt=xml"})
    testing.expect(t, err != nil)
}

@(test)
test_parse_cmd_get_incomplete_token_error :: proc(t: ^testing.T) {
    _, _, _, err := parse_cmd_get({"+"})
    testing.expect(t, err != nil)
}

// truncate_content tests

CONTENT_COL_WIDTH :: 40

@(test)
test_table_cell_pads_to_width :: proc(t: ^testing.T) {
    // Cells are pre-padded because `fmt`'s `%-Ns` pads by bytes; the table's borders depend on exact widths.
    result := table_cell("hello", CONTENT_COL_WIDTH)
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
    testing.expect_value(t, result[:5], "hello")
}

@(test)
test_table_cell_exact_width :: proc(t: ^testing.T) {
    s := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // exactly 40
    result := table_cell(s, CONTENT_COL_WIDTH)
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
}

@(test)
test_table_cell_truncates_with_ellipsis :: proc(t: ^testing.T) {
    s := "this string is definitely longer than forty characters and should be truncated"
    result := table_cell(s, CONTENT_COL_WIDTH)
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
    testing.expect_value(t, result[len(result) - 3:], "...")
}

@(test)
test_table_cell_escapes_whitespace :: proc(t: ^testing.T) {
    testing.expect_value(t, strings.trim_space(table_cell("hello\nworld", CONTENT_COL_WIDTH)), `hello\nworld`)
    testing.expect_value(t, strings.trim_space(table_cell("hello\tworld", CONTENT_COL_WIDTH)), `hello\tworld`)
    testing.expect_value(t, strings.trim_space(table_cell("hello\rworld", CONTENT_COL_WIDTH)), `hello\rworld`)
}

@(test)
test_table_cell_escapes_other_control_bytes :: proc(t: ^testing.T) {
    // A form feed printed raw moves the terminal cursor and wrecks the row. Clipboard content is untrusted text, so
    // every control byte has to be neutralised, not just the three common whitespace ones.
    result := table_cell("a\x01b\x0cc\x7fd", CONTENT_COL_WIDTH)
    testing.expect_value(t, strings.trim_space(result), `a\x01b\x0cc\x7fd`)
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
}

@(test)
test_table_cell_multibyte_width_counted_in_runes :: proc(t: ^testing.T) {
    // "é" is two bytes but one column: byte-based padding left the cell short and skewed every border to its right.
    result := table_cell("ééé", CONTENT_COL_WIDTH)
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
}

@(test)
test_display_content_binary_is_described_not_rendered :: proc(t: ^testing.T) {
    data := [?]byte{0x89, 'P', 'N', 'G', 0xFF, 0xFE}
    mimes := [?]string{}
    entry := lib.Resp_Reg {
        mime        = "image/png",
        data        = data[:],
        other_mimes = mimes[:],
    }
    result := display_content(entry, CONTENT_COL_WIDTH)
    testing.expect_value(t, strings.trim_space(result), "[6 bytes of binary data]")
    testing.expect_value(t, utf8.rune_count_in_string(result), CONTENT_COL_WIDTH)
}

@(test)
test_display_content_no_printable_mime :: proc(t: ^testing.T) {
    others := [?]string{"image/png"}
    entry := lib.Resp_Reg {
        mime        = "",
        other_mimes = others[:],
    }
    result := display_content(entry, CONTENT_COL_WIDTH)
    testing.expect_value(t, strings.trim_space(result), "[no printable mime]")
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
test_parse_cmd_set_dest_reg_selection :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("selection")
    testing.expect(t, err == nil)
    testing.expect_value(t, dest, lib.SELECTION_CLIPBOARD)
    testing.expect_value(t, mode, lib.Set_Mode.OVERWRITE)
}

@(test)
test_parse_cmd_set_dest_reg_primary_selection :: proc(t: ^testing.T) {
    dest, mode, err := parse_cmd_set_dest_reg("@selection")
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
test_parse_cmd_set_source_reg_selection :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("selection")
    testing.expect(t, err == nil)
    testing.expect_value(t, source, lib.SELECTION_CLIPBOARD)
}

@(test)
test_parse_cmd_set_source_reg_primary_selection :: proc(t: ^testing.T) {
    source, err := parse_cmd_set_source_reg("@selection")
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
    filter, _, _, err := parse_cmd_get({"+a:f"})
    testing.expect(t, err == nil)
    // a=10, b=11, c=12, d=13, e=14, f=15
    for bit in 10 ..= 15 {
        testing.expect(t, bit in filter)
    }
}

@(test)
test_parse_cmd_get_primary_specific :: proc(t: ^testing.T) {
    filter, _, _, err := parse_cmd_get({"+@038"})
    testing.expect(t, err == nil)
    // PRIMARY_START=36, so @0=36, @3=39, @8=44
    testing.expect(t, 36 in filter)
    testing.expect(t, 39 in filter)
    testing.expect(t, 44 in filter)
}

@(test)
test_parse_cmd_get_fmt_table :: proc(t: ^testing.T) {
    // `table` is the default, but spelling it explicitly must be accepted so the set is discoverable.
    _, format, _, err := parse_cmd_get({"++all", "fmt=table"})
    testing.expect(t, err == nil)
    testing.expect_value(t, format, Get_Cmd_Format.TABLE)
}

@(test)
test_parse_cmd_get_fmt_table_then_other_rejected :: proc(t: ^testing.T) {
    // `.TABLE` is both the default and an explicit value, so the duplicate check cannot use it as an unset sentinel.
    _, _, _, err_mixed := parse_cmd_get({"++all", "fmt=table", "fmt=json"})
    testing.expect(t, err_mixed != nil, "fmt=table followed by fmt=json should be rejected")

    _, _, _, err_dup := parse_cmd_get({"++all", "fmt=table", "fmt=table"})
    testing.expect(t, err_dup != nil, "duplicate fmt=table should be rejected")

    _, _, _, err_after := parse_cmd_get({"++all", "fmt=raw", "fmt=table"})
    testing.expect(t, err_after != nil, "fmt=raw followed by fmt=table should be rejected")
}

// resolve_mime_groups tests. Each case runs the real arg list through parse_cmd_get first, so the presence mask and the
// tokens come from the same source they would in `cmd_get`.

resolve :: proc(
    t: ^testing.T,
    args: []string,
    groups: ^[lib.MAX_REGS]lib.Cmd_Get_Group,
    loc := #caller_location,
) -> int {
    filter, _, pref, err := parse_cmd_get(args)
    testing.expect(t, err == nil, "parse should succeed", loc = loc)
    count, gerr := resolve_mime_groups(args, filter, pref, groups)
    testing.expect(t, gerr == nil, "resolve should succeed", loc = loc)
    return count
}

// The group covering `reg`, or nil if none does.
group_for_reg :: proc(groups: []lib.Cmd_Get_Group, reg: lib.Reg_Id) -> ^lib.Cmd_Get_Group {
    for &g in groups {
        if int(reg) in g.filter {return &g}
    }
    return nil
}

@(test)
test_resolve_mime_groups_no_mimes_is_one_group :: proc(t: ^testing.T) {
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"++named"}, &groups)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, groups[0].pref, lib.Mime_Pref(lib.Ranked_Mime.PRINTABLE))
    testing.expect_value(t, groups[0].filter, lib.CMD_GET_FILTER_NAMED)
}

@(test)
test_resolve_mime_groups_pref_flag_applies_to_unmimed :: proc(t: ^testing.T) {
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"++named", "pref=richest"}, &groups)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, groups[0].pref, lib.Mime_Pref(lib.Ranked_Mime.RICHEST))
}

@(test)
test_resolve_mime_groups_splits_by_mime :: proc(t: ^testing.T) {
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"+a=image/png", "+b"}, &groups)
    testing.expect_value(t, count, 2)

    a := group_for_reg(groups[:count], lib.reg_id_from_named_index(0))
    b := group_for_reg(groups[:count], lib.reg_id_from_named_index(1))
    testing.expect(t, a != nil && b != nil, "both registers should be covered")
    testing.expect_value(t, a.pref, lib.Mime_Pref(lib.Exact_Mime("image/png")))
    testing.expect_value(t, b.pref, lib.Mime_Pref(lib.Ranked_Mime.PRINTABLE))
}

@(test)
test_resolve_mime_groups_partitions_by_mime_not_token :: proc(t: ^testing.T) {
    // Two tokens naming the same mime must collapse into one group, not two -- the partition keys on the winning mime.
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"+a=text/html", "+c=text/html"}, &groups)
    testing.expect_value(t, count, 1)
    testing.expect_value(t, groups[0].pref, lib.Mime_Pref(lib.Exact_Mime("text/html")))
    testing.expect(t, int(lib.reg_id_from_named_index(0)) in groups[0].filter)
    testing.expect(t, int(lib.reg_id_from_named_index(2)) in groups[0].filter)
}

@(test)
test_resolve_mime_groups_strict_nesting_narrower_wins :: proc(t: ^testing.T) {
    // `++all=text/plain +a=image/png`: PNG for `a`, plain text everywhere else.
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"++all=text/plain", "+a=image/png"}, &groups)
    testing.expect_value(t, count, 2)

    a := group_for_reg(groups[:count], lib.reg_id_from_named_index(0))
    z := group_for_reg(groups[:count], lib.reg_id_from_named_index(25))
    testing.expect(t, a != nil && z != nil)
    testing.expect_value(t, a.pref, lib.Mime_Pref(lib.Exact_Mime("image/png")))
    testing.expect_value(t, z.pref, lib.Mime_Pref(lib.Exact_Mime("text/plain")))
}

@(test)
test_resolve_mime_groups_order_independent :: proc(t: ^testing.T) {
    // Same two tokens written the other way round must resolve identically.
    a_first: [lib.MAX_REGS]lib.Cmd_Get_Group
    n1 := resolve(t, {"++all=text/plain", "+a=image/png"}, &a_first)
    b_first: [lib.MAX_REGS]lib.Cmd_Get_Group
    n2 := resolve(t, {"+a=image/png", "++all=text/plain"}, &b_first)
    testing.expect_value(t, n1, n2)

    reg := lib.reg_id_from_named_index(0)
    testing.expect_value(t, group_for_reg(a_first[:n1], reg).pref, group_for_reg(b_first[:n2], reg).pref)
}

@(test)
test_resolve_mime_groups_partial_overlap_errors :: proc(t: ^testing.T) {
    // `a:c` and `c:z` both claim `c` with different mimes, and neither set contains the other.
    filter, _, pref, err := parse_cmd_get({"+a:c=text/plain", "+c:z=text/html"})
    testing.expect(t, err == nil)

    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    _, gerr := resolve_mime_groups({"+a:c=text/plain", "+c:z=text/html"}, filter, pref, &groups)
    testing.expect(t, gerr != nil, "partial overlap should be rejected")
    testing.expect(t, strings.contains(gerr.?, "`c`"), "error should name the contested register")
}

@(test)
test_resolve_mime_groups_identical_sets_differing_mimes_errors :: proc(t: ^testing.T) {
    // Identical sets are not nesting: without the `inter != b.set` guard this would look like one nested in the other.
    filter, _, pref, err := parse_cmd_get({"+a=text/plain", "+a=text/html"})
    testing.expect(t, err == nil)

    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    _, gerr := resolve_mime_groups({"+a=text/plain", "+a=text/html"}, filter, pref, &groups)
    testing.expect(t, gerr != nil, "identical sets with different mimes should be rejected")
}

@(test)
test_resolve_mime_groups_excluded_register_drops_its_mime :: proc(t: ^testing.T) {
    // `-a` removes `a` from presence, so its mime token covers nothing and must not resurrect it.
    groups: [lib.MAX_REGS]lib.Cmd_Get_Group
    count := resolve(t, {"++named", "+a=image/png", "-a"}, &groups)
    testing.expect(t, count >= 1)
    testing.expect(t, group_for_reg(groups[:count], lib.reg_id_from_named_index(0)) == nil)
    for g in groups[:count] {
        testing.expect_value(t, g.pref, lib.Mime_Pref(lib.Ranked_Mime.PRINTABLE))
    }
}

@(test)
test_parse_cmd_get_rejects_bad_mimes :: proc(t: ^testing.T) {
    _, _, _, err_no_slash := parse_cmd_get({"+a=text"})
    testing.expect(t, err_no_slash != nil, "mime without `/` should be rejected")

    _, _, _, err_empty := parse_cmd_get({"+a="})
    testing.expect(t, err_empty != nil, "empty mime should be rejected")

    long: [lib.MAX_MIME_LEN + 1]byte
    for &c in long {c = 'x'}
    _, _, _, err_long := parse_cmd_get({fmt.tprintf("+a=%s", string(long[:]))})
    testing.expect(t, err_long != nil, "over-long mime should be rejected")

    _, _, _, err_excl := parse_cmd_get({"-a=text/plain"})
    testing.expect(t, err_excl != nil, "mime on an exclusion token should be rejected")

    _, _, _, err_bare := parse_cmd_get({"a=text/plain"})
    testing.expect(t, err_bare != nil, "bare `a=mime` is the flag namespace, not a register")
}

@(test)
test_parse_cmd_get_pref_flag :: proc(t: ^testing.T) {
    _, _, pref, err := parse_cmd_get({"++all", "pref=richest"})
    testing.expect(t, err == nil)
    testing.expect_value(t, pref, lib.Ranked_Mime.RICHEST)

    _, _, _, err_bad := parse_cmd_get({"++all", "pref=fastest"})
    testing.expect(t, err_bad != nil, "unknown pref value should be rejected")

    _, _, _, err_dup := parse_cmd_get({"++all", "pref=richest", "pref=printable"})
    testing.expect(t, err_dup != nil, "duplicate pref flag should be rejected")
}

// parse_set_mime_flags tests

@(test)
test_parse_set_mime_flags_none :: proc(t: ^testing.T) {
    mimes, err := parse_set_mime_flags({"a"})
    defer delete(mimes)
    testing.expect(t, err == nil)
    testing.expect_value(t, len(mimes), 0)
}

@(test)
test_parse_set_mime_flags_repeatable_and_ordered :: proc(t: ^testing.T) {
    // Order is the point: most-specific-first is what drives resolution on the daemon side.
    mimes, err := parse_set_mime_flags({"a", "mime=application/rtf", "mime=text/plain"})
    defer {
        for mime in mimes {delete(mime)}
        delete(mimes)
    }
    testing.expect(t, err == nil)
    testing.expect_value(t, len(mimes), 2)
    testing.expect_value(t, mimes[0], "application/rtf")
    testing.expect_value(t, mimes[1], "text/plain")
}

@(test)
test_parse_set_mime_flags_dedupes :: proc(t: ^testing.T) {
    // Repeats are redundant rather than contradictory, so they are dropped rather than rejected.
    mimes, err := parse_set_mime_flags({"a", "mime=text/plain", "mime=text/plain"})
    defer {
        for mime in mimes {delete(mime)}
        delete(mimes)
    }
    testing.expect(t, err == nil)
    testing.expect_value(t, len(mimes), 1)
}

@(test)
test_parse_set_mime_flags_rejects_invalid :: proc(t: ^testing.T) {
    // Shares `validate_exact_mime` with GET, so SET rejects exactly what `+a=` rejects.
    _, err_empty := parse_set_mime_flags({"a", "mime="})
    testing.expect(t, err_empty != nil, "empty mime should be rejected")

    _, err_no_slash := parse_set_mime_flags({"a", "mime=text"})
    testing.expect(t, err_no_slash != nil, "mime without `/` should be rejected")

    long: [lib.MAX_MIME_LEN + 1]byte
    for &c in long {c = 'x'}
    _, err_long := parse_set_mime_flags({"a", fmt.tprintf("mime=%s", string(long[:]))})
    testing.expect(t, err_long != nil, "over-long mime should be rejected")
}

@(test)
test_parse_set_mime_flags_rejects_over_count :: proc(t: ^testing.T) {
    // The wire format's count is one byte; refusing beats letting the marshal clamp silently.
    args := make([dynamic]string)
    defer delete(args)
    append(&args, "a")
    for i in 0 ..< lib.MAX_MIME_COUNT + 1 {
        append(&args, fmt.tprintf("mime=text/x-%d", i))
    }
    _, err := parse_set_mime_flags(args[:])
    testing.expect(t, err != nil, "more than MAX_MIME_COUNT mimes should be rejected")
}

@(test)
test_is_set_mime_flag :: proc(t: ^testing.T) {
    testing.expect(t, is_set_mime_flag("mime=text/plain"))
    testing.expect(t, is_set_mime_flag("mime="))
    // Positional args and other flags must not be mistaken for it, or the SET form dispatch breaks.
    testing.expect(t, !is_set_mime_flag("a"))
    testing.expect(t, !is_set_mime_flag("selection"))
    testing.expect(t, !is_set_mime_flag("fmt=json"))
}
