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

// TODO: make these persistent in the future by writing state to binary
clipboard_registers: Recency_Ring
named_registers: [26]lib.Reg_Entry
primary_registers: Recency_Ring

// Push to head, takes ownership of data and mime (caller must provide heap-allocated memory)
push_to_ring :: proc(ring: ^Recency_Ring, data: []u8, mime: string) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    lib.free_reg_entry(&ring.entries[ring.head])
    ring.entries[ring.head] = lib.Reg_Entry {
        data      = data,
        mime_type = mime,
        timestamp = time.time_to_unix(time.now()),
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

push_recency_reg :: proc(type: lib.Selection_Type, data: []u8, mime: string) {
    ring: ^Recency_Ring
    switch type {
    case .CLIPBOARD:
        ring = &clipboard_registers
    case .PRIMARY:
        ring = &primary_registers
    }
    push_to_ring(ring, data, mime)
}

// Get the `recency` most recent `Register_Entry` from a specific ring
get_ring_entry :: proc(ring: ^Recency_Ring, recency: u8) -> ^lib.Reg_Entry {
    if recency >= ring.count {return nil}
    idx := (ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
    return &ring.entries[idx]
}

// Get the `recency` most recent `Register_Entry` by selection type
get_recency_reg :: proc(type: lib.Selection_Type, recency: u8) -> ^lib.Reg_Entry {
    switch type {
    case .CLIPBOARD:
        return get_ring_entry(&clipboard_registers, recency)
    case .PRIMARY:
        return get_ring_entry(&primary_registers, recency)
    }
    return nil
}

// Get the `idx` index `Register_Entry` from named registers array
get_named_reg :: proc(idx: u8) -> ^lib.Reg_Entry {
    if idx >= len(named_registers) {return nil}
    if named_registers[idx].data == nil {return nil}
    return &named_registers[idx]
}

// Look up by id, index into the right array
get_reg :: proc(reg_id: lib.Reg_Id) -> ^lib.Reg_Entry {
    if lib.reg_id_is_clipboard_num(reg_id) {
        recency := lib.reg_id_to_clipboard_index(reg_id)
        return get_recency_reg(.CLIPBOARD, recency)
    } else if lib.reg_id_is_named(reg_id) {
        idx := lib.reg_id_to_named_index(reg_id)
        return get_named_reg(idx)
    } else if lib.reg_id_is_primary_num(reg_id) {
        recency := lib.reg_id_to_primary_index(reg_id)
        return get_recency_reg(.PRIMARY, recency)
    } else if reg_id == lib.SELECTION_CLIPBOARD {
        // TODO: get the selection through cached data_offer in wayland layer. For now, just return the most recent
        // register (should be identical for now, but maybe offer filtering/only writing certain stuff to recency
        // registers in the future)
        return get_recency_reg(.CLIPBOARD, 0)
    } else if reg_id == lib.SELECTION_PRIMARY {
        return get_recency_reg(.PRIMARY, 0)
    }
    return nil
}

get_registers :: proc(filter: lib.Cmd_Get_Filter, regs: ^[46]lib.Reg) -> (count: u8) {
    count = 0
    for bit in filter & lib.CMD_GET_FILTER_CLIPBOARD {
        entry := get_recency_reg(.CLIPBOARD, u8(bit))
        if entry == nil {continue}
        regs[count] = lib.Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_NAMED {
        entry := get_named_reg(u8(bit) - u8(lib.NAMED_START))
        if entry == nil {continue}
        regs[count] = lib.Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_PRIMARY {
        entry := get_recency_reg(.PRIMARY, u8(bit) - u8(lib.PRIMARY_START))
        if entry == nil {continue}
        regs[count] = lib.Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    return count
}

set_named_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string, set_mode: lib.Set_Mode) -> bool {
    idx := lib.reg_id_to_named_index(reg_id)

    switch set_mode {
    case .OVERWRITE:
        overwrite_named_reg(idx, data, mime)
        return true
    case .APPEND:
        reg_entry := &named_registers[idx]
        if reg_entry.data == nil {
            // Nothing to append to, treat same as set
            overwrite_named_reg(idx, data, mime)
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
overwrite_named_reg :: proc(idx: u8, data: []byte, mime: string) {
    lib.free_reg_entry(&named_registers[idx])
    named_registers[idx] = lib.Reg_Entry {
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
clear_named_reg :: proc(reg_id: lib.Reg_Id) {
    idx := lib.reg_id_to_named_index(reg_id)
    lib.free_reg_entry(&named_registers[idx])
}

cleanup_registers :: proc() {
    for &entry in clipboard_registers.entries {lib.free_reg_entry(&entry)}
    for &entry in primary_registers.entries {lib.free_reg_entry(&entry)}
    for &entry in named_registers {lib.free_reg_entry(&entry)}
}

// Convenience clone functions
push_to_ring_clone :: proc(ring: ^Recency_Ring, data: []u8, mime: string) {
    push_to_ring(ring, slice.clone(data), strings.clone(mime))
}
push_recency_reg_clone :: proc(type: lib.Selection_Type, data: []u8, mime: string) {
    push_recency_reg(type, slice.clone(data), strings.clone(mime))
}
set_named_reg_clone :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string, set_mode: lib.Set_Mode) {
    set_named_reg(reg_id, slice.clone(data), strings.clone(mime), set_mode)
}

