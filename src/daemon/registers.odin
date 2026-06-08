package main

import "core:log"
import "core:slice"
import "core:strings"
import "core:time"

import "../lib"

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

// Push to head, overwriting any existing value
push_recency_reg :: proc(ring: ^Recency_Ring, entry: lib.Reg_Entry) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    lib.free_reg_entry(&ring.entries[ring.head])
    ring.entries[ring.head] = lib.Reg_Entry {
        data      = slice.clone(entry.data),
        mime_type = strings.clone(entry.mime_type),
        timestamp = entry.timestamp,
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

// Get the `recency` most recent `Register_Entry`
get_recency_reg :: proc(ring: ^Recency_Ring, recency: u8) -> (reg: ^lib.Reg_Entry, ok: bool) {
    if recency >= ring.count {return nil, false}
    idx := (ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
    return &ring.entries[idx], true
}

// Get the `idx` index `Register_Entry` from named registers array
get_named_reg :: proc(idx: u8) -> (reg: ^lib.Reg_Entry, ok: bool) {
    if idx < 0 || idx > len(named_registers) {
        log.errorf("Index %v is out of named register bounds", idx)
        return nil, false
    }
    reg = &named_registers[idx]
    if reg.data == nil {
        log.debugf("Named register %v is empty", idx)
        return nil, true
    }
    return reg, true
}

// Look up by id, index into the right array
get_reg :: proc(reg_id: lib.Reg_Id) -> (reg_entry: ^lib.Reg_Entry, ok: bool) {
    if lib.reg_id_is_clipboard_num(reg_id) {
        recency := lib.reg_id_to_clipboard_index(reg_id)
        return get_recency_reg(&clipboard_registers, recency)
    } else if lib.reg_id_is_named(reg_id) {
        idx := lib.reg_id_to_named_index(reg_id)
        return get_named_reg(idx)
    } else if lib.reg_id_is_primary_num(reg_id) {
        recency := lib.reg_id_to_primary_index(reg_id)
        return get_recency_reg(&primary_registers, recency)
    } else if reg_id == lib.SELECTION_CLIPBOARD {
        // TODO: get the selection through cached data_offer in wayland layer. For now, just return the most recent
        // register (should be identical for now, but maybe offer filtering/only writing certain stuff to recency
        // registers in the future)
        return get_recency_reg(&clipboard_registers, 0)
    } else if reg_id == lib.SELECTION_PRIMARY {
        return get_recency_reg(&primary_registers, 0)
    }
    return nil, false
}

set_named_reg :: proc(set_mode: lib.Set_Mode, reg_id: lib.Reg_Id, data: []byte, mime: string) {
    switch set_mode {
    case .OVERWRITE:
        overwrite_named_reg(reg_id, data, mime)
    case .APPEND:
        append_named_reg(reg_id, data, mime)
    }
}

// TODO: impl through wayland layer based on https://wayland.app/protocols/ext-data-control-v1#ext_data_control_device_v1
set_clipboard_reg :: proc(data: []byte, mime: string) {
    // set the primary selection through ext_data_control_device_v1::set_primary_selection
}

// TODO: impl through wayland layer based on https://wayland.app/protocols/ext-data-control-v1#ext_data_control_device_v1
set_primary_reg :: proc(data: []byte, mime: string) {
    // set the clipboard selection through ext_data_control_device_v1::set_selection
}

set_selection_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string) {
    if reg_id == lib.SELECTION_CLIPBOARD {
        set_clipboard_reg(data, mime)
    } else if reg_id == lib.SELECTION_PRIMARY {
        set_primary_reg(data, mime)
    }
}

// Overwrite a named reg
overwrite_named_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string) {
    idx := lib.reg_id_to_named_index(reg_id)
    lib.free_reg_entry(&named_registers[idx])
    named_registers[idx] = lib.Reg_Entry {
        data      = slice.clone(data),
        mime_type = strings.clone(mime),
        timestamp = time.time_to_unix(time.now()),
    }
}

// Append to a named reg
append_named_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string) -> bool {
    idx := lib.reg_id_to_named_index(reg_id)
    reg_entry := &named_registers[idx]

    if reg_entry.data == nil {
        // Nothing to append to, treat same as set
        named_registers[idx] = lib.Reg_Entry {
            data      = slice.clone(data),
            mime_type = strings.clone(mime),
            timestamp = time.time_to_unix(time.now()),
        }
        return true
    }

    if reg_entry.mime_type != mime {
        return false
    }

    // Concatenate
    new_data := make([]byte, len(reg_entry.data) + len(data))
    copy(new_data, reg_entry.data)
    copy(new_data[len(reg_entry.data):], data)
    delete(reg_entry.data)
    reg_entry.data = new_data
    reg_entry.timestamp = time.time_to_unix(time.now())
    return true
}

// Zero out a named slot
clear_named_reg :: proc(reg_id: lib.Reg_Id) {
    idx := lib.reg_id_to_named_index(reg_id)
    lib.free_reg_entry(&named_registers[idx])
}

