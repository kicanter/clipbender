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
    // Maintained by the Wayland layer on each selection event, seeded at startup, and never persisted.
    // NOTE: these are currently _almost_ equivalent to numbered reg 0 for the respective ring buffer, however on duplicate
    // entries, the timestamp is updated, whereas nothing is pushed or modified wrt the numbered registers.
    clipboard_selection: lib.Reg_Entry,
    primary_selection:   lib.Reg_Entry,
}

// Overwrite the live selection cache for `type`, taking ownership of `data` and `mime` (frees the previous value).
set_live_selection :: proc(store: ^Register_Store, type: lib.Selection_Type, data: []byte, mime: string) {
    selection: ^lib.Reg_Entry
    switch type {
    case .CLIPBOARD:
        selection = &store.clipboard_selection
    case .PRIMARY:
        selection = &store.primary_selection
    }
    lib.free_reg_entry(selection)
    selection^ = lib.Reg_Entry {
        data      = data,
        mime_type = mime,
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
        if entry.data == nil {continue}
        push_recency_reg(store, .CLIPBOARD, entry.data, entry.mime_type)
    }
    for i := int(lib.PRIMARY_END); i >= int(lib.PRIMARY_START); i -= 1 {
        entry := regs[i]
        if entry.data == nil {continue}
        push_recency_reg(store, .PRIMARY, entry.data, entry.mime_type)
    }
    for i in int(lib.NAMED_START) ..= int(lib.NAMED_END) {
        entry := regs[i]
        if entry.data == nil {continue}
        overwrite_named_reg(store, lib.reg_id_to_named_index(lib.Reg_Id(i)), entry.data, entry.mime_type)
    }
}

// Push to head, takes ownership of data and mime (caller must provide heap-allocated memory)
push_to_ring :: proc(ring: ^Recency_Ring, data: []u8, mime: string, timestamp: Maybe(i64) = nil) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    lib.free_reg_entry(&ring.entries[ring.head])

    ts := timestamp.? or_else time.time_to_unix(time.now())
    ring.entries[ring.head] = lib.Reg_Entry {
        data      = data,
        mime_type = mime,
        timestamp = ts,
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

push_recency_reg :: proc(
    store: ^Register_Store,
    type: lib.Selection_Type,
    data: []u8,
    mime: string,
    timestamp: Maybe(i64) = nil,
) {
    ring: ^Recency_Ring
    switch type {
    case .CLIPBOARD:
        ring = &store.clipboard_registers
    case .PRIMARY:
        ring = &store.primary_registers
    }

    push_to_ring(ring, data, mime, timestamp)
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
    if store.named_registers[idx].data == nil {return nil}
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
        if store.clipboard_selection.data == nil {return nil}
        return &store.clipboard_selection
    } else if reg_id == lib.SELECTION_PRIMARY {
        if store.primary_selection.data == nil {return nil}
        return &store.primary_selection
    }
    return nil
}

// Gather registers matching `filter` into `regs`, indexed by Reg_Id. Slots not matched are left zeroed.
get_registers :: proc(
    store: ^Register_Store,
    filter: lib.Cmd_Get_Filter,
    regs: ^[lib.MAX_REGS]lib.Reg_Entry,
) -> (
    count: u8,
) {
    regs^ = {}
    count = 0
    for bit in filter & lib.CMD_GET_FILTER_NUMBERED {
        entry := get_recency_reg(store, .CLIPBOARD, u8(bit))
        if entry == nil {continue}
        regs[bit] = entry^
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_NAMED {
        entry := get_named_reg(store, u8(bit) - u8(lib.NAMED_START))
        if entry == nil {continue}
        regs[bit] = entry^
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_PRIMARY_NUMBERED {
        entry := get_recency_reg(store, .PRIMARY, u8(bit) - u8(lib.PRIMARY_START))
        if entry == nil {continue}
        regs[bit] = entry^
        count += 1
    }

    // Live selections
    if filter & lib.CMD_GET_FILTER_SELECTION != {} && store.clipboard_selection.data != nil {
        regs[lib.SELECTION_CLIPBOARD] = store.clipboard_selection
        count += 1
    }
    if filter & lib.CMD_GET_FILTER_PRIMARY_SELECTION != {} && store.primary_selection.data != nil {
        regs[lib.SELECTION_PRIMARY] = store.primary_selection
        count += 1
    }

    return count
}

set_named_reg :: proc(
    store: ^Register_Store,
    reg_id: lib.Reg_Id,
    data: []byte,
    mime: string,
    set_mode: lib.Set_Mode,
) -> bool {
    idx := lib.reg_id_to_named_index(reg_id)

    switch set_mode {
    case .OVERWRITE:
        overwrite_named_reg(store, idx, data, mime)
        return true
    case .APPEND:
        reg_entry := &store.named_registers[idx]
        if reg_entry.data == nil {
            // Nothing to append to, treat same as set
            overwrite_named_reg(store, idx, data, mime)
            return true
        }
        return append_named_reg(reg_entry, data, mime)
    }

    unreachable()
}

set_selection_reg :: proc(backend: ^lib.Clipboard_Backend, reg_id: lib.Reg_Id, data: []byte, mime: string) {
    if backend.state == nil {
        log.error("No backend state, can't set selection register")
        delete(data)
        delete(mime)
        return
    }
    if reg_id == lib.SELECTION_CLIPBOARD {
        backend.set_selection(backend.state, data, mime, .CLIPBOARD)
    } else if reg_id == lib.SELECTION_PRIMARY {
        backend.set_selection(backend.state, data, mime, .PRIMARY)
    }
}

// Overwrite a named reg
overwrite_named_reg :: proc(store: ^Register_Store, idx: u8, data: []byte, mime: string) {
    lib.free_reg_entry(&store.named_registers[idx])
    store.named_registers[idx] = lib.Reg_Entry {
        data      = data,
        mime_type = mime,
        timestamp = time.time_to_unix(time.now()),
    }
}

// Append to a named reg
append_named_reg :: proc(reg_entry: ^lib.Reg_Entry, data: []byte, mime: string) -> bool {
    if reg_entry.mime_type != mime {
        delete(data)
        delete(mime)
        return false
    }

    // Concatenate
    new_data := make([]byte, len(reg_entry.data) + len(data))
    copy(new_data, reg_entry.data)
    copy(new_data[len(reg_entry.data):], data)
    delete(reg_entry.data)
    delete(data) // free caller's data, already copied into new_data
    delete(mime) // free caller's mime, register keeps its existing mime_type
    reg_entry.data = new_data
    reg_entry.timestamp = time.time_to_unix(time.now())
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

// Convenience clone functions
push_to_ring_clone :: proc(ring: ^Recency_Ring, data: []u8, mime: string) {
    push_to_ring(ring, slice.clone(data), strings.clone(mime))
}
push_recency_reg_clone :: proc(store: ^Register_Store, type: lib.Selection_Type, data: []u8, mime: string) {
    push_recency_reg(store, type, slice.clone(data), strings.clone(mime))
}
set_named_reg_clone :: proc(
    store: ^Register_Store,
    reg_id: lib.Reg_Id,
    data: []byte,
    mime: string,
    set_mode: lib.Set_Mode,
) {
    set_named_reg(store, reg_id, slice.clone(data), strings.clone(mime), set_mode)
}
