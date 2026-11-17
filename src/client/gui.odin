package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

import cairo "bindings:cairo"
import pango "bindings:pango"
import pc "bindings:pangocairo"
import xkb "bindings:xkbcommon"
import lib "src:libclipbender"
import wl "wayland:odin-wayland"
import wlr_ls "wayland:wlr-layer-shell"

// Dimensions
POPUP_WIDTH :: 800
// Panel sizes itself to the populated registers and may grow up to this maximum.
POPUP_MAX_HEIGHT :: 900

// An RGBA color with every component on the [0, 1] scale.
Rgba :: distinct [4]f64

// Colors as RGBA hex codes normalized to the [0, 1] scale. TODO: hardcoded for now, theming in config phase.
PANEL_BG :: Rgba{0x2E / 255.0, 0x34 / 255.0, 0x40 / 255.0, 0xF5 / 255.0} // dark gray, slightly translucent
PANEL_BORDER :: Rgba{0x4C / 255.0, 0x56 / 255.0, 0x6A / 255.0, 0xFF / 255.0} // one step lighter than the fill
FG :: Rgba{0xFF / 255.0, 0xFF / 255.0, 0xFF / 255.0, 0xFF / 255.0} // white
// Fully transparent, for clearing the surface outside the panel card.
TRANSPARENT :: Rgba{0, 0, 0, 0}

// The panel is a rounded card inset from the surface, so the surface must be larger than the card and transparent
// outside it.
PANEL_MARGIN :: 12 // surface edge to card edge
PANEL_RADIUS :: 14
PANEL_BORDER_WIDTH :: 1

// The open mime list floats over the rows below its own rather than displacing them: the panel is a
// fixed size, so pushing rows down would run the last one out of it.
DROPDOWN_BG :: Rgba{0x3B / 255.0, 0x42 / 255.0, 0x52 / 255.0, 0xFF / 255.0}
DROPDOWN_SELECTED :: Rgba{0x5E / 255.0, 0x81 / 255.0, 0xAC / 255.0, 0xFF / 255.0}
DROPDOWN_RADIUS :: 8
DROPDOWN_PAD :: 8 // inside the dropdown's own edge
DROPDOWN_INDENT :: 40 // from the panel's text column, so it reads as hanging off its row

// Font as a fontconfig pattern.
FONT_DESC :: "monospace 11"

// Text Layout
TEXT_PADDING_X :: 16 // left margin
TEXT_PADDING_Y :: 16 // top margin
LINE_HEIGHT :: 18 // min spacing between rows, doesn't include font size so needs to be greater than FONT_SIZE

// Main panel measurements
ROW_HEIGHT :: 26
REGNAME_WIDTH :: 26 // register name pill width
PILL_HEIGHT :: 19 // height for pill-style elements
PILL_RADIUS :: 5 // radius for pill-style elements
@(private = "file")
COL_GAP :: 12
PANEL_MIME_COLUMN_WIDTH :: 192 // 16 chars of mime + ` +##` + pill padding, at 9px per character
PANEL_TIME_COLUMN_WIDTH :: 90 // sized for widest possible date (`YYYY-MM-DD`, 90px)
MIME_LABEL_CHARS :: 16 // what the pill elides to, leaving room for a ` +N` suffix

// Dividers between register categories.
RULE_FG :: Rgba{0x4C / 255.0, 0x56 / 255.0, 0x6A / 255.0, 0xFF / 255.0} // dimmed
HORZ_RULE_HEIGHT :: 1
HORZ_RULE_GAP :: 7 // vertical room a horz divider claims, split above and below the line

REGNAME_BG :: Rgba{0x43 / 255.0, 0x4C / 255.0, 0x5E / 255.0, 0xFF / 255.0}
MIME_BG :: Rgba{0x43 / 255.0, 0x4C / 255.0, 0x5E / 255.0, 0xFF / 255.0}
FG_DIM :: Rgba{0xA0 / 255.0, 0xA8 / 255.0, 0xB8 / 255.0, 0xFF / 255.0}

// State of the open mime list. `cursor` indexes `reg`'s mimes and is clamped to that count, never wrapped.
Mime_List_State :: struct {
    reg:    lib.Reg_Id,
    cursor: u16,
}

Frame_Buffer :: struct {
    buffer:   ^wl.buffer,
    shm_pool: ^wl.shm_pool,
    shm_fd:   linux.Fd,
    surface:  ^cairo.Surface,
    ctx:      ^cairo.Context,
    layout:   ^pango.Layout,
    pixels:   [^]u32, // mmap'd pixel data
    width:    uint,
    height:   uint,
}

Keyboard :: struct {
    keyboard:    ^wl.keyboard,
    ctx:         ^xkb.Context,
    keymap:      ^xkb.Keymap,
    state:       ^xkb.State,
    // Keypresses accumulated so far toward a binding. Cleared on dispatch, on an unmatched key, and
    // on unwind.
    pending:     [MAX_PRESSES]Key_Chord,
    pending_len: u8,
}

Gui_State :: struct {
    // Client connection FD to daemon socket
    client_fd:        linux.Fd,
    // General connection state
    display:          ^wl.display,
    registry:         ^wl.registry,
    seat:             ^wl.seat,
    seat_name:        uint,
    compositor:       ^wl.compositor,
    compositor_name:  uint,
    shm:              ^wl.shm,
    shm_name:         uint,
    layer_shell:      ^wlr_ls.layer_shell_v1,
    layer_shell_name: uint,
    running:          bool,
    // Surface-specific state
    surface:          ^wl.surface,
    layer_surface:    ^wlr_ls.layer_surface_v1,
    // Buffer of pixels
    frame_buf:        Frame_Buffer,
    // Keyboard input
    kb:               Keyboard,
    // Context of what "mode" or activity the user is focused in, defines which keymaps are valid
    activity_focus:   Activity_Focus,
    // Index into the populated-register list of the first row drawn. Clamped on every render.
    scroll_row:       int,
    // Only meaningful while `activity_focus == .Mime_List`; that enum is the authority.
    mime_list:        Mime_List_State,
    // Font description resolved by fontconfig. Outlives the buffer.
    font_desc:        ^pango.Font_Description,
    // Register data, indexed by Reg_Id
    regs:             [lib.MAX_REGS]lib.Resp_Reg,
}

//** KEYMAP STUFF**//

// Modifier keys. Caps lock intentionally left out and keysyms are case-insensitive to prevent caps+a being construed as
// shift+a.
Modifier :: enum u8 {
    Ctrl,
    Shift,
    Meta,
    Super,
}
Modifier_Flags :: bit_set[Modifier;u8] // activated modifiers

// A key chord is the activated modifiers plus one key.
Key_Chord :: struct {
    mods:   Modifier_Flags,
    keysym: xkb.Keysym,
}

// Plain type to represent a register name token:
// - clipboard registers `0-9`
// - primary registers `@0-@9`
// - named registers `a-z`
// - live clipboard register `.`
// - live primary register `@.`
//
// Grouping every register under one token is what collapses the table. A single binding covers all 48 names instead of
// one near-duplicate entry each.
Reg_Token :: struct {}

// A single token in a binding's sequence, either the literal chord or we matched a register token name.
Key_Token :: union {
    Key_Chord,
    Reg_Token,
}

// The action a resolved binding carries out.
Action :: enum u8 {
    Set_Reg,
    Clear_Reg,
    Open_Mime_List,
    Scroll_Row_Down,
    Scroll_Row_Up,
    Scroll_Page_Down,
    Scroll_Page_Up,
    Cursor_Down,
    Cursor_Up,
    Commit,
    Unwind,
}

// A keymap is a sequence of tokens with the resulting action.
Keymap :: struct {
    seq:    []Key_Token,
    action: Action,
}

// Reading a register onto the clipboard is one keypress because it's the common usage of the GUI. All other register
// setting goes through the <space> leader key. TODO: maybe I'll make the leader configurable or something later.
MAIN_KEYMAPS := []Keymap {
    {{Reg_Token{}}, .Set_Reg},
    {{Key_Chord{{}, xkb.KEYSYM_space}, Reg_Token{}, Reg_Token{}}, .Set_Reg},
    {{Key_Chord{{}, xkb.KEYSYM_equal}, Reg_Token{}}, .Open_Mime_List},
    {{Key_Chord{{}, xkb.KEYSYM_minus}, Reg_Token{}}, .Clear_Reg},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_e}}, .Scroll_Row_Down},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_y}}, .Scroll_Row_Up},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_d}}, .Scroll_Page_Down},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_u}}, .Scroll_Page_Up},
}

// All literal navigation chords.
MIME_LIST_KEYMAPS := []Keymap {
    {{Key_Chord{{}, xkb.KEYSYM_j}}, .Cursor_Down},
    {{Key_Chord{{}, xkb.KEYSYM_Down}}, .Cursor_Down},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_n}}, .Cursor_Down},
    {{Key_Chord{{}, xkb.KEYSYM_k}}, .Cursor_Up},
    {{Key_Chord{{}, xkb.KEYSYM_Up}}, .Cursor_Up},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_p}}, .Cursor_Up},
    {{Key_Chord{{}, xkb.KEYSYM_Return}}, .Commit},
}

// Unwind one level e.g. close mime list, drop pending key sequence, or dismiss the popup otherwise. Always matched
// against the current key press independent of the pending sequence.
UNWIND_KEYMAPS := []Keymap {
    {{Key_Chord{{}, xkb.KEYSYM_Escape}}, .Unwind},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_bracketleft}}, .Unwind},
    {{Key_Chord{{.Ctrl}, xkb.KEYSYM_c}}, .Unwind},
}

// You might think of this as the "mode" we're in. We need to define what activity we're focused in to determine which
// keymaps to match against, sort of like vim's `nmap`/`imap`/`vmap`, etc.
Activity_Focus :: enum u8 {
    Main, // the main register panel
    Mime_List, // a register's mime list is open
    //Edit, // TODO: used for inline edit mode in the future
}

// Get the keymaps for whatever activity we're currently focused in.
keymaps_for :: proc(activity_focus: Activity_Focus) -> []Keymap {
    switch activity_focus {
    case .Main:
        return MAIN_KEYMAPS
    case .Mime_List:
        return MIME_LIST_KEYMAPS
    }
    return nil
}


// Captured args from a key sequence (currently these args are always going to be registers which is why we have `regs`,
// but perhaps this changes in the future), with the modifiers held on the last keypress of a register such that we can
// differentiate between `a` and `A` for overwrite or append on a named register.
//
// Index 0 is the src and index 1 is the dst.
MAX_PRESSES :: 1 + 2 * lib.MAX_REG_NAME_LEN // longest key sequence the tables can express (`<space>` + 2 two-key regs)
MAX_CAPTURES :: 2 // max amount of args for any action we may need to account for.
Captures :: struct {
    regs: [MAX_CAPTURES]lib.Reg_Id,
    mods: [MAX_CAPTURES]Modifier_Flags,
    len:  u8,
}

// From the captures of a keymap, return the needed values to invoke a set command through the daemon, i.e. a register
// operation's operands and mode. Ignore shift for the source register.
//
// If we have a single capture, we automatically treat that as loading that register as src into the live selection
// clipboard. This is the most common functionality we want to short-circuit via the single the keymaps that consist of
// a single register name.
reg_args :: proc(captures: Captures) -> (src: lib.Reg_Id, dst: lib.Reg_Id, mode: lib.Set_Mode, ok: bool) {
    switch captures.len {
    case 1:
        src = captures.regs[0]
        return src, lib.SELECTION_CLIPBOARD, .OVERWRITE, true
    case 2:
        src = captures.regs[0]
        dst = captures.regs[1]
        mode = .OVERWRITE
        if lib.reg_id_is_named(dst) && .Shift in captures.mods[1] {mode = .APPEND}
        return src, dst, mode, true
    case:
        return 0, 0, .OVERWRITE, false
    }
}

// Modifiers/lock keys arrive as ordinary key events in the `key()` callback as well as `modifiers()`. We already update
// the modifiers in the kb state from `modifiers()`, so we need to filter these out in `key()` to avoid recognizing them
// as an invalid keypress in a keymap.
keysym_is_modifier :: proc(keysym: xkb.Keysym) -> bool {
    return(
        (keysym >= xkb.KEYSYM_Shift_L && keysym <= xkb.KEYSYM_Hyper_R) ||
        (keysym >= xkb.KEYSYM_ISO_Lock && keysym <= xkb.KEYSYM_ISO_Level5_Lock) ||
        keysym == xkb.KEYSYM_Mode_switch ||
        keysym == xkb.KEYSYM_Num_Lock \
    )
}


// Consume one register name from the front of `presses`, reporting the modifiers held on its final
// keypress.
parse_reg_token :: proc(
    presses: []Key_Chord,
) -> (
    reg: lib.Reg_Id,
    mods: Modifier_Flags,
    consumed: int,
    status: lib.Match_Status,
) {
    if len(presses) == 0 {return 0, {}, 0, .Partial}

    // Build candidate string for potential register name
    buf: [lib.MAX_REG_NAME_LEN]u8
    avail := 0
    for avail < len(presses) && avail < lib.MAX_REG_NAME_LEN {
        // Exit early if non-Latin-1 keysym or any mods other than shift
        if presses[avail].keysym > 0x7F || presses[avail].mods - {.Shift} != {} {break}

        buf[avail] = u8(presses[avail].keysym) // Latin-1 keysyms equal their codepoint
        avail += 1
    }

    // Match the longest name possible (e.g. if we were given `@3` we don't want to match just `3`).
    for name_len := avail; name_len >= 1; name_len -= 1 {
        if id, name := lib.reg_id_from_string(string(buf[:name_len])); name == .Hit {
            return id, presses[name_len - 1].mods, name_len, .Hit
        }
    }

    // Check if the full candidate partially matches a register id (e.g. `@`).
    if avail == len(presses) {
        if _, name := lib.reg_id_from_string(string(buf[:avail])); name == .Partial {
            return 0, {}, 0, .Partial
        }
    }
    return 0, {}, 0, .Miss
}

// Match a sequence of key presses against a single keymap. If `presses` matches a prefix of `keymap` but not the entire
// thing, it returns `Partial`. If we successfully match a register name or known keymap and have no leftover key
// presses, it's a `Hit`, otherwise a `Miss`.
match_keymap :: proc(keymap: Keymap, presses: []Key_Chord) -> (captures: Captures, status: lib.Match_Status) {
    press_index := 0
    for token in keymap.seq {
        if press_index >= len(presses) {return captures, .Partial}
        switch tok in token {
        // match the literal keychord
        case Key_Chord:
            if tok != presses[press_index] {return captures, .Miss}
            press_index += 1
        // or try to parse a register from this press onward
        case Reg_Token:
            _ = tok // empty value, just discard it
            reg, mods, consumed, reg_status := parse_reg_token(presses[press_index:])
            if reg_status != .Hit {return captures, reg_status}
            assert(captures.len < MAX_CAPTURES, "binding names more register slots than MAX_CAPTURES")
            captures.regs[captures.len] = reg
            captures.mods[captures.len] = mods
            captures.len += 1
            press_index += consumed // advance the press index by the number we had to consume during parsing
        }
    }
    if press_index < len(presses) {return captures, .Miss}     // input left over
    return captures, .Hit
}

// Match user-invoked key presses against a list of defined keymaps that result in some action.
resolve_keymap :: proc(
    keymaps: []Keymap,
    presses: []Key_Chord,
) -> (
    keymap: Keymap,
    captures: Captures,
    status: lib.Match_Status,
) {
    partial := false
    for candidate in keymaps {
        caps, candidate_status := match_keymap(candidate, presses)
        if candidate_status == .Hit {return candidate, caps, .Hit}
        if candidate_status == .Partial {partial = true}
    }
    return {}, {}, partial ? .Partial : .Miss
}

// Pack the modifiers xkb currently reports into our own set.
active_mods :: proc(state: ^xkb.State) -> (mods: Modifier_Flags) {
    MODS_EFFECTIVE :: xkb.State_Component.XKB_STATE_MODS_EFFECTIVE
    if xkb.xkb_state_mod_name_is_active(state, xkb.MOD_NAME_CTRL, MODS_EFFECTIVE) == 1 {mods += {.Ctrl}}
    if xkb.xkb_state_mod_name_is_active(state, xkb.MOD_NAME_SHIFT, MODS_EFFECTIVE) == 1 {mods += {.Shift}}
    if xkb.xkb_state_mod_name_is_active(state, xkb.MOD_NAME_MOD1, MODS_EFFECTIVE) == 1 {mods += {.Meta}}
    if xkb.xkb_state_mod_name_is_active(state, xkb.MOD_NAME_MOD4, MODS_EFFECTIVE) == 1 {mods += {.Super}}
    return
}

// Unwind one level in this order:
// - abandon a partially-typed sequence
// - leave the current activity
// - dismiss
unwind :: proc(gui_state: ^Gui_State) {
    if gui_state.kb.pending_len > 0 {
        gui_state.kb.pending_len = 0
        return
    }
    if gui_state.activity_focus != .Main {
        gui_state.activity_focus = .Main
        gui_render(gui_state)
        return
    }
    gui_state.running = false
}

// Counts total mimes across a single register
mime_count :: proc(reg: lib.Resp_Reg) -> (count: int) {
    for repr in reg.reprs {count += len(repr.mimes)}
    return
}

// The nth mime in flattened order, with the repr it belongs to. The repr index is what decides whether committing needs
// a fetch.
mime_at :: proc(reg: lib.Resp_Reg, n: int) -> (repr_index: int, mime: string, ok: bool) {
    seen := 0
    for repr, i in reg.reprs {
        if n < seen + len(repr.mimes) {
            return i, repr.mimes[n - seen], true
        }
        seen += len(repr.mimes)
    }
    return 0, "", false
}

// Where the cursor opens to in the mime list. The first mime of the repr was already chosen by the daemon's policy, so
// the list starts on what the row is currently showing rather than at the top.
selected_mime_index :: proc(reg: lib.Resp_Reg) -> int {
    if lib.resp_reg_selected(reg) == nil {return 0}
    index := 0
    for repr, i in reg.reprs {
        if i == int(reg.selected) {return index}
        index += len(repr.mimes)
    }
    return 0
}

// Fetch one register under an exact mime, replacing its entry so the row renders that blob.
fetch_reg_mime :: proc(gui_state: ^Gui_State, reg: lib.Reg_Id, mime: string) -> (err: Maybe(string)) {
    msg: [lib.MAX_MSG_SIZE]byte
    filter := transmute(lib.Cmd_Get_Filter)(u64(1) << u64(reg)) // single bit set on the Reg ID
    groups := [?]lib.Cmd_Get_Group{{filter = filter, policy = lib.Exact_Mime(mime)}}

    // Marshal + send GET request to daemon
    written := lib.marshal_cmd_get(groups[:], msg[:])
    if _, send_err := linux.send(gui_state.client_fd, msg[:written], {.NOSIGNAL}); send_err != nil {
        return fmt.tprintf(
            "Failed sending GET for `%s` mime `%s`: errno %v",
            lib.reg_id_to_string(reg),
            mime,
            send_err,
        )
    }

    // Receive response from daemon
    resp_buf: [lib.MAX_MSG_SIZE]u8
    bytes_read, recv_err := linux.recv(gui_state.client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        return fmt.tprintf("No response fetching `%s` mime `%s`: errno %v", lib.reg_id_to_string(reg), mime, recv_err)
    }

    switch lib.Resp_Status(resp_buf[0]) {
    case .REGISTERS:
        // Unmarshals into the same array the full fetch uses, so only this register's slot changes.
        if _, unmarshal_err := lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &gui_state.regs);
           unmarshal_err != nil {
            return fmt.tprintf("Malformed response: %s", unmarshal_err.?)
        }
    case .ERROR:
        return fmt.tprintf("%s", string(resp_buf[1:bytes_read]))
    case .OK:
        return fmt.tprint("Unexpected OK response to a GET")
    }
    return nil
}

// Send a SET to the daemon and act on its reply.
send_set_reg :: proc(gui_state: ^Gui_State, dest: lib.Reg_Id, src: lib.Reg_Id, mode: lib.Set_Mode) {
    msg: [lib.CMD_SET_REG_SIZE]byte
    written := lib.marshal_cmd_set_reg(dest, src, mode, msg[:])
    _, send_err := linux.send(gui_state.client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        log.errorf(
            "Failed sending SET reg `%s` from reg `%s` to daemon: errno %v",
            lib.reg_id_to_string(dest),
            lib.reg_id_to_string(src),
            send_err,
        )
        return
    }

    resp_buf: [RESP_BUF_SMALL]u8
    bytes_read, recv_err := linux.recv(gui_state.client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        log.errorf(
            "Failed receiving SET reg `%s` from reg `%s`: errno %v",
            lib.reg_id_to_string(dest),
            lib.reg_id_to_string(src),
            recv_err,
        )
        return
    }

    switch lib.Resp_Status(resp_buf[0]) {
    case .OK:
        // TODO: highlight green or something, indicate success
        gui_state.running = false
    case .ERROR:
        log.errorf(
            "Failed setting register `%s` from register `%s`: %v",
            lib.reg_id_to_string(dest),
            lib.reg_id_to_string(src),
            string(resp_buf[1:bytes_read]),
        )
    // TODO: highlight red or something, indicate failure
    case .REGISTERS:
        // wtf how'd we get here
        log.error("Unexpected REGISTERS response for `set` command")
    }
}

// Send a CLEAR to the daemon and act on its reply.
send_clear_reg :: proc(gui_state: ^Gui_State, reg: lib.Reg_Id) {
    msg: [lib.CMD_CLEAR_SIZE]byte
    written := lib.marshal_cmd_clear(reg, msg[:])
    _, send_err := linux.send(gui_state.client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        log.errorf("Failed sending CLEAR reg `%s`: errno %v", lib.reg_id_to_string(reg), send_err)
        return
    }

    resp_buf: [RESP_BUF_SMALL]u8
    bytes_read, recv_err := linux.recv(gui_state.client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        log.errorf("Failed receiving CLEAR reg `%s`: errno %v", lib.reg_id_to_string(reg), recv_err)
        return
    }

    switch lib.Resp_Status(resp_buf[0]) {
    case .OK:
        // TODO: needs confirmation step
        gui_state.running = false
    case .ERROR:
        log.errorf("Failed clearing register `%s`: %v", lib.reg_id_to_string(reg), string(resp_buf[1:bytes_read]))
    case .REGISTERS:
        // wtf how'd we get here
        log.error("Unexpected REGISTERS response for `clear` command")
    }
}

// Render the chosen mime's blob in place of the row's current one. Note: this doesn't mutate the clipboard at all until
// the user invokes the action to set a register/clipboard.
commit_mime :: proc(gui_state: ^Gui_State) {
    reg := gui_state.mime_list.reg
    entry := gui_state.regs[reg]
    repr_index, mime, ok := mime_at(entry, int(gui_state.mime_list.cursor))
    if !ok {
        log.errorf("mime cursor %d is past the end for `%s`", gui_state.mime_list.cursor, lib.reg_id_to_string(reg))
        gui_state.activity_focus = .Main
        gui_render(gui_state)
        return
    }

    // If same repr, there's nothing we need to fetch, we're already seeing the correct data.
    if lib.resp_reg_selected(entry) != nil && repr_index == int(entry.selected) {
        log.debugf("`%s` already showing repr %d (`%s`)", lib.reg_id_to_string(reg), repr_index, mime)
    } else if err := fetch_reg_mime(gui_state, reg, mime); err != nil {
        log.errorf("%s", err.?)
        // TODO: red flash and the row keeps showing its previous mime
    }

    gui_state.activity_focus = .Main
    gui_render(gui_state)
}

// Carry out a resolved binding's action.
perform_action :: proc(gui_state: ^Gui_State, keymap: Keymap, captures: Captures) {
    switch keymap.action {
    case .Set_Reg:
        src, dst, mode, ok := reg_args(captures)
        if !ok {
            log.errorf("`%v` resolved with %d captures", keymap.action, captures.len)
            return
        }
        send_set_reg(gui_state, dst, src, mode)
    case .Clear_Reg:
        if captures.len < 1 {
            log.error("`Clear_Reg` resolved with no register")
            return
        }
        send_clear_reg(gui_state, captures.regs[0])
    case .Open_Mime_List:
        // TODO: need to implement dropdown mime list
        log.debugf("Open_Mime_List for `%s` is not implemented yet", lib.reg_id_to_string(captures.regs[0]))
    case .Scroll_Row_Down, .Scroll_Row_Up, .Scroll_Page_Down, .Scroll_Page_Up:
        // TODO: need to implement scrolling
        log.debugf("%v is not implemented yet", keymap.action)
    case .Cursor_Down, .Cursor_Up, .Commit:
        log.debugf("%v is not implemented yet", keymap.action)
    case .Unwind:
        unwind(gui_state)
    }
}

gui_init_surface :: proc(gui_state: ^Gui_State) {
    // Init wl_surface and wlr_layer_surface
    gui_state.surface = wl.compositor_create_surface(gui_state.compositor)
    gui_state.layer_surface = wlr_ls.layer_shell_v1_get_layer_surface(
        gui_state.layer_shell,
        gui_state.surface,
        nil, // output = `nil` means let the compositor choose
        .overlay,
        "clipbender",
    )

    // Configure layer surface
    width: uint = POPUP_WIDTH
    height := popup_height(gui_state)
    wlr_ls.layer_surface_v1_set_size(gui_state.layer_surface, width, height)
    wlr_ls.layer_surface_v1_set_keyboard_interactivity(gui_state.layer_surface, .on_demand)

    // Add listener
    wlr_ls.layer_surface_v1_add_listener(gui_state.layer_surface, &layer_surface_listener, rawptr(gui_state))
    wl.surface_commit(gui_state.surface)
}

// Resolve the UI font once. Outlives the frame buffer.
gui_init_font :: proc(gui_state: ^Gui_State) -> bool {
    gui_state.font_desc = pango.pango_font_description_from_string(FONT_DESC)
    if gui_state.font_desc == nil {
        log.errorf("Failed to resolve a font from %q", FONT_DESC)
        return false
    }
    log.debugf("Resolved font description %q", FONT_DESC)
    return true
}

// Wrap the mapped shm memory in a cairo surface and build the layout that draws into it. Called after every
// `gui_init_buffer` since all three objects reference `pixels` and the buffer is recreated on configure.
gui_init_cairo :: proc(gui_state: ^Gui_State) -> (err: Maybe(string)) {
    fb := &gui_state.frame_buf
    width := i32(fb.width)
    height := i32(fb.height)

    // Ensure stride of shm buffer matches what cairo expects
    stride := cairo.cairo_format_stride_for_width(.ARGB32, width)
    if stride != width * 4 {
        return fmt.tprintf(
            "cairo wants a stride of %d for %d px ARGB32, the shm buffer uses %d",
            stride,
            width,
            width * 4,
        )
    }

    fb.surface = cairo.cairo_image_surface_create_for_data(cast([^]u8)fb.pixels, .ARGB32, width, height, stride)
    if status := cairo.cairo_surface_status(fb.surface); status != .SUCCESS {
        return fmt.tprintf("cairo surface: %s", cairo.cairo_status_to_string(status))
    }

    fb.ctx = cairo.cairo_create(fb.surface)
    if status := cairo.cairo_status(fb.ctx); status != .SUCCESS {
        return fmt.tprintf("cairo context: %s", cairo.cairo_status_to_string(status))
    }

    // Reuse layout for every row
    fb.layout = pc.pango_cairo_create_layout(fb.ctx)
    if fb.layout == nil {
        return fmt.tprint("Failed to create a pango layout")
    }
    pango.pango_layout_set_font_description(fb.layout, gui_state.font_desc)
    // Ellipsize rather than wrap, so one long register cannot push the rest off the popup. Pango cuts on a grapheme
    // boundary.
    pango.pango_layout_set_width(fb.layout, (width - 2 * TEXT_PADDING_X) * pango.SCALE)
    pango.pango_layout_set_ellipsize(fb.layout, .END)

    return nil
}

gui_init_buffer :: proc(gui_state: ^Gui_State) -> (err: Maybe(string)) {
    // Create shared memory fd
    errno: linux.Errno
    gui_state.frame_buf.shm_fd, errno = linux.memfd_create("clipbender", {.CLOEXEC})
    if errno != .NONE {
        return fmt.tprintf("Failed to create mem-backed shm FD: errno %v", errno)
    }

    // Truncate size to 4 bytes per pixel (#argb8888)
    width := gui_state.frame_buf.width
    height := gui_state.frame_buf.height
    area_bytes := 4 * width * height
    errno = linux.ftruncate(gui_state.frame_buf.shm_fd, i64(area_bytes))
    if errno != .NONE {
        return fmt.tprintf("Failed to truncate shm FD: errno %v", errno)
    }

    // Map FD into address space to write pixels to
    pixels_ptr: rawptr
    pixels_ptr, errno = linux.mmap(0, area_bytes, {.READ, .WRITE}, {.SHARED}, gui_state.frame_buf.shm_fd, 0)
    if errno != .NONE {
        return fmt.tprintf("Failed to mmap shm FD for pixel array: errno %v", errno)
    }
    gui_state.frame_buf.pixels = cast([^]u32)pixels_ptr

    // Create shm_pool
    gui_state.frame_buf.shm_pool = wl.shm_create_pool(gui_state.shm, int(gui_state.frame_buf.shm_fd), int(area_bytes))

    // Create buffer from the pool and attach to surface
    gui_state.frame_buf.buffer = wl.shm_pool_create_buffer(
        gui_state.frame_buf.shm_pool,
        0,
        int(width),
        int(height),
        int(width * 4), // stride is bytes per row, we have 4 bytes for every pixel in width
        .argb8888,
    )
    wl.surface_attach(gui_state.surface, gui_state.frame_buf.buffer, 0, 0)

    // Commit configuration
    wl.surface_commit(gui_state.surface)

    return nil
}

gui_init :: proc(gui_state: ^Gui_State) -> Maybe(string) {
    gui_state.running = true

    gui_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if gui_state.display == nil {
        return fmt.tprint("Failed to connect to default Wayland display")
    }

    // Get registry
    gui_state.registry = wl.display_get_registry(gui_state.display)
    wl.registry_add_listener(gui_state.registry, &registry_listener, gui_state)

    // Roundtrip to receive registry events (binds seat, compositor, shm, and layer_shell)
    wl.display_roundtrip(gui_state.display)
    if gui_state.seat == nil {
        return fmt.tprint("Failed to bind Wayland seat")
    }
    if gui_state.compositor == nil {
        return fmt.tprint("Failed to bind Wayland compositor")
    }
    if gui_state.shm == nil {
        return fmt.tprint("Failed to bind Wayland shm")
    }
    if gui_state.layer_shell == nil {
        return fmt.tprint("Failed to bind Wayland wlr_layer_shell")
    }

    // Init surface resources and commit
    gui_init_surface(gui_state)
    if gui_state.surface == nil {
        return fmt.tprint("Failed to init Wayland surface")
    }
    if gui_state.layer_surface == nil {
        return fmt.tprint("Failed to init Wayland wlr_layer_surface")
    }

    // Initialize font info (must be before roundtrip since configure callback may render)
    if !gui_init_font(gui_state) {
        return fmt.tprint("Failed to initialize font from file at any known path")
    }

    // Add seat listener to get keyboard
    wl.seat_add_listener(gui_state.seat, &seat_listener, gui_state)

    // Roundtrip to receive configure event for layer_surface_listener
    wl.display_roundtrip(gui_state.display)

    return nil
}

gui_cleanup_cairo :: proc(gui_state: ^Gui_State) {
    fb := &gui_state.frame_buf
    // Reverse of creation order (pixels -> surface -> context -> layout)
    if fb.layout != nil {
        pango.g_object_unref(fb.layout) // GOBJECTTTTT!!!!
        fb.layout = nil
    }
    if fb.ctx != nil {
        cairo.cairo_destroy(fb.ctx)
        fb.ctx = nil
    }
    if fb.surface != nil {
        cairo.cairo_surface_destroy(fb.surface)
        fb.surface = nil
    }
}

gui_cleanup_font :: proc(gui_state: ^Gui_State) {
    if gui_state.font_desc != nil {
        pango.pango_font_description_free(gui_state.font_desc)
        gui_state.font_desc = nil
    }
    // Release pango's own reference to the process-wide default font map.
    pc.pango_cairo_font_map_set_default(nil)
}

gui_cleanup_keyboard :: proc(gui_state: ^Gui_State) {
    if gui_state.kb.state != nil {xkb.xkb_state_unref(gui_state.kb.state)}
    if gui_state.kb.keymap != nil {xkb.xkb_keymap_unref(gui_state.kb.keymap)}
    if gui_state.kb.ctx != nil {xkb.xkb_context_unref(gui_state.kb.ctx)}
    if gui_state.kb.keyboard != nil {wl.keyboard_release(gui_state.kb.keyboard)}
}

gui_cleanup_buffer :: proc(gui_state: ^Gui_State) {
    // Cairo surface borrows `pixels`, so clean up cairo first.
    gui_cleanup_cairo(gui_state)
    if gui_state.frame_buf.buffer != nil {wl.buffer_destroy(gui_state.frame_buf.buffer)}
    if gui_state.frame_buf.shm_pool != nil {wl.shm_pool_destroy(gui_state.frame_buf.shm_pool)}
    if gui_state.frame_buf.pixels != nil {
        linux.munmap(rawptr(gui_state.frame_buf.pixels), 4 * gui_state.frame_buf.width * gui_state.frame_buf.height)
    }
    _ = linux.close(gui_state.frame_buf.shm_fd)
}

gui_cleanup_surface :: proc(gui_state: ^Gui_State) {
    if gui_state.layer_surface != nil {wlr_ls.layer_surface_v1_destroy(gui_state.layer_surface)}
    if gui_state.surface != nil {wl.surface_destroy(gui_state.surface)}
}

gui_cleanup :: proc(gui_state: ^Gui_State) {
    // Cleanup register data (indexed by Reg_Id; empty slots free harmlessly)
    for &entry in gui_state.regs {
        lib.free_resp_reg(&entry)
    }
    // Cleanup font
    gui_cleanup_font(gui_state)
    // Cleanup keyboard
    gui_cleanup_keyboard(gui_state)
    // Cleanup buffer
    gui_cleanup_buffer(gui_state)
    // Cleanup surface
    gui_cleanup_surface(gui_state)
    // Cleanup connection state
    if gui_state.layer_shell != nil {wlr_ls.layer_shell_v1_destroy(gui_state.layer_shell)}
    if gui_state.shm != nil {wl.shm_destroy(gui_state.shm)}
    if gui_state.compositor != nil {wl.compositor_destroy(gui_state.compositor)}
    if gui_state.seat != nil {wl.seat_release(gui_state.seat)}
    wl.registry_destroy(gui_state.registry)
    wl.display_disconnect(gui_state.display)

}

registry_listener := wl.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            gui_state.seat = cast(^wl.seat)wl.registry_bind(registry, name_, &wl.seat_interface, 1)
            gui_state.seat_name = name_
        case "wl_compositor":
            gui_state.compositor = cast(^wl.compositor)wl.registry_bind(registry, name_, &wl.compositor_interface, 1)
            gui_state.compositor_name = name_
        case "wl_shm":
            gui_state.shm = cast(^wl.shm)wl.registry_bind(registry, name_, &wl.shm_interface, 1)
            gui_state.shm_name = name_
        case "zwlr_layer_shell_v1":
            gui_state.layer_shell = cast(^wlr_ls.layer_shell_v1)wl.registry_bind(
                registry,
                name_,
                &wlr_ls.layer_shell_v1_interface,
                1,
            )
            gui_state.layer_shell_name = name_
        case:
            return
        }
        log.debugf("Successfully bound Wayland interface `%s`", interface_)
    },
    global_remove = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        if name_ == gui_state.seat_name ||
           name_ == gui_state.compositor_name ||
           name_ == gui_state.shm_name ||
           name_ == gui_state.layer_shell_name {
            interface: string
            switch name_ {
            case gui_state.seat_name:
                interface = "wl_seat"
            case gui_state.compositor_name:
                interface = "wl_compositor"
            case gui_state.shm_name:
                interface = "wl_shm"
            case gui_state.layer_shell_name:
                interface = "zwlr_layer_shell_v1"
            }
            log.errorf("Critical Wayland global removed `%s`, shutting down", interface)
            // TODO: Handle exit
        }
    },
}

layer_surface_listener := wlr_ls.layer_surface_v1_listener {
    configure = proc "c" (
        data: rawptr,
        layer_surface_v1: ^wlr_ls.layer_surface_v1,
        serial_: uint,
        width_: uint,
        height_: uint,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received zwlr_layer_surface_v1::configure event")

        if width_ == 0 || height_ == 0 {
            // The compositor left the size to us, so fall back to the same content-derived height
            // the surface was created with rather than a fixed default.
            gui_state.frame_buf.width = POPUP_WIDTH
            gui_state.frame_buf.height = popup_height(gui_state)
        } else {
            gui_state.frame_buf.width = width_
            gui_state.frame_buf.height = height_
        }
        wlr_ls.layer_surface_v1_set_size(layer_surface_v1, gui_state.frame_buf.width, gui_state.frame_buf.height)

        // Must ack configure before attach/commit
        wlr_ls.layer_surface_v1_ack_configure(layer_surface_v1, serial_)

        // Clear buf if not empty
        if gui_state.frame_buf.pixels != nil {
            gui_cleanup_buffer(gui_state)
        }
        // Init buf, attach to surface, and commit surface
        err := gui_init_buffer(gui_state)
        if err != nil {
            log.errorf("Failed to init GUI frame buffer: %v", err.?)
            gui_state.running = false
            return
        }
        // The cairo surface wraps the buffer that was just created, so it is rebuilt on every configure too.
        if cairo_err := gui_init_cairo(gui_state); cairo_err != nil {
            log.errorf("Failed to init cairo: %v", cairo_err.?)
            gui_state.running = false
            return
        }

        // Render the GUI pixels if we've already fetched registers
        gui_render(gui_state)
    },
    closed = proc "c" (data: rawptr, layer_surface_v1: ^wlr_ls.layer_surface_v1) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received zwlr_layer_surface_v1::closed event")
        gui_state.running = false
    },
}

// We don't need the name callback here, we're only going to really use one seat
seat_listener := wl.seat_listener {
    capabilities = proc "c" (data: rawptr, seat: ^wl.seat, capabilities_: wl.seat_capability) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received wl_seat::capabilities event")

        if uint(capabilities_) & uint(wl.seat_capability.keyboard) != 0 {
            gui_state.kb.keyboard = wl.seat_get_keyboard(seat)
            wl.keyboard_add_listener(gui_state.kb.keyboard, &keyboard_listener, gui_state)
        }
    },
    name = proc "c" (data: rawptr, seat: ^wl.seat, name_: cstring) {},
}

keyboard_listener := wl.keyboard_listener {
    keymap = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        format_: wl.keyboard_keymap_format,
        fd_: int,
        size_: uint,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        if format_ != .xkb_v1 {
            log.error("Unsupported keymap format")
            return
        }

        // mmap the keymap fd
        map_ptr, mmap_err := linux.mmap(0, size_, {.READ}, {.PRIVATE}, cast(linux.Fd)fd_, 0)
        linux.close(cast(linux.Fd)fd_)
        if mmap_err != .NONE {
            log.error("Failed to mmap keymap fd: errno %v", mmap_err)
            return
        }
        defer linux.munmap(map_ptr, size_)

        // Create xkb context if not yet created
        if gui_state.kb.ctx == nil {
            gui_state.kb.ctx = xkb.xkb_context_new(.XKB_CONTEXT_NO_FLAGS)
            if gui_state.kb.ctx == nil {
                log.error("Failed to create xkb context")
                return
            }
        }

        // Release previous keymap/state if exists
        if gui_state.kb.state != nil {xkb.xkb_state_unref(gui_state.kb.state)}
        if gui_state.kb.keymap != nil {xkb.xkb_keymap_unref(gui_state.kb.keymap)}

        // Create keymap from the mmap'd string
        gui_state.kb.keymap = xkb.xkb_keymap_new_from_string(
            gui_state.kb.ctx,
            cast(cstring)map_ptr,
            .XKB_KEYMAP_FORMAT_TEXT_V1,
            .XKB_KEYMAP_COMPILE_NO_FLAGS,
        )
        if gui_state.kb.keymap == nil {
            log.error("Failed to create xkb keymap from compositor keymap string")
            return
        }

        // Create state from keymap
        gui_state.kb.state = xkb.xkb_state_new(gui_state.kb.keymap)
        if gui_state.kb.state == nil {
            log.error("Failed to create xkb state")
            return
        }

        log.debug("xkb keymap and state initialized successfully")
    },
    enter = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface, keys_: wl.array) {},
    leave = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received wl_keyboard::leave event")
        gui_state.running = false
    },
    key = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        serial_: uint,
        time_: uint,
        key_: uint,
        state_: wl.keyboard_key_state,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        // Releases carry no meaning for a binding and repeats are not delivered by the compositor at all because a
        // Wayland client drives its own from `repeat_info`, which is not implemented yet.
        if state_ != .pressed {return}
        if gui_state.kb.state == nil {return}

        // evdev keycodes need +8 offset for xkbcommon
        keycode := xkb.Keycode(key_ + 8)

        // Use the keysym (not the UTF-32 codepoint) as the logical key for dispatch. The keysym accounts for the user's
        // layout and any remaps, and it is NOT subject to the control-character transformation that
        // `xkb_state_key_get_utf32` applies (e.g. <C-a> yields codepoint 1, but keysym stays `XKB_KEY_a`). For the
        // ASCII printable range, keysym values equal their ASCII codepoint, so `rune(keysym)` is the char.
        keysym := xkb.xkb_state_key_get_one_sym(gui_state.kb.state, keycode)

        // Modifier keys are reported in every chord's `mods`, so don't handle key presses that are exclusively
        // reporting the modifier press itself.
        if keysym_is_modifier(keysym) {return}

        chord := Key_Chord{active_mods(gui_state.kb.state), keysym}
        log.debugf("Key pressed: keysym=%d mods=%v", keysym, chord.mods)

        // Match unwind against the bare keypress, the sequence doesn't matter if the user wants to cancel.
        if _, _, status := resolve_keymap(UNWIND_KEYMAPS, {chord}); status == .Hit {
            unwind(gui_state)
            return
        }

        kb := &gui_state.kb
        if kb.pending_len >= MAX_PRESSES {
            log.errorf("pending sequence outran MAX_PRESSES (%d); resetting", MAX_PRESSES)
            kb.pending_len = 0
            return
        }
        kb.pending[kb.pending_len] = chord
        kb.pending_len += 1

        keymap, captures, status := resolve_keymap(keymaps_for(gui_state.activity_focus), kb.pending[:kb.pending_len])
        switch status {
        case .Partial:
            // A binding could still complete, so hold the buffer and wait for the next press.
            return
        case .Miss:
            log.debugf("no binding for %v", kb.pending[:kb.pending_len])
            kb.pending_len = 0
        case .Hit:
            kb.pending_len = 0
            perform_action(gui_state, keymap, captures)
        }
    },
    modifiers = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        serial_: uint,
        mods_depressed_: uint,
        mods_latched_: uint,
        mods_locked_: uint,
        group_: uint,
    ) {
        gui_state := cast(^Gui_State)data
        if gui_state.kb.state == nil {return}
        xkb.xkb_state_update_mask(
            gui_state.kb.state,
            cast(xkb.Mod_Mask)mods_depressed_,
            cast(xkb.Mod_Mask)mods_latched_,
            cast(xkb.Mod_Mask)mods_locked_,
            cast(xkb.Layout_Index)0,
            cast(xkb.Layout_Index)0,
            cast(xkb.Layout_Index)group_,
        )
    },
    repeat_info = proc "c" (data: rawptr, keyboard: ^wl.keyboard, rate_: int, delay_: int) {},
}

gui_fetch_registers :: proc(client_fd: linux.Fd, gui_state: ^Gui_State) -> (err: Maybe(string)) {
    // Send GET message for all registers. The GUI renders content, so it wants the richest representation.
    msg: [lib.MAX_MSG_SIZE]byte
    groups := [?]lib.Cmd_Get_Group{{filter = lib.CMD_GET_FILTER_ALL, policy = lib.Ranked_Policy.VISUAL}}
    written := lib.marshal_cmd_get(groups[:], msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        return fmt.tprintf("Failed sending GET to daemon: errno %v", send_err)
    }

    // Receive response from daemon
    resp_buf: [lib.MAX_MSG_SIZE]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        return fmt.tprintf("No response from daemon when fetching registers: errno %v", recv_err)
    }

    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        return fmt.tprint("Unexpected OK response when fetching registers")
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        return fmt.tprintf("%s", err_msg)
    case .REGISTERS:
        _, unmarshal_err := lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &gui_state.regs)
        if unmarshal_err != nil {
            return fmt.tprintf("Malformed response from daemon: %s", unmarshal_err.?)
        }
    }

    return nil
}

// One register row: name, preview, mime pill, time/age. Returns the height it occupied, which the caller uses to
// advance.
draw_register :: proc(gui_state: ^Gui_State, reg_id: lib.Reg_Id, cols: Row_Columns, y: f64, now: i64) {
    fb := &gui_state.frame_buf
    entry := gui_state.regs[reg_id]

    // Render register name as a pill element
    name := lib.reg_id_to_string(reg_id)
    rounded_rect(fb.ctx, cols.regname_x, y, REGNAME_WIDTH, PILL_HEIGHT, PILL_RADIUS)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(REGNAME_BG))
    cairo.cairo_fill(fb.ctx)
    name_width: i32
    pango.pango_layout_set_text(fb.layout, raw_data(name), i32(len(name)))
    pango.pango_layout_get_pixel_size(fb.layout, &name_width, nil)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(FG))
    cairo.cairo_move_to(fb.ctx, cols.regname_x + (REGNAME_WIDTH - f64(name_width)) / 2, y)
    pc.pango_cairo_show_layout(fb.ctx, fb.layout)

    // Render content preview. `display_data` pads to a character budget, pango handles pixel clipping.
    if !lib.resp_reg_is_empty(entry) {
        draw_text_clipped(gui_state, display_data(entry, -1), cols.preview_x, y, cols.preview_width, FG)
    }

    // Render mime pill, with `+N` for N extra mimes the register carries.
    total_mimes := mime_count(entry)
    if total_mimes > 0 {
        _, mime, _ := mime_at(entry, selected_mime_index(entry))
        // Prefer to elide the mime in the middle after the full type.
        label := lib.elide_mime(mime, MIME_LABEL_CHARS)
        if total_mimes > 1 {label = fmt.tprintf("%s +%d", label, total_mimes - 1)}

        pango.pango_layout_set_text(fb.layout, raw_data(label), i32(len(label)))
        pill_width: i32
        pango.pango_layout_get_pixel_size(fb.layout, &pill_width, nil)
        rounded_rect(
            fb.ctx,
            cols.mime_x,
            y,
            min(f64(pill_width) + 2 * 6, PANEL_MIME_COLUMN_WIDTH),
            PILL_HEIGHT,
            PILL_RADIUS,
        )
        cairo.cairo_set_source_rgba(fb.ctx, expand_values(MIME_BG))
        cairo.cairo_fill(fb.ctx)
        draw_text(gui_state, label, cols.mime_x + 6, y, FG_DIM)
    }

    // Render time/age, dimmed.
    if entry.timestamp != 0 {
        buf: [lib.RELATIVE_TIMESTAMP_LEN]u8
        age := lib.format_relative_timestamp(entry.timestamp, now, &buf)
        draw_text_clipped(gui_state, age, cols.time_x, y, PANEL_TIME_COLUMN_WIDTH, FG_DIM)
    }
}

// Get the non-empty registers, we don't display empty registers. Returns number of register IDs filled.
populated_regs :: proc(gui_state: ^Gui_State, reg_ids: []lib.Reg_Id) -> (count: int) {
    // Small helper adding and counting the non-empty registers in a register category.
    append_group :: proc(gui_state: ^Gui_State, first, last: lib.Reg_Id, dst: []lib.Reg_Id, count: ^int) {
        for id := first; id <= last; id += 1 {
            if lib.resp_reg_is_empty(gui_state.regs[id]) {continue}
            if count^ >= len(dst) {return}
            dst[count^] = id
            count^ += 1
        }
    }

    // Display order
    append_group(gui_state, lib.SELECTION_CLIPBOARD, lib.SELECTION_PRIMARY, reg_ids, &count)
    append_group(gui_state, lib.CLIPBOARD_START, lib.CLIPBOARD_END, reg_ids, &count)
    append_group(gui_state, lib.PRIMARY_START, lib.PRIMARY_END, reg_ids, &count)
    append_group(gui_state, lib.NAMED_START, lib.NAMED_END, reg_ids, &count)
    return count
}

// How many rows fit in the panel.
visible_row_count :: proc(gui_state: ^Gui_State) -> int {
    usable := int(gui_state.frame_buf.height) - 2 * (PANEL_MARGIN + TEXT_PADDING_Y)
    if usable < ROW_HEIGHT {return 0}
    usable -= (len(Reg_Category) - 1) * HORZ_RULE_GAP // account for horizontal rules
    return max(1, usable / ROW_HEIGHT)
}

// Move the viewport, clamped so the last row can reach the bottom but no further. Returns whether anything moved, so
// the caller can skip a redraw that would paint the same pixels.
scroll_by :: proc(gui_state: ^Gui_State, rows: int) -> bool {
    buf: [lib.MAX_REGS]lib.Reg_Id
    total := populated_regs(gui_state, buf[:])
    max_scroll := max(0, total - visible_row_count(gui_state))

    prev := gui_state.scroll_row
    gui_state.scroll_row = clamp(gui_state.scroll_row + rows, 0, max_scroll)
    return gui_state.scroll_row != prev
}

// Draw the non-empty registers.
draw_all_registers :: proc(gui_state: ^Gui_State, x: f64, y: f64) {
    buf: [lib.MAX_REGS]lib.Reg_Id
    regs := buf[:populated_regs(gui_state, buf[:])]

    // Clamp here too since the rendered regs can shrink or grow.
    max_scroll := max(0, len(regs) - visible_row_count(gui_state))
    gui_state.scroll_row = clamp(gui_state.scroll_row, 0, max_scroll)

    cols := row_columns(gui_state)
    // Calculate time only once for the entire frame so every register compares its time to the same thing.
    now := time.time_to_unix(time.now())

    cursor_y := y
    end := min(len(regs), gui_state.scroll_row + visible_row_count(gui_state))
    visible := regs[gui_state.scroll_row:end]
    fb := &gui_state.frame_buf
    for id, i in visible {
        // Insert a horizontal rule when the current register's category differs from the last
        if i > 0 && reg_category_from_id(id) != reg_category_from_id(visible[i - 1]) {
            cursor_y += HORZ_RULE_GAP / 2
            cairo.cairo_set_source_rgba(fb.ctx, expand_values(RULE_FG))
            cairo.cairo_rectangle(fb.ctx, PANEL_MARGIN, cursor_y, f64(fb.width) - 2 * PANEL_MARGIN, HORZ_RULE_HEIGHT)
            cairo.cairo_fill(fb.ctx)
            cursor_y += HORZ_RULE_GAP - HORZ_RULE_GAP / 2
        }
        draw_register(gui_state, id, cols, cursor_y, now)
        cursor_y += ROW_HEIGHT
    }

    // Draw mime list over top of main panel if needed.
    if gui_state.activity_focus == .Mime_List {
        draw_mime_list(gui_state, visible, cols, y)
    }
}

// Which category a register belongs to.
Reg_Category :: enum u8 {
    Selection, // what the system clipboard/primary currently holds
    Clipboard_Ring, // recency, immutable
    Primary_Ring, // recency, immutable
    Named, // saved selections, mutable
}

reg_category_from_id :: proc(id: lib.Reg_Id) -> Reg_Category {
    switch {
    case lib.reg_id_is_selection(id):
        return .Selection
    case lib.reg_id_is_clipboard_num(id):
        return .Clipboard_Ring
    case lib.reg_id_is_primary_num(id):
        return .Primary_Ring
    }
    return .Named
}

// Number of horizontal rules needed i.e. count of category changes within populated registers.
group_breaks :: proc(rows: []lib.Reg_Id) -> (count: int) {
    for i in 1 ..< len(rows) {
        if reg_category_from_id(rows[i]) != reg_category_from_id(rows[i - 1]) {count += 1}
    }
    return
}

// Surface height for the current register set. Should be called before the surface is created.
popup_height :: proc(gui_state: ^Gui_State) -> uint {
    buf: [lib.MAX_REGS]lib.Reg_Id
    rows := populated_regs(gui_state, buf[:])
    chrome := 2 * (PANEL_MARGIN + TEXT_PADDING_Y)
    rules := group_breaks(buf[:rows]) * HORZ_RULE_GAP
    // At least one row, so an empty register set still produces a visible panel rather than a sliver.
    return uint(clamp(chrome + max(rows, 1) * ROW_HEIGHT + rules, chrome + ROW_HEIGHT, POPUP_MAX_HEIGHT))
}

// Where each column starts.
Row_Columns :: struct {
    regname_x:     f64,
    preview_x:     f64,
    preview_width: f64,
    mime_x:        f64,
    time_x:        f64,
    right:         f64, // panel's inner right edge, which the dropdown clamps against
}

// Derive the start locations of the columns from the gui state.
row_columns :: proc(gui_state: ^Gui_State) -> Row_Columns {
    left := f64(PANEL_MARGIN + TEXT_PADDING_X)
    right := f64(gui_state.frame_buf.width) - PANEL_MARGIN - TEXT_PADDING_X
    time_x := right - PANEL_TIME_COLUMN_WIDTH
    mime_x := time_x - COL_GAP - PANEL_MIME_COLUMN_WIDTH
    preview_x := left + REGNAME_WIDTH + COL_GAP
    return {
        regname_x = left,
        preview_x = preview_x,
        preview_width = max(0, mime_x - COL_GAP - preview_x),
        mime_x = mime_x,
        time_x = time_x,
        right = right,
    }
}

// Draw `text` at `x` with no clipping, for text whose length the caller has already bounded.
draw_text :: proc(gui_state: ^Gui_State, text: string, x, y: f64, color: Rgba) {
    fb := &gui_state.frame_buf
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(color))
    cairo.cairo_move_to(fb.ctx, x, y)
    pango.pango_layout_set_text(fb.layout, raw_data(text), i32(len(text)))
    pc.pango_cairo_show_layout(fb.ctx, fb.layout)
}

// Draw `text` at `x`, ellipsized to `width` pixels. Pango does the cutting, so it lands on a grapheme boundary rather
// than mid-codepoint, and an ellipsis marks that it was clipped.
draw_text_clipped :: proc(gui_state: ^Gui_State, text: string, x, y, width: f64, color: Rgba) {
    fb := &gui_state.frame_buf
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(color))
    cairo.cairo_move_to(fb.ctx, x, y)
    pango.pango_layout_set_width(fb.layout, i32(width * pango.SCALE))
    pango.pango_layout_set_ellipsize(fb.layout, .END)
    pango.pango_layout_set_text(fb.layout, raw_data(text), i32(len(text)))
    pc.pango_cairo_show_layout(fb.ctx, fb.layout)
    // Reset, or every later layout inherits this row's width and ellipsization.
    pango.pango_layout_set_width(fb.layout, -1)
    pango.pango_layout_set_ellipsize(fb.layout, .NONE)
}

// Trace a rounded rectangle as a single closed path, ready to fill or stroke.
rounded_rect :: proc(ctx: ^cairo.Context, x, y, width, height, radius: f64) {
    TAU :: 6.283185307179586
    // Needed before first arc, otherwise line is drawn from whatever the current point happens to be to the start of
    // the arc.
    cairo.cairo_new_sub_path(ctx)
    cairo.cairo_arc(ctx, x + width - radius, y + radius, radius, -TAU / 4, 0) // top-right
    cairo.cairo_arc(ctx, x + width - radius, y + height - radius, radius, 0, TAU / 4) // bottom-right
    cairo.cairo_arc(ctx, x + radius, y + height - radius, radius, TAU / 4, TAU / 2) // bottom-left
    cairo.cairo_arc(ctx, x + radius, y + radius, radius, TAU / 2, 3 * TAU / 4) // top-left
    cairo.cairo_close_path(ctx)
}

// Draw the open mime list over the rows beneath its own, anchored to the row it belongs to.
//
// Returns without drawing if the register scrolled out of view, rather than anchoring to nothing.
draw_mime_list :: proc(gui_state: ^Gui_State, rows: []lib.Reg_Id, cols: Row_Columns, origin_y: f64) {
    mime_state := gui_state.mime_list
    entry := gui_state.regs[mime_state.reg]
    total := mime_count(entry)
    if total == 0 {return}

    // Find row index of selected register.
    row_index := -1
    for id, i in rows {
        if id == mime_state.reg {
            row_index = i
            break
        }
    }
    if row_index < 0 {return}     // scrolled out of the window

    fb := &gui_state.frame_buf
    // Widest name decides the width, mime list does not elide.
    width := 0.0
    for i in 0 ..< total {
        _, mime, ok := mime_at(entry, i)
        if !ok {continue}
        pango.pango_layout_set_text(fb.layout, raw_data(mime), i32(len(mime)))
        mime_width: i32
        pango.pango_layout_get_pixel_size(fb.layout, &mime_width, nil)
        width = max(width, f64(mime_width))
    }

    box_width_probe := width + 2 * DROPDOWN_PAD
    // Hangs off the mime pill it expands, but shifted left as far as needed to stay inside the panel.
    x := min(cols.mime_x, cols.right - box_width_probe)
    y := origin_y + f64(row_index + 1) * ROW_HEIGHT
    box_width := box_width_probe
    box_height := f64(total) * ROW_HEIGHT + 2 * DROPDOWN_PAD

    // Draw mime list container.
    rounded_rect(fb.ctx, x, y, box_width, box_height, DROPDOWN_RADIUS)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(DROPDOWN_BG))
    cairo.cairo_fill_preserve(fb.ctx)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(PANEL_BORDER))
    cairo.cairo_set_line_width(fb.ctx, PANEL_BORDER_WIDTH)
    cairo.cairo_stroke(fb.ctx)

    // Draw each mime in the container.
    for i in 0 ..< total {
        _, mime, ok := mime_at(entry, i)
        if !ok {continue}
        row_y := y + DROPDOWN_PAD + f64(i) * ROW_HEIGHT

        if i == int(mime_state.cursor) {
            rounded_rect(fb.ctx, x + DROPDOWN_PAD / 2, row_y, box_width - DROPDOWN_PAD, PILL_HEIGHT, 4)
            cairo.cairo_set_source_rgba(fb.ctx, expand_values(DROPDOWN_SELECTED))
            cairo.cairo_fill(fb.ctx)
        }

        cairo.cairo_set_source_rgba(fb.ctx, expand_values(FG))
        cairo.cairo_move_to(fb.ctx, x + DROPDOWN_PAD, row_y)
        pango.pango_layout_set_text(fb.layout, raw_data(mime), i32(len(mime)))
        pc.pango_cairo_show_layout(fb.ctx, fb.layout)
    }
}

gui_render :: proc(gui_state: ^Gui_State) {
    fb := &gui_state.frame_buf
    if fb.ctx == nil {return}     // configure has not run yet, so there is nothing to draw into

    // Clear the whole surface to fully transparent with SOURCE rather than painting over it. The margin around the card
    // must end up transparent, and OVER would leave the previous frame's pixels showing through wherever the new frame
    // is translucent.
    cairo.cairo_set_operator(fb.ctx, .SOURCE)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(TRANSPARENT))
    cairo.cairo_paint(fb.ctx)

    cairo.cairo_set_operator(fb.ctx, .OVER)
    panel_width := f64(fb.width) - 2 * PANEL_MARGIN
    panel_height := f64(fb.height) - 2 * PANEL_MARGIN

    // Draw root container.
    rounded_rect(fb.ctx, PANEL_MARGIN, PANEL_MARGIN, panel_width, panel_height, PANEL_RADIUS)
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(PANEL_BG))
    cairo.cairo_fill_preserve(fb.ctx) // keep the path so the border strokes the same shape
    cairo.cairo_set_source_rgba(fb.ctx, expand_values(PANEL_BORDER))
    cairo.cairo_set_line_width(fb.ctx, PANEL_BORDER_WIDTH)
    cairo.cairo_stroke(fb.ctx)

    cairo.cairo_set_source_rgba(fb.ctx, expand_values(FG))
    draw_all_registers(gui_state, PANEL_MARGIN + TEXT_PADDING_X, PANEL_MARGIN + TEXT_PADDING_Y)

    // The compositor reads the mapped memory directly, so pending drawing has to be flushed before it does.
    cairo.cairo_surface_flush(fb.surface)
    if status := cairo.cairo_status(fb.ctx); status != .SUCCESS {
        log.errorf("cairo render: %s", cairo.cairo_status_to_string(status))
    }
}

run_gui :: proc(client_fd: linux.Fd) {
    // Single-instance lock to prevent multiple popups
    lock_path := lib.clipbender_lock_path()
    defer delete(lock_path)

    lock_fd, open_err := linux.open(
        strings.clone_to_cstring(lock_path, context.temp_allocator),
        {.CREAT, .RDWR},
        {.IRUSR, .IWUSR},
    )
    if open_err != .NONE {
        fmt.eprintfln("Error: could not open lock file at %s: errno %v", lock_path, open_err)
        os.exit(1)
    }
    defer linux.close(lock_fd)
    flock_err := linux.flock(lock_fd, {.EX, .NB})
    if flock_err != .NONE {
        fmt.eprintln("Error: another clipbender popup is already running")
        os.exit(0)
    }

    gui_state: Gui_State
    gui_state.client_fd = client_fd

    // We need to fetch registers before `gui_init` in order to properly size it.
    err := gui_fetch_registers(client_fd, &gui_state)
    if err != nil {
        fmt.eprintfln("Error: could not fetch registers: %s", err)
    }

    err = gui_init(&gui_state)
    if err != nil {
        fmt.eprintfln("Error: could not initialize GUI state: %s", err)
        os.exit(1)
    }
    defer gui_cleanup(&gui_state)
    log.debug("GUI initialized")

    gui_render(&gui_state)
    log.debug("GUI rendered, entering event loop")

    for gui_state.running {
        wl.display_dispatch(gui_state.display)
    }
}
