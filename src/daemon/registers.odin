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
push_recency_reg :: proc(ring: ^Recency_Ring, data: []u8, mime: string) {
    ring.head = (ring.head + 1) % lib.RECENCY_SIZE
    lib.free_reg_entry(&ring.entries[ring.head])
    ring.entries[ring.head] = lib.Reg_Entry {
        data      = slice.clone(data),
        mime_type = strings.clone(mime),
        timestamp = time.time_to_unix(time.now()),
    }
    ring.count = min(ring.count + 1, lib.RECENCY_SIZE)
}

// Get the `recency` most recent `Register_Entry`
get_recency_reg :: proc(ring: ^Recency_Ring, recency: u8) -> ^lib.Reg_Entry {
    if recency >= ring.count {return nil}
    idx := (ring.head - recency + lib.RECENCY_SIZE) % lib.RECENCY_SIZE
    return &ring.entries[idx]
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
    return nil
}

get_registers :: proc(filter: lib.Cmd_Get_Filter, regs: ^[46]lib.Resp_Reg) -> (count: u8, ok: bool) {
    // TODO: Temporary for testing
    free_ring(&clipboard_registers)
    free_ring(&primary_registers)
    for &entry in named_registers {
        lib.free_reg_entry(&entry)
    }
    named_registers = {}
    push_recency_reg(&clipboard_registers, transmute([]u8)string("https://github.com/odin-lang/Odin"), "text/uri-list")
    push_recency_reg(&clipboard_registers, transmute([]u8)string("fn main() { println!(\"hello\"); }"), "text/plain")
    push_recency_reg(&clipboard_registers, transmute([]u8)string("<div class=\"container\">content</div>"), "text/html")
    push_recency_reg(&clipboard_registers, transmute([]u8)string("short"), "text/plain")
    push_recency_reg(&primary_registers, transmute([]u8)string("selected text from browser"), "text/plain")
    push_recency_reg(&primary_registers, transmute([]u8)string("{\"key\": \"value\", \"num\": 42}"), "application/json")
    push_recency_reg(&primary_registers, transmute([]u8)string("another primary selection that is longer than the content column width for testing truncation"), "text/plain")
    push_recency_reg(&primary_registers, transmute([]u8)string("/home/user/.config/clipbender/config"), "text/plain")
    set_named_reg(.OVERWRITE, lib.Reg_Id(lib.NAMED_START + 3), transmute([]u8)string("persistent snippet stored in register d"), "text/plain")
    set_named_reg(.OVERWRITE, lib.Reg_Id(lib.NAMED_START + 5), transmute([]u8)string("git@github.com:user/repo.git"), "text/plain")
    set_named_reg(.OVERWRITE, lib.Reg_Id(lib.NAMED_END - 2), transmute([]u8)string("<p>some html content</p>"), "text/html")

    count = 0
    for bit in filter & lib.CMD_GET_FILTER_CLIPBOARD {
        entry := get_recency_reg(&clipboard_registers, u8(bit))
        if entry == nil {continue}
        regs[count] = lib.Resp_Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_NAMED {
        entry := get_named_reg(u8(bit) - u8(lib.NAMED_START))
        if entry == nil {continue}
        regs[count] = lib.Resp_Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    for bit in filter & lib.CMD_GET_FILTER_PRIMARY {
        entry := get_recency_reg(&primary_registers, u8(bit) - u8(lib.PRIMARY_START))
        if entry == nil {continue}
        regs[count] = lib.Resp_Reg {
            id    = lib.Reg_Id(bit),
            entry = entry^,
        }
        count += 1
    }

    return count, true
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
set_selection_clipboard_reg :: proc(data: []byte, mime: string) {
    // set the primary selection through ext_data_control_device_v1::set_primary_selection
}

// TODO: impl through wayland layer based on https://wayland.app/protocols/ext-data-control-v1#ext_data_control_device_v1
set_selection_primary_reg :: proc(data: []byte, mime: string) {
    // set the clipboard selection through ext_data_control_device_v1::set_selection
}

set_selection_reg :: proc(reg_id: lib.Reg_Id, data: []byte, mime: string) {
    if reg_id == lib.SELECTION_CLIPBOARD {
        set_selection_clipboard_reg(data, mime)
    } else if reg_id == lib.SELECTION_PRIMARY {
        set_selection_primary_reg(data, mime)
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

