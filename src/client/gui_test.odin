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
