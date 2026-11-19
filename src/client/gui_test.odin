package main

import xkb "bindings:xkbcommon"
import "core:testing"
import lib "src:libclipbender"

// Keymap resolution. Each case drives `resolve_keymap` with the presses a user would actually make,
// so the sequence match, the register-name parse and the operand derivation are exercised together.

chord :: proc(keysym: xkb.Keysym, mods: Modifier_Flags = {}) -> Key_Chord {
    return {mods, keysym}
}

// Resolve a sequence and derive the register operands, which is what the handler will do. `mode`
// comes from which action matched, so it is reported here the same way dispatch would read it.
// Fails loudly rather than reporting `.Miss` when a sequence resolves to some other action, so a
// mis-bound sequence cannot masquerade as one that simply did not match.
fire_set :: proc(
    t: ^testing.T,
    keymaps: []Keymap,
    presses: []Key_Chord,
    loc := #caller_location,
) -> (
    src: lib.Reg_Id,
    dst: lib.Reg_Id,
    mode: lib.Set_Mode,
    status: lib.Match_Status,
) {
    keymap, captures, st := resolve_keymap(keymaps, presses)
    if st != .Hit {return {}, {}, {}, st}
    testing.expectf(t, keymap.action == .Set_Reg, "expected Set_Reg, got %v", keymap.action, loc = loc)
    src, dst, mode, _ = reg_args(captures)
    return src, dst, mode, .Hit
}

@(test)
test_keymap_bare_register_copies_to_clipboard :: proc(t: ^testing.T) {
    // One binding covers every register spelling, because a register operand matches any name.
    cases := [?]struct {
        presses: []Key_Chord,
        want:    lib.Reg_Id,
    } {
        {{chord('3')}, lib.reg_id_from_clipboard_index(3)},
        {{chord('a')}, lib.reg_id_from_named_index(0)},
        {{chord('.')}, lib.SELECTION_CLIPBOARD},
        {{chord(xkb.KEYSYM_at, {.Shift}), chord('7')}, lib.reg_id_from_primary_index(7)},
        {{chord(xkb.KEYSYM_at, {.Shift}), chord('.')}, lib.SELECTION_PRIMARY},
    }
    for c in cases {
        src, dst, mode, status := fire_set(t, MAIN_KEYMAPS, c.presses)
        testing.expectf(t, status == .Hit, "expected Hit, got %v", status)
        testing.expectf(t, src == c.want, "src = %v, want %v", src, c.want)
        testing.expect(t, dst == lib.SELECTION_CLIPBOARD)
        testing.expect(t, mode == .OVERWRITE)
    }
}

@(test)
test_keymap_partial_while_sequence_incomplete :: proc(t: ^testing.T) {
    // `@` cannot finish a register name, and `<space>` cannot finish a binding. Both must report
    // Partial so the caller keeps the buffer instead of resetting it.
    partials := [?][]Key_Chord {
        {chord(xkb.KEYSYM_at, {.Shift})},
        {chord(xkb.KEYSYM_space)},
        {chord(xkb.KEYSYM_space), chord('a')},
        {chord(xkb.KEYSYM_equal)},
    }
    for presses in partials {
        _, _, st := resolve_keymap(MAIN_KEYMAPS, presses)
        testing.expectf(t, st == .Partial, "expected Partial for %v presses, got %v", len(presses), st)
    }
}

@(test)
test_keymap_space_sequence_copies_between_registers :: proc(t: ^testing.T) {
    src, dst, mode, status := fire_set(t, MAIN_KEYMAPS, {chord(xkb.KEYSYM_space), chord('a'), chord('b')})
    testing.expect(t, status == .Hit)
    testing.expect(t, src == lib.reg_id_from_named_index(0))
    testing.expect(t, dst == lib.reg_id_from_named_index(1))
    testing.expect(t, mode == .OVERWRITE)
}

@(test)
test_keymap_shift_on_destination_appends :: proc(t: ^testing.T) {
    src, dst, mode, status := fire_set(t, MAIN_KEYMAPS, {chord(xkb.KEYSYM_space), chord('a'), chord('B', {.Shift})})
    testing.expect(t, status == .Hit)
    testing.expect(t, src == lib.reg_id_from_named_index(0))
    testing.expect(t, dst == lib.reg_id_from_named_index(1))
    testing.expectf(t, mode == .APPEND, "Shift on the destination must append, got %v", mode)
}

@(test)
test_keymap_caps_lock_does_not_append :: proc(t: ^testing.T) {
    // With caps lock the keysym is uppercase but Shift is NOT held. Keying append off the keysym's
    // case instead of the flag would make every caps-locked overwrite a silent append.
    src, dst, mode, status := fire_set(t, MAIN_KEYMAPS, {chord(xkb.KEYSYM_space), chord('A'), chord('B')})
    testing.expect(t, status == .Hit)
    testing.expect(t, src == lib.reg_id_from_named_index(0))
    testing.expect(t, dst == lib.reg_id_from_named_index(1))
    testing.expectf(t, mode == .OVERWRITE, "caps lock must not append, got %v", mode)
}

@(test)
test_keymap_at_prefixed_destination_is_not_an_append :: proc(t: ^testing.T) {
    // `@` is Shift+2, so a `@`-prefixed operand always arrives with Shift held. Append must ignore
    // that, or `<space>a@.` would be read as an append.
    src, dst, mode, status := fire_set(
        t,
        MAIN_KEYMAPS,
        {chord(xkb.KEYSYM_space), chord('a'), chord(xkb.KEYSYM_at, {.Shift}), chord('.')},
    )
    testing.expect(t, status == .Hit)
    testing.expect(t, src == lib.reg_id_from_named_index(0))
    testing.expect(t, dst == lib.SELECTION_PRIMARY)
    testing.expectf(t, mode == .OVERWRITE, "`@.` destination must not append, got %v", mode)
}

@(test)
test_keymap_chord_not_shadowed_by_register_operand :: proc(t: ^testing.T) {
    // A register operand rejects non-Shift modifiers. Without that, `<C-e>` parses as register `e`
    // and the bare-register binding swallows every Ctrl chord.
    keymap, _, status := resolve_keymap(MAIN_KEYMAPS, {chord(xkb.KEYSYM_e, {.Ctrl})})
    testing.expect(t, status == .Hit)
    testing.expectf(t, keymap.action == .Scroll_Row_Down, "<C-e> must scroll, got %v", keymap.action)
}

@(test)
test_keymap_unary_actions :: proc(t: ^testing.T) {
    // Unary actions take their register from capture 0.
    keymap, captures, status := resolve_keymap(MAIN_KEYMAPS, {chord(xkb.KEYSYM_equal), chord('a')})
    testing.expect(t, status == .Hit)
    testing.expect(t, keymap.action == .Open_Mime_List)
    testing.expect(t, captures.regs[0] == lib.reg_id_from_named_index(0))

    keymap, captures, status = resolve_keymap(MAIN_KEYMAPS, {chord(xkb.KEYSYM_minus), chord('a')})
    testing.expect(t, status == .Hit)
    testing.expect(t, keymap.action == .Clear_Reg)
    testing.expect(t, captures.regs[0] == lib.reg_id_from_named_index(0))
}

@(test)
test_keymap_misses :: proc(t: ^testing.T) {
    misses := [?][]Key_Chord {
        {chord('a', {.Ctrl})}, // a non-Shift modifier is never part of a register name
        {chord(xkb.KEYSYM_space), chord('a'), chord('!', {.Shift})}, // not a register name
        {chord(xkb.KEYSYM_at, {.Shift}), chord('a')}, // `@a` is not a register
        {chord('3'), chord('3')}, // leftover input past a complete binding
    }
    for presses in misses {
        _, _, st := resolve_keymap(MAIN_KEYMAPS, presses)
        testing.expectf(t, st == .Miss, "expected Miss, got %v", st)
    }
}

@(test)
test_keymap_unwind_matches_in_any_mode :: proc(t: ^testing.T) {
    for presses in ([?][]Key_Chord {
            {chord(xkb.KEYSYM_Escape)},
            {chord(xkb.KEYSYM_bracketleft, {.Ctrl})},
            {chord(xkb.KEYSYM_c, {.Ctrl})},
        }) {
        keymap, _, st := resolve_keymap(UNWIND_KEYMAPS, presses)
        testing.expect(t, st == .Hit)
        testing.expect(t, keymap.action == .Unwind)
    }
}

@(test)
test_keymap_mime_list_is_chord_only :: proc(t: ^testing.T) {
    // `j` is a cursor key here and a register name in MAIN -- the same keysym, different table.
    keymap, _, st := resolve_keymap(MIME_LIST_KEYMAPS, {chord(xkb.KEYSYM_j)})
    testing.expect(t, st == .Hit)
    testing.expect(t, keymap.action == .Cursor_Down)

    _, _, miss := resolve_keymap(MIME_LIST_KEYMAPS, {chord('3')})
    testing.expectf(t, miss == .Miss, "digits address nothing in a mime list, got %v", miss)
}

@(test)
test_keymap_append_cannot_target_a_live_selection :: proc(t: ^testing.T) {
    // `set_selection_reg` ignores `Set_Mode`, so an append into `.` or `@.` would silently
    // overwrite. `reg_args` forces OVERWRITE for a selection destination so the caller is not told
    // an append happened when it did not.
    for presses in ([?][]Key_Chord {
            {chord(xkb.KEYSYM_space), chord('a'), chord('.')},
            {chord(xkb.KEYSYM_space), chord('a'), chord(xkb.KEYSYM_at, {.Shift}), chord('.')},
        }) {
        _, dst, mode, status := fire_set(t, MAIN_KEYMAPS, presses)
        testing.expect(t, status == .Hit)
        testing.expect(t, lib.reg_id_is_selection(dst))
        testing.expectf(t, mode == .OVERWRITE, "a selection destination must not claim APPEND, got %v", mode)
    }
}

@(test)
test_activity_focus_selects_its_own_keymaps :: proc(t: ^testing.T) {
    // The same keysym means different things per activity, which is why each has its own table.
    browsing_keymap, browsing_captures, browsing_status := resolve_keymap(keymaps_for(.Main), {chord('j')})
    testing.expect(t, browsing_status == .Hit)
    testing.expectf(t, browsing_keymap.action == .Set_Reg, "`j` is register j in MAIN, got %v", browsing_keymap.action)
    testing.expect(t, browsing_captures.regs[0] == lib.reg_id_from_named_index('j' - 'a'))

    mime_list_keymap, _, mime_list_status := resolve_keymap(keymaps_for(.Mime_List), {chord('j')})
    testing.expect(t, mime_list_status == .Hit)
    testing.expectf(
        t,
        mime_list_keymap.action == .Cursor_Down,
        "`j` moves the cursor in MIME_LIST, got %v",
        mime_list_keymap.action,
    )
}

@(test)
test_modifier_keysyms_are_filtered :: proc(t: ^testing.T) {
    // A modifier press is its own event. Left unfiltered it would accumulate, match nothing, and
    // report an invalid sequence every time the user reached for Shift.
    for keysym in ([?]xkb.Keysym {
            xkb.KEYSYM_Shift_L,
            xkb.KEYSYM_Hyper_R,
            xkb.KEYSYM_Num_Lock,
            xkb.KEYSYM_Mode_switch,
            xkb.KEYSYM_ISO_Lock,
            xkb.KEYSYM_ISO_Level5_Lock,
            xkb.Keysym(0xFE04), // ISO_Level3_Latch -- inside the range, missed by a member list
        }) {
        testing.expectf(t, keysym_is_modifier(keysym), "keysym %x must be filtered", keysym)
    }
    for keysym in ([?]xkb.Keysym{'a', '3', xkb.KEYSYM_Return, xkb.KEYSYM_Escape, xkb.KEYSYM_at}) {
        testing.expectf(t, !keysym_is_modifier(keysym), "keysym %x must not be filtered", keysym)
    }
}

@(test)
test_reg_name_parse_asks_lib_for_the_grammar :: proc(t: ^testing.T) {
    // `@` alone is Partial because `lib.reg_id_from_string` reports Partial for it, not
    // because the popup knows `@` is a prefix.
    _, _, _, partial := parse_reg_token({chord(xkb.KEYSYM_at, {.Shift})})
    testing.expectf(t, partial == .Partial, "`@` alone must be Partial, got %v", partial)

    // Longest-first: `@3` must beat a one-key read of `@`.
    reg, _, used, status := parse_reg_token({chord(xkb.KEYSYM_at, {.Shift}), chord('3')})
    testing.expect(t, status == .Hit)
    testing.expectf(t, used == 2, "`@3` consumes both presses, got %v", used)
    testing.expect(t, reg == lib.reg_id_from_primary_index(3))

    // A trailing key that cannot extend the name leaves it at one press.
    reg, _, used, status = parse_reg_token({chord('a'), chord('b')})
    testing.expect(t, status == .Hit)
    testing.expectf(t, used == 1, "`ab` is register a plus leftover, got used=%v", used)
    testing.expect(t, reg == lib.reg_id_from_named_index(0))

    // Not a register name and cannot become one.
    _, _, _, miss := parse_reg_token({chord('!', {.Shift})})
    testing.expectf(t, miss == .Miss, "`!` must Miss, got %v", miss)
}

@(test)
test_reg_name_reports_mods_of_its_final_press :: proc(t: ^testing.T) {
    // `@` is Shift+2, so a `@`-prefixed name always opens with Shift held. Reporting the first
    // press's modifiers instead would make every primary register look like an append request.
    _, at_mods, used, status := parse_reg_token({chord(xkb.KEYSYM_at, {.Shift}), chord('3')})
    testing.expect(t, status == .Hit)
    testing.expect(t, used == 2)
    testing.expectf(t, at_mods == {}, "`@3` must report `3`'s modifiers, got %v", at_mods)

    // A single-press name reports its own modifiers, which is what marks append.
    _, shift_mods, _, shift_status := parse_reg_token({chord('B', {.Shift})})
    testing.expect(t, shift_status == .Hit)
    testing.expectf(t, shift_mods == {.Shift}, "`Shift+b` must report Shift, got %v", shift_mods)
}

@(test)
test_keymap_stray_shift_on_a_bare_register_is_forgiven :: proc(t: ^testing.T) {
    // The token records Shift rather than requiring it, so `Shift+a` still reads register `a`. Mode
    // is ignored here because a one-capture binding targets the live clipboard, where
    // `set_selection_reg` discards `Set_Mode` anyway -- so the Shift is harmless rather than a
    // silent append.
    src, dst, mode, status := fire_set(t, MAIN_KEYMAPS, {chord('A', {.Shift})})
    testing.expectf(t, status == .Hit, "`Shift+a` should still read register a, got %v", status)
    testing.expect(t, src == lib.reg_id_from_named_index(0))
    testing.expect(t, dst == lib.SELECTION_CLIPBOARD)
    testing.expect(t, mode == .OVERWRITE)
}

@(test)
test_binding_bounds :: proc(t: ^testing.T) {
    // Records what the tables actually demand, so whoever sizes the pending-press buffer has a
    // checked number instead of a hand-derived one -- and so adding a longer binding fails here.
    // A chord consumes one press; a register name consumes up to `lib.MAX_REG_NAME_LEN`.
    for keymaps in ([?][]Keymap{MAIN_KEYMAPS, MIME_LIST_KEYMAPS, UNWIND_KEYMAPS}) {
        for keymap in keymaps {
            presses, captures := 0, 0
            for token in keymap.seq {
                switch _ in token {
                case Key_Chord:
                    presses += 1
                case Reg_Token:
                    presses += lib.MAX_REG_NAME_LEN
                    captures += 1
                }
            }
            testing.expectf(
                t,
                presses <= MAX_PRESSES,
                "%v needs up to %d presses, bound is %d",
                keymap.action,
                presses,
                MAX_PRESSES,
            )
            testing.expectf(
                t,
                captures <= MAX_CAPTURES,
                "%v names %d register slots, MAX_CAPTURES is %d",
                keymap.action,
                captures,
                MAX_CAPTURES,
            )
        }
    }
}

@(test)
test_max_presses_covers_every_binding :: proc(t: ^testing.T) {
    // The pending buffer is a fixed array, so `MAX_PRESSES` must bound what the tables can demand.
    // Overflowing it would be the one way a sequence could be silently truncated.
    for keymaps in ([?][]Keymap{MAIN_KEYMAPS, MIME_LIST_KEYMAPS, UNWIND_KEYMAPS}) {
        for keymap in keymaps {
            presses := 0
            for token in keymap.seq {
                switch _ in token {
                case Key_Chord:
                    presses += 1
                case Reg_Token:
                    presses += lib.MAX_REG_NAME_LEN
                }
            }
            testing.expectf(
                t,
                presses <= MAX_PRESSES,
                "%v needs up to %d presses, MAX_PRESSES is %d",
                keymap.action,
                presses,
                MAX_PRESSES,
            )
        }
    }
}

// Viewport. These build a `Gui_State` with only the fields the viewport reads, so no compositor or
// cairo context is needed.

fake_state :: proc(populated: []lib.Reg_Id, height: uint) -> Gui_State {
    gui_state := Gui_State {
        frame_buf = {height = height},
    }
    for id in populated {
        // One repr is all `resp_reg_is_empty` looks at.
        gui_state.regs[id] = lib.Resp_Reg {
            reprs = make([]lib.Resp_Repr, 1),
        }
    }
    return gui_state
}

free_fake_state :: proc(gui_state: ^Gui_State) {
    for &reg in gui_state.regs {
        if len(reg.reprs) > 0 {delete(reg.reprs)}
    }
}

@(test)
test_populated_regs_skips_empties_and_orders_groups :: proc(t: ^testing.T) {
    // Live selections first -- clipboard before primary -- then the clipboard ring, then primary,
    // then named. Nothing for the 40-odd ids that hold no data.
    gui_state := fake_state(
        {
            lib.reg_id_from_named_index(0),
            lib.SELECTION_PRIMARY,
            lib.reg_id_from_clipboard_index(2),
            lib.SELECTION_CLIPBOARD,
            lib.reg_id_from_primary_index(1),
        },
        900,
    )
    defer free_fake_state(&gui_state)

    buf: [lib.MAX_REGS]lib.Reg_Id
    got := buf[:populated_regs(&gui_state, buf[:])]

    want := []lib.Reg_Id {
        lib.SELECTION_CLIPBOARD,
        lib.SELECTION_PRIMARY,
        lib.reg_id_from_clipboard_index(2),
        lib.reg_id_from_primary_index(1),
        lib.reg_id_from_named_index(0),
    }
    testing.expectf(t, len(got) == len(want), "got %d rows, want %d", len(got), len(want))
    for id, i in want {
        testing.expectf(
            t,
            got[i] == id,
            "row %d is %s, want %s",
            i,
            lib.reg_id_to_string(got[i]),
            lib.reg_id_to_string(id),
        )
    }
}

@(test)
test_scroll_clamps_at_both_ends :: proc(t: ^testing.T) {
    // Three rows in a panel that fits two, so exactly one row of travel.
    gui_state := fake_state(
        {lib.reg_id_from_clipboard_index(0), lib.reg_id_from_clipboard_index(1), lib.reg_id_from_clipboard_index(2)},
        // Plus the divider budget `visible_row_count` reserves, or the panel only fits one row.
        uint(2 * ROW_HEIGHT + (len(Reg_Category) - 1) * HORZ_RULE_GAP + 2 * (PANEL_MARGIN + TEXT_PADDING_Y)),
    )
    defer free_fake_state(&gui_state)
    testing.expectf(
        t,
        visible_row_count(&gui_state) == 2,
        "expected 2 visible rows, got %d",
        visible_row_count(&gui_state),
    )

    testing.expect(t, scroll_by(&gui_state, 1), "first row down should move")
    testing.expect(t, gui_state.scroll_row == 1)

    testing.expect(t, !scroll_by(&gui_state, 1), "already at the bottom, must report no movement")
    testing.expect(t, gui_state.scroll_row == 1)

    testing.expect(t, !scroll_by(&gui_state, 50), "a page past the end must clamp, not overshoot")
    testing.expect(t, gui_state.scroll_row == 1)

    testing.expect(t, scroll_by(&gui_state, -50), "scrolling up from the bottom should move")
    testing.expect(t, gui_state.scroll_row == 0)

    testing.expect(t, !scroll_by(&gui_state, -1), "already at the top, must report no movement")
}

@(test)
test_scroll_is_a_noop_when_everything_fits :: proc(t: ^testing.T) {
    // Nothing is clipped, so there is nowhere to scroll and no redraw to trigger.
    gui_state := fake_state({lib.reg_id_from_clipboard_index(0)}, 900)
    defer free_fake_state(&gui_state)

    testing.expect(t, !scroll_by(&gui_state, 1))
    testing.expect(t, !scroll_by(&gui_state, 10))
    testing.expect(t, gui_state.scroll_row == 0)
}

// Mime list. The flattened-mimes walk and the repr mapping decide whether committing needs a fetch,
// so they are worth pinning without a compositor.

snap_multi_mime :: proc(groups: [][]string, selected: u8) -> lib.Resp_Reg {
    reprs := make([]lib.Resp_Repr, len(groups))
    for names, i in groups {
        mimes := make([]string, len(names))
        copy(mimes, names)
        reprs[i] = {
            mimes = mimes,
        }
    }
    return {reprs = reprs, selected = selected, data_sent = true}
}

free_multi_mime :: proc(reg: lib.Resp_Reg) {
    for repr in reg.reprs {delete(repr.mimes)}
    delete(reg.reprs)
}

@(test)
test_mime_list_flattens_across_reprs :: proc(t: ^testing.T) {
    // Two blobs, four names: the first repr carries two aliases of one blob.
    reg := snap_multi_mime({{"text/plain", "UTF8_STRING"}, {"text/html", "text/markdown"}}, 0)
    defer free_multi_mime(reg)

    testing.expectf(t, mime_count(reg) == 4, "expected 4 mimes, got %d", mime_count(reg))

    want := [?]struct {
        repr: int,
        mime: string,
    }{{0, "text/plain"}, {0, "UTF8_STRING"}, {1, "text/html"}, {1, "text/markdown"}}
    for w, i in want {
        repr, mime, ok := mime_at(reg, i)
        testing.expectf(t, ok, "mime %d should exist", i)
        testing.expectf(t, repr == w.repr, "mime %d is in repr %d, want %d", i, repr, w.repr)
        testing.expectf(t, mime == w.mime, "mime %d is %q, want %q", i, mime, w.mime)
    }

    _, _, past_end := mime_at(reg, 4)
    testing.expect(t, !past_end, "index past the last mime must not resolve")
}

@(test)
test_mime_cursor_opens_on_the_selected_repr :: proc(t: ^testing.T) {
    // Opening on index 0 would point at a different blob than the row is showing.
    reg := snap_multi_mime({{"image/png"}, {"text/plain", "UTF8_STRING"}, {"text/html"}}, 1)
    defer free_multi_mime(reg)
    testing.expectf(
        t,
        selected_mime_index(reg) == 1,
        "cursor should open on repr 1's first mime (index 1), got %d",
        selected_mime_index(reg),
    )

    // With no repr selected there is nothing to prefer, so the top is the only sane default.
    none := snap_multi_mime({{"image/png"}, {"text/plain"}}, lib.RESP_SELECTED_NONE)
    defer free_multi_mime(none)
    testing.expect(t, selected_mime_index(none) == 0)
}

@(test)
test_mime_aliases_share_a_repr :: proc(t: ^testing.T) {
    // The property `commit_mime` relies on to skip a fetch: names in one repr share one blob, so
    // choosing an alias of what is already selected needs no IPC.
    reg := snap_multi_mime({{"text/plain", "UTF8_STRING", "STRING"}, {"text/html"}}, 0)
    defer free_multi_mime(reg)

    for i in 0 ..< 3 {
        repr, _, _ := mime_at(reg, i)
        testing.expectf(t, repr == int(reg.selected), "alias %d must resolve to the selected repr", i)
    }
    other, _, _ := mime_at(reg, 3)
    testing.expectf(t, other != int(reg.selected), "a different repr must not be mistaken for the selected one")
}

@(test)
test_row_columns_do_not_overlap :: proc(t: ^testing.T) {
    // Columns are laid out by arithmetic on constants, so a mis-sized one shows up as text running
    // into its neighbour. Asserting the geometry catches that without looking at a screenshot.
    gui_state := Gui_State {
        frame_buf = {width = POPUP_WIDTH, height = POPUP_MAX_HEIGHT},
    }
    cols := row_columns(&gui_state)

    testing.expectf(
        t,
        cols.regname_x + REGNAME_WIDTH <= cols.preview_x,
        "register name (ends %.0f) overlaps preview (starts %.0f)",
        cols.regname_x + REGNAME_WIDTH,
        cols.preview_x,
    )
    testing.expectf(
        t,
        cols.preview_x + cols.preview_width <= cols.mime_x,
        "preview (ends %.0f) overlaps mime (starts %.0f)",
        cols.preview_x + cols.preview_width,
        cols.mime_x,
    )
    testing.expectf(
        t,
        cols.mime_x + PANEL_MIME_COLUMN_WIDTH <= cols.time_x,
        "mime (ends %.0f) overlaps age (starts %.0f)",
        cols.mime_x + PANEL_MIME_COLUMN_WIDTH,
        cols.time_x,
    )
    testing.expectf(
        t,
        cols.time_x + PANEL_TIME_COLUMN_WIDTH <= cols.right,
        "age (ends %.0f) runs past the panel edge (%.0f)",
        cols.time_x + PANEL_TIME_COLUMN_WIDTH,
        cols.right,
    )
    testing.expectf(t, cols.preview_width > 0, "preview column collapsed to %.0f", cols.preview_width)
}

@(test)
test_column_widths_fit_their_widest_content :: proc(t: ^testing.T) {
    // `monospace 11` renders at 9px per character, measured. These are the widest strings each
    // column can be asked to hold, so a narrower column would clip them.
    PX_PER_CHAR :: 9
    testing.expectf(
        t,
        PANEL_TIME_COLUMN_WIDTH >= lib.RELATIVE_TIMESTAMP_LEN * PX_PER_CHAR,
        "age column is %d, needs %d for `YYYY-MM-DD`",
        PANEL_TIME_COLUMN_WIDTH,
        lib.RELATIVE_TIMESTAMP_LEN * PX_PER_CHAR,
    )
    // Worst case label: the elided mime plus a ` +NN` suffix, inside the pill's own padding.
    PILL_PAD :: 12
    widest_label :: (MIME_LABEL_CHARS + len(" +12")) * PX_PER_CHAR
    testing.expectf(
        t,
        PANEL_MIME_COLUMN_WIDTH >= widest_label + PILL_PAD,
        "mime column is %d, needs %d for an elided mime plus ` +12`",
        PANEL_MIME_COLUMN_WIDTH,
        widest_label + PILL_PAD,
    )
}

@(test)
test_popup_height_fits_the_populated_set :: proc(t: ^testing.T) {
    chrome :: 2 * (PANEL_MARGIN + TEXT_PADDING_Y)

    // Three rows means three rows of height, not a fixed 900.
    three := fake_state(
        {lib.reg_id_from_clipboard_index(0), lib.reg_id_from_clipboard_index(1), lib.reg_id_from_named_index(0)},
        0,
    )
    defer free_fake_state(&three)
    // Spans the clipboard ring and the named registers, so one divider claims its gap too.
    want_three :: chrome + 3 * ROW_HEIGHT + HORZ_RULE_GAP
    testing.expectf(
        t,
        popup_height(&three) == uint(want_three),
        "three rows across two categories should be %d tall, got %d",
        want_three,
        popup_height(&three),
    )

    // An empty set still gets one row, so the panel is visible rather than a sliver.
    empty := fake_state({}, 0)
    defer free_fake_state(&empty)
    testing.expectf(
        t,
        popup_height(&empty) == uint(chrome + ROW_HEIGHT),
        "an empty set should still be one row tall, got %d",
        popup_height(&empty),
    )

    // Every register populated must not exceed the cap, or the panel runs off a short screen.
    full := Gui_State{}
    for id in lib.Reg_Id(0) ..= lib.Reg_Id(lib.MAX_REGS - 1) {
        if !lib.reg_id_is_valid(id) {continue}
        full.regs[id] = lib.Resp_Reg {
            reprs = make([]lib.Resp_Repr, 1),
        }
    }
    defer free_fake_state(&full)
    testing.expectf(
        t,
        popup_height(&full) == POPUP_MAX_HEIGHT,
        "a full register set should clamp to %d, got %d",
        POPUP_MAX_HEIGHT,
        popup_height(&full),
    )
}

@(test)
test_group_breaks_counts_category_changes :: proc(t: ^testing.T) {
    // `populated_regs` emits categories in order, so a change between adjacent rows is a boundary.
    // Counting them from the ids means there is no second list to keep in step with the rows.
    cases := [?]struct {
        rows: []lib.Reg_Id,
        want: int,
    } {
        {{}, 0},
        {{lib.reg_id_from_clipboard_index(0)}, 0},
        // Two rows, same ring: no divider between them.
        {{lib.reg_id_from_clipboard_index(0), lib.reg_id_from_clipboard_index(1)}, 0},
        // Both live selections are one category, despite being two registers.
        {{lib.SELECTION_CLIPBOARD, lib.SELECTION_PRIMARY}, 0},
        // All four categories in display order: three dividers.
        {
            {
                lib.SELECTION_CLIPBOARD,
                lib.reg_id_from_clipboard_index(0),
                lib.reg_id_from_primary_index(0),
                lib.reg_id_from_named_index(0),
            },
            3,
        },
    }
    for c in cases {
        got := group_breaks(c.rows)
        testing.expectf(t, got == c.want, "%d rows produced %d breaks, want %d", len(c.rows), got, c.want)
    }
}

@(test)
test_visible_rows_leave_room_for_dividers :: proc(t: ^testing.T) {
    // A row budget that ignored dividers would promise more rows than fit, clipping the last one by
    // however much height the rules claimed.
    gui_state := Gui_State {
        frame_buf = {width = POPUP_WIDTH, height = POPUP_MAX_HEIGHT},
    }
    rows := visible_row_count(&gui_state)
    worst_case := rows * ROW_HEIGHT + (len(Reg_Category) - 1) * HORZ_RULE_GAP + 2 * (PANEL_MARGIN + TEXT_PADDING_Y)
    testing.expectf(
        t,
        worst_case <= POPUP_MAX_HEIGHT,
        "%d rows plus dividers needs %d, panel is %d",
        rows,
        worst_case,
        POPUP_MAX_HEIGHT,
    )
}

// A targeted mime fetch cannot unmarshal straight into live state: `unmarshal_resp_registers` zeroes
// every slot and only refills the ones the response carried, so a single-register reply would blank
// the rest of the panel. Only the register asked for may cross over.
@(test)
test_adopt_reg_leaves_the_other_registers_alone :: proc(t: ^testing.T) {
    bystander := lib.reg_id_from_clipboard_index(2)
    target := lib.reg_id_from_named_index(0)
    live := fake_state({target, bystander}, 900)
    defer free_fake_state(&live)

    // What a one-register response unmarshals into: the target filled, every other slot zeroed.
    scratch: [lib.MAX_REGS]lib.Resp_Reg
    scratch[target] = lib.Resp_Reg {
        reprs = make([]lib.Resp_Repr, 2),
    }

    adopt_reg(&live.regs, &scratch, target)

    testing.expectf(
        t,
        len(live.regs[target].reprs) == 2,
        "target should hold the fetched entry, got %d reprs",
        len(live.regs[target].reprs),
    )
    testing.expect(
        t,
        !lib.resp_reg_is_empty(live.regs[bystander]),
        "a register absent from the response must survive a targeted fetch",
    )
    testing.expect(
        t,
        lib.resp_reg_is_empty(scratch[target]),
        "the source slot must be cleared so a caller's sweep cannot double-free it",
    )
}
