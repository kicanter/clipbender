package lib

import "core:fmt"
import "core:os"

clipbender_socket_path :: proc() -> string {
    // Get XDG_RUNTIME_DIR, fallback to /tmp
    socket_dir := os.get_env("XDG_RUNTIME_DIR", context.allocator)
    if len(socket_dir) == 0 || !os.is_directory(socket_dir) {
        socket_dir = "/tmp"
    }
    return fmt.tprintf("%s/clipbender.sock", socket_dir)
}

// Kinds of messages passed between client and daemon
Message_Type :: enum u8 {
    SET,
    GET,
    CLEAR,
    SHUTDOWN,
}

// Info related to a single register entry
Register_Entry :: struct {
    data:       []byte,
    mime_type:  string,
    timestampe: i64, // unix epoch time
}

// Register IDs
// Pack into a single byte to reduce data sent across IPC
Register_Id :: distinct u8

CLIPBOARD_START :: Register_Id(0)
CLIPBOARD_END :: Register_Id(9)
NAMED_START :: Register_Id(10)
NAMED_END :: Register_Id(35)
PRIMARY_START :: Register_Id(36)
PRIMARY_END :: Register_Id(45)
SELECTION_PRIMARY :: Register_Id(254)
SELECTION_CLIPBOARD :: Register_Id(255)

// Register ID validation
register_id_is_valid :: proc(id: Register_Id) -> bool {
    return id <= PRIMARY_END || id == SELECTION_CLIPBOARD || id == SELECTION_PRIMARY
}

register_id_is_clipboard_num :: proc(id: Register_Id) -> bool {
    return id >= CLIPBOARD_START && id <= CLIPBOARD_END
}

register_id_is_named :: proc(id: Register_Id) -> bool {
    return id >= NAMED_START && id <= NAMED_END
}

register_id_is_primary_num :: proc(id: Register_Id) -> bool {
    return id >= PRIMARY_START && id <= PRIMARY_END
}

register_id_is_read_only :: proc(id: Register_Id) -> bool {
    return register_id_is_clipboard_num(id) || register_id_is_primary_num(id)
}

// Conversions
register_id_from_clipboard_index :: proc(i: u8) -> Register_Id {
    return Register_Id(i)
}

register_id_from_named_letter :: proc(ch: u8) -> Register_Id {
    return Register_Id(ch - 'a') + NAMED_START
}

register_id_to_named_letter :: proc(id: Register_Id) -> u8 {
    return u8(id - NAMED_START) + 'a'
}

register_id_from_primary_index :: proc(i: u8) -> Register_Id {
    return Register_Id(i) + PRIMARY_START
}

