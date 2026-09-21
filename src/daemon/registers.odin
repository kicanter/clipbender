package main

import "core:log"
import "core:slice"
import "core:strings"
import "core:time"

import lib "src:libclipbender"

// Ringbuffer for recency registers
Recency_Ring :: struct {
    entries: [lib.RECENCY_SIZE]lib.Reg_Entry,
    head:    u8,
    count:   u8,
}

Register_Store :: struct {
    named_registers:     [lib.NAMED_SIZE]lib.Reg_Entry,
    clipboard_registers: Recency_Ring,
    primary_registers:   Recency_Ring,
    // Live system selections: the actual current clipboard/primary selection, distinct from the recency rings.
    // NOTE: these are currently _almost_ equivalent to numbered reg 0 for the respective ring buffer, however on duplicate
    // entries, the timestamp is updated, whereas nothing is pushed or modified wrt the numbered registers.
    clipboard_selection: lib.Reg_Entry,
    primary_selection:   lib.Reg_Entry,
}

// Overwrite the live selection cache for `type`, taking ownership of `data` and `mime` (frees the previous value).
set_live_selection :: proc(store: ^Register_Store, type: lib.Selection_Type, reprs: []lib.Data_Repr) {
    selection: ^lib.Reg_Entry
    switch type {
    case .CLIPBOARD:
        selection = &store.clipboard_selection
    case .PRIMARY:
        selection = &store.primary_selection
    }
    lib.free_reg_entry(selection)
    selection^ = lib.Reg_Entry {
        reprs     = reprs,
        timestamp = time.time_to_unix(time.now()),
    }
}

// Retrieve the live selection cache for `type`.
get_live_selection :: proc(store: ^Register_Store, type: lib.Selection_Type) -> ^lib.Reg_Entry {
    switch type {
    case .CLIPBOARD:
        return &store.clipboard_selection
    case .PRIMARY:
        return &store.primary_selection
    }
    unreachable()
}

// Bump the live selection cache's timestamp for `type`, updating the existing value.
bump_live_selection :: proc(store: ^Register_Store, type: lib.Selection_Type) {
    selection: ^lib.Reg_Entry
    switch type {
    case .CLIPBOARD:
        selection = &store.clipboard_selection
    case .PRIMARY:
        selection = &store.primary_selection
    }

    selection.timestamp = time.time_to_unix(time.now())
}

free_live_selections :: proc(store: ^Register_Store) {
    lib.free_reg_entry(&store.clipboard_selection)
    lib.free_reg_entry(&store.primary_selection)
}

load_registers :: proc(store: ^Register_Store, regs: ^[lib.MAX_REGS]lib.Reg_Entry) {
    // `regs` is indexed by Reg_Id. Recency rings are serialized most-recent-first, so within each ring we push in
    // reverse (highest recency index first) so the most recent entry ends up at the ring head.
    for i := int(lib.CLIPBOARD_END); i >= int(lib.CLIPBOARD_START); i -= 1 {
        entry := regs[i]
        if len(entry.reprs) == 0 {continue}
        push_recency_reg(store, .CLIPBOARD, entry.reprs)
    }
    for i := int(lib.PRIMARY_END); i >= int(lib.PRIMARY_START); i -= 1 {
        entry := regs[i]
        if len(entry.reprs) == 0 {continue}
        push_recency_reg(store, .PRIMARY, entry.reprs)
    }
    for i in int(lib.NAMED_START) ..= int(lib.NAMED_END) {
        entry := regs[i]
        if len(entry.reprs) == 0 {continue}
        overwrite_named_reg(store, lib.reg_id_to_named_index(lib.Reg_Id(i)), entry.reprs)
    }
}

// Push to head, takes ownership of data and mime (caller must provide heap-allocated memory)
push_to_ring :: proc(ring: ^Recency_Ring, reprs: []lib.Data_Repr, timestamp: Maybe(i64) = nil) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    lib.free_reg_entry(&ring.entries[ring.head])

    ts := timestamp.? or_else time.time_to_unix(time.now())
    ring.entries[ring.head] = lib.Reg_Entry {
        reprs     = reprs,
        timestamp = ts,
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

push_recency_reg :: proc(
    store: ^Register_Store,
    type: lib.Selection_Type,
    reprs: []lib.Data_Repr,
    timestamp: Maybe(i64) = nil,
) {
    ring: ^Recency_Ring
    switch type {
    case .CLIPBOARD:
        ring = &store.clipboard_registers
    case .PRIMARY:
        ring = &store.primary_registers
    }

    push_to_ring(ring, reprs, timestamp)
}

// Move the entry at `recency` to the front (recency 0), shifting the entries in between back one slot. Refreshes the
// moved entry's timestamp. No allocations, just shuffling existing entries. Head/count unchanged.
move_ring_entry_to_front :: proc(ring: ^Recency_Ring, recency: u8) {
    if recency == 0 || recency >= ring.count {return}

    saved := ring.entries[(ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE]
    // Shift each entry one step toward the head, opening up the front slot
    for i := recency; i > 0; i -= 1 {
        src := (ring.head - (i - 1) + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
        dst := (ring.head - i + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
        ring.entries[dst] = ring.entries[src]
    }
    saved.timestamp = time.time_to_unix(time.now())
    ring.entries[ring.head] = saved
}

// Move the `recency` most recent `Register_Entry` to the front of the `type` selection ring
move_recency_reg_to_front :: proc(store: ^Register_Store, type: lib.Selection_Type, recency: u8) {
    switch type {
    case .CLIPBOARD:
        move_ring_entry_to_front(&store.clipboard_registers, recency)
    case .PRIMARY:
        move_ring_entry_to_front(&store.primary_registers, recency)
    }
}

// Get the `recency` most recent `Register_Entry` from a specific ring
get_ring_entry :: proc(ring: ^Recency_Ring, recency: u8) -> ^lib.Reg_Entry {
    if recency >= ring.count {return nil}
    idx := (ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
    return &ring.entries[idx]
}

// Get the `recency` most recent `Register_Entry` by selection type
get_recency_reg :: proc(store: ^Register_Store, type: lib.Selection_Type, recency: u8) -> ^lib.Reg_Entry {
    switch type {
    case .CLIPBOARD:
        return get_ring_entry(&store.clipboard_registers, recency)
    case .PRIMARY:
        return get_ring_entry(&store.primary_registers, recency)
    }
    return nil
}

// Get the `idx` index `Register_Entry` from named registers array
get_named_reg :: proc(store: ^Register_Store, idx: u8) -> ^lib.Reg_Entry {
    if idx >= len(store.named_registers) {return nil}
    if len(store.named_registers[idx].reprs) == 0 {return nil}
    return &store.named_registers[idx]
}

// Look up by id, index into the right array
get_reg :: proc(store: ^Register_Store, reg_id: lib.Reg_Id) -> ^lib.Reg_Entry {
    if lib.reg_id_is_clipboard_num(reg_id) {
        recency := lib.reg_id_to_clipboard_index(reg_id)
        return get_recency_reg(store, .CLIPBOARD, recency)
    } else if lib.reg_id_is_named(reg_id) {
        idx := lib.reg_id_to_named_index(reg_id)
        return get_named_reg(store, idx)
    } else if lib.reg_id_is_primary_num(reg_id) {
        recency := lib.reg_id_to_primary_index(reg_id)
        return get_recency_reg(store, .PRIMARY, recency)
    } else if reg_id == lib.SELECTION_CLIPBOARD {
        if len(store.clipboard_selection.reprs) == 0 {return nil}
        return &store.clipboard_selection
    } else if reg_id == lib.SELECTION_PRIMARY {
        if len(store.primary_selection.reprs) == 0 {return nil}
        return &store.primary_selection
    }
    return nil
}

// Gather registers matching `filter` into `regs`, indexed by Reg_Id. Slots not matched are left nil.
get_registers :: proc(store: ^Register_Store, filter: lib.Cmd_Get_Filter) -> [lib.MAX_REGS]^lib.Reg_Entry {
    regs: [lib.MAX_REGS]^lib.Reg_Entry
    for bit in filter & lib.CMD_GET_FILTER_NUMBERED {
        entry := get_recency_reg(store, .CLIPBOARD, u8(bit))
        if entry == nil {continue}
        regs[bit] = entry
    }

    for bit in filter & lib.CMD_GET_FILTER_NAMED {
        entry := get_named_reg(store, u8(bit) - u8(lib.NAMED_START))
        if entry == nil {continue}
        regs[bit] = entry
    }

    for bit in filter & lib.CMD_GET_FILTER_PRIMARY_NUMBERED {
        entry := get_recency_reg(store, .PRIMARY, u8(bit) - u8(lib.PRIMARY_START))
        if entry == nil {continue}
        regs[bit] = entry
    }

    // Live selections
    if filter & lib.CMD_GET_FILTER_SELECTION != {} && len(store.clipboard_selection.reprs) > 0 {
        regs[lib.SELECTION_CLIPBOARD] = &store.clipboard_selection
    }
    if filter & lib.CMD_GET_FILTER_PRIMARY_SELECTION != {} && len(store.primary_selection.reprs) > 0 {
        regs[lib.SELECTION_PRIMARY] = &store.primary_selection
    }

    return regs
}

set_named_reg :: proc(
    store: ^Register_Store,
    reg_id: lib.Reg_Id,
    reprs: []lib.Data_Repr,
    set_mode: lib.Set_Mode,
) -> bool {
    idx := lib.reg_id_to_named_index(reg_id)

    switch set_mode {
    case .OVERWRITE:
        overwrite_named_reg(store, idx, reprs)
        return true
    case .APPEND:
        reg_entry := &store.named_registers[idx]
        if len(reg_entry.reprs) == 0 {
            // Nothing to append to, treat same as set
            overwrite_named_reg(store, idx, reprs)
            return true
        }
        // Append the incoming plaintext representation and discard the rest: there is no meaningful way to append an
        // image to an image. The destination's other representations are left in place, which is worth revisiting --
        // after appending text they no longer correspond to it.
        appended := false
        for repr in reprs {
            if !appended && is_plaintext_repr(repr) {
                appended = append_named_reg(reg_entry, repr)
            } else {
                lib.free_data_repr(repr)
            }
        }
        delete(reprs)
        return appended
    }

    unreachable()
}

// Hand `reprs` to the backend to advertise, taking ownership either way.
set_selection_reg :: proc(backend: Clipboard_Backend, reg_id: lib.Reg_Id, reprs: []lib.Data_Repr) {
    if reg_id == lib.SELECTION_CLIPBOARD {
        backend_set_selection(backend, reprs, .CLIPBOARD)
    } else if reg_id == lib.SELECTION_PRIMARY {
        backend_set_selection(backend, reprs, .PRIMARY)
    } else {
        // Not a selection register, so there is nothing to advertise and nobody else owns `reprs`.
        log.errorf("`%s` is not a selection register", lib.reg_id_to_string(reg_id))
        lib.free_data_reprs(reprs)
    }
}

// Overwrite a named reg
overwrite_named_reg :: proc(store: ^Register_Store, idx: u8, reprs: []lib.Data_Repr) {
    lib.free_reg_entry(&store.named_registers[idx])
    store.named_registers[idx] = lib.Reg_Entry {
        reprs     = reprs,
        timestamp = time.time_to_unix(time.now()),
    }
}

PLAINTEXT_MIMES :: [?]string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"}
is_plaintext_mime :: proc(mime: string) -> bool {
    for text_mime in PLAINTEXT_MIMES {
        if text_mime == mime do return true
    }
    return false
}

find_plaintext_repr :: proc(reg_entry: ^lib.Reg_Entry) -> ^lib.Data_Repr {
    for &repr in reg_entry.reprs {
        for mime in repr.mimes {
            if is_plaintext_mime(mime) do return &repr
        }
    }
    return nil
}

// Append `data` to a named reg's plaintext repr. Only plaintext is appendable (concatenating
// structured formats like html/png would corrupt them). Takes ownership of `data` and `mime`,
// both must be heap-allocated as they will be freed.
// M1: single repr, single mime; the existing repr is already text, so its mimes are left as-is.
// True when any of `repr`'s names is a plaintext mime.
is_plaintext_repr :: proc(repr: lib.Data_Repr) -> bool {
    for mime in repr.mimes {
        if is_plaintext_mime(mime) do return true
    }
    return false
}

// Names present in both sets, cloned. Falls back to `text/plain` when they share none: every plaintext mime refines it,
// so it is always a truthful label for concatenated text.
//
// Two passes so the result is exactly sized and its ownership is unambiguous -- slicing a [dynamic]string would hand the
// caller a pointer whose allocation carries capacity it does not know about.
intersect_mimes :: proc(a: []string, b: []string) -> []string {
    count := 0
    for m in a {
        for n in b {
            if m == n {
                count += 1
                break
            }
        }
    }

    if count == 0 {
        out := make([]string, 1)
        out[0] = strings.clone("text/plain")
        return out
    }

    out := make([]string, count)
    i := 0
    for m in a {
        for n in b {
            if m == n {
                out[i] = strings.clone(m)
                i += 1
                break
            }
        }
    }
    return out
}

// Concatenate `repr`'s bytes onto the entry's plaintext representation, taking ownership of `repr` either way.
//
// Append is a text operation -- concatenating two PNGs produces garbage -- and it leaves the register **text-only**:
//
//   - The result's names are the *intersection* of both sides'. Appending a `STRING` (latin-1) payload to a
//     `text/plain;charset=utf-8` one does not yield valid UTF-8, so the register must stop claiming any name the incoming
//     bytes did not also satisfy.
//   - Every other representation is dropped, because they describe the pre-append content. Keeping a stored PNG would
//     mean `get +a=image/png` returning an image inconsistent with `get +a`, and M5 paste offering the compositor a
//     mismatched set.
append_named_reg :: proc(reg_entry: ^lib.Reg_Entry, repr: lib.Data_Repr) -> bool {
    dest := find_plaintext_repr(reg_entry) // nil if the entry has no text representation

    // Both sides must be plaintext to concatenate.
    if !is_plaintext_repr(repr) || dest == nil {
        lib.free_data_repr(repr)
        return false
    }

    new_data, err := slice.concatenate([][]byte{dest.data, repr.data})
    if err != nil {
        log.errorf("allocator error when appending to named reg: errno %v", err)
        lib.free_data_repr(repr)
        return false
    }
    new_mimes := intersect_mimes(dest.mimes, repr.mimes)

    // Both salvaged values are freshly allocated, so the old entry and the incoming repr can go.
    lib.free_reg_entry(reg_entry)
    lib.free_data_repr(repr)

    reprs := make([]lib.Data_Repr, 1)
    reprs[0] = lib.Data_Repr {
        data  = new_data,
        mimes = new_mimes,
    }
    reg_entry^ = lib.Reg_Entry {
        reprs     = reprs,
        timestamp = time.time_to_unix(time.now()),
    }
    return true
}

// Zero out a named slot
clear_named_reg :: proc(store: ^Register_Store, reg_id: lib.Reg_Id) {
    idx := lib.reg_id_to_named_index(reg_id)
    lib.free_reg_entry(&store.named_registers[idx])
}

cleanup_registers :: proc(store: ^Register_Store) {
    for &entry in store.clipboard_registers.entries {lib.free_reg_entry(&entry)}
    for &entry in store.primary_registers.entries {lib.free_reg_entry(&entry)}
    for &entry in store.named_registers {lib.free_reg_entry(&entry)}
    free_live_selections(store)
}
