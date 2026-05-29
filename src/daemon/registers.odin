package main

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

// Push to head, overwriting any existing value
push_recency_reg :: proc(ring: ^Recency_Ring, entry: lib.Reg_Entry) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    free_reg_entry(&ring.entries[ring.head])
    ring.entries[ring.head] = lib.Reg_Entry {
        data      = slice.clone(entry.data),
        mime_type = strings.clone(entry.mime_type),
        timestamp = entry.timestamp,
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

// Get the `recency` most recent `Register_Entry`
get_recency_reg :: proc(ring: ^Recency_Ring, recency: u8) -> (^lib.Reg_Entry, bool) {
    if recency >= ring.count {return nil, false}
    idx := (ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
    return &ring.entries[idx], true
}

// TODO: make these persistent in the future by writing state to binary
clipboard_registers: Recency_Ring
named_registers: [26]lib.Reg_Entry
primary_registers: Recency_Ring

free_reg_entry :: proc(reg_entry: ^lib.Reg_Entry) {
    delete(reg_entry.data)
    delete(reg_entry.mime_type)
    reg_entry^ = {}
}

set_clipboard_reg :: proc(data: []byte, mime: string) {
    reg_entry := lib.Reg_Entry{data, mime, time.time_to_unix(time.now())}
    push_recency_reg(&clipboard_registers, reg_entry)
}

set_primary_reg :: proc(data: []byte, mime: string) {
    reg_entry := lib.Reg_Entry{data, mime, time.time_to_unix(time.now())}
    push_recency_reg(&primary_registers, reg_entry)
}

// Look up by id, index into the right array
get_reg :: proc(reg_id: lib.Reg_Id) -> (^lib.Reg_Entry, bool) {
    if lib.reg_id_is_clipboard_num(reg_id) {
        recency := lib.reg_id_to_clipboard_index(reg_id)
        return get_recency_reg(&clipboard_registers, recency)
    } else if lib.reg_id_is_named(reg_id) {
        idx := lib.reg_id_to_named_index(reg_id)
        if named_registers[idx].data == nil {
            return nil, false
        }
        return &named_registers[idx], true
    } else if lib.reg_id_is_primary_num(reg_id) {
        recency := lib.reg_id_to_primary_index(reg_id)
        return get_recency_reg(&primary_registers, recency)
    }
    return nil, false
}

// Overwrite a named reg
set_named_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string) {
    idx := lib.reg_id_to_named_index(reg_id)
    free_reg_entry(&named_registers[idx])
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
    free_reg_entry(&named_registers[idx])
}

