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
Reg_Entry :: struct {
    data:      []byte,
    mime_type: string,
    timestamp: i64, // unix epoch time
}

// Register IDs
// Pack into a single byte to reduce data sent across IPC
Reg_Id :: distinct u8
RECENCY_SIZE :: 10

CLIPBOARD_START :: Reg_Id(0)
CLIPBOARD_END :: Reg_Id(9)
NAMED_START :: Reg_Id(10)
NAMED_END :: Reg_Id(35)
PRIMARY_START :: Reg_Id(36)
PRIMARY_END :: Reg_Id(45)
SELECTION_PRIMARY :: Reg_Id(254)
SELECTION_CLIPBOARD :: Reg_Id(255)

// Register ID validation
reg_id_is_valid :: proc(id: Reg_Id) -> bool {
    return id <= PRIMARY_END || id == SELECTION_CLIPBOARD || id == SELECTION_PRIMARY
}

reg_id_is_clipboard_num :: proc(id: Reg_Id) -> bool {
    return id >= CLIPBOARD_START && id <= CLIPBOARD_END
}

reg_id_is_named :: proc(id: Reg_Id) -> bool {
    return id >= NAMED_START && id <= NAMED_END
}

reg_id_is_primary_num :: proc(id: Reg_Id) -> bool {
    return id >= PRIMARY_START && id <= PRIMARY_END
}

reg_id_is_read_only :: proc(id: Reg_Id) -> bool {
    return reg_id_is_clipboard_num(id) || reg_id_is_primary_num(id)
}

// Conversions
reg_id_from_clipboard_index :: proc(i: u8) -> Reg_Id {
    return Reg_Id(i)
}
reg_id_from_named_index :: proc(i: u8) -> Reg_Id {
    return Reg_Id(i) + NAMED_START
}
reg_id_from_primary_index :: proc(i: u8) -> Reg_Id {
    return Reg_Id(i) + PRIMARY_START
}

reg_id_to_clipboard_index :: proc(id: Reg_Id) -> u8 {
    return u8(id)
}
reg_id_to_named_index :: proc(id: Reg_Id) -> u8 {
    return u8(id - NAMED_START)
}
reg_id_to_primary_index :: proc(id: Reg_Id) -> u8 {
    return u8(id - PRIMARY_START)
}

