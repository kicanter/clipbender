package base

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

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

reg_id_is_selection :: proc(id: Reg_Id) -> bool {
    return id == SELECTION_CLIPBOARD || id == SELECTION_PRIMARY
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

reg_id_to_string :: proc(id: Reg_Id) -> string {
    if reg_id_is_clipboard_num(id) {
        return fmt.tprintf("%d", reg_id_to_clipboard_index(id))
    } else if reg_id_is_primary_num(id) {
        return fmt.tprintf("@%d", reg_id_to_primary_index(id))
    } else if reg_id_is_named(id) {
        return fmt.tprintf("%c", rune(reg_id_to_named_index(id) + 'a'))
    } else if id == SELECTION_CLIPBOARD {
        return "clipboard"
    } else if id == SELECTION_PRIMARY {
        return "primary"
    }
    return "unknown reg id"
}

Selection_Type :: enum u8 {
    CLIPBOARD,
    PRIMARY,
}

// Runtime polymoprhic struct to dynamically dispatch to Wayland or X11
Clipboard_Backend :: struct {
    fd:            linux.Fd,
    dispatch:      proc(state: rawptr) -> bool,
    cleanup:       proc(state: rawptr),
    set_selection: proc(state: rawptr, data: []u8, mime: string, type: Selection_Type),
    state:         rawptr,
}

Session_Type :: enum u8 {
    WAYLAND,
    X11,
    OTHER,
}

get_session_type :: proc() -> Session_Type {
    // Get Wayland or X11 session type
    session_type := os.get_env("XDG_SESSION_TYPE", context.allocator)
    defer delete(session_type)

    switch session_type {
    case "wayland":
        return .WAYLAND
    case "x11":
        return .X11
    case:
        return .OTHER
    }
}

// Protocol/IPC

// Return a path built from an env var directory, using a fallback if the env var doesn't exist or isn't a directory.
// Fallback to using `fallback_dir` if the `env_var` doesn't exist or isn't a directory.
// Caller is responsible for freeing returned string.
env_path_with_fallback :: proc(env_var: string, subdir: string, filename: string, fallback_dir: string) -> string {
    env_var_dir := os.get_env(env_var, context.allocator)
    defer delete(env_var_dir)

    dir: string
    if len(env_var_dir) == 0 || !os.is_directory(env_var_dir) {
        if len(env_var_dir) > 0 {
            log.warnf("%s env var is not a directory, you should probably fix this (got %s)", env_var, env_var_dir)
        }
        // Use fallback if we can't build a path from the env var
        dir = fmt.tprintf("%s/%s", fallback_dir, subdir)
    } else {
        dir = fmt.tprintf("%s/%s", env_var_dir, subdir)
    }

    os.make_directory_all(dir)
    return fmt.aprintf("%s/%s", dir, filename)
}

RUNTIME_ENV_VAR :: "XDG_RUNTIME_DIR"
TMP_DIR :: "/tmp"
CLIPBENDER_SUBDIR :: "clipbender"
SOCKET_FILENAME :: "clipbender.sock"
LOCK_FILENAME :: "clipbender-gui.lock"

// Caller is responsible for freeing returned string.
clipbender_socket_path :: proc() -> string {
    return env_path_with_fallback(RUNTIME_ENV_VAR, CLIPBENDER_SUBDIR, SOCKET_FILENAME, TMP_DIR)
}

// Caller is responsible for freeing returned string.
clipbender_lock_path :: proc() -> string {
    return env_path_with_fallback(RUNTIME_ENV_VAR, CLIPBENDER_SUBDIR, LOCK_FILENAME, TMP_DIR)
}

// Kinds of messages (commands) passed from client to daemon. IPC wire format:
//
// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
// SET (INLINE):   `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime type len][M mime type][N data]`
// GET:            `[1b Message_Type][8b Cmd_Get_filter]`
// CLEAR:          `[1b Message_Type][1b Reg_Id]`
// SHUTDOWN:       `[1b Message_Type]`
//
// > NOTE: SEQPACKET gives us total message size on recv and maintains message boundaries as opposed to a STREAM, so we
// > don't need to encode the data length in the SET (INLINE) message to determine how many bytes to read.
Command_Type :: enum u8 {
    SET,
    GET,
    CLEAR,
    SHUTDOWN,
}

// For SET operations, whether the register should be overwritten or appended
Set_Mode :: enum u8 {
    OVERWRITE, // lowercase named register
    APPEND, // uppercase named register
}

// Source from which the data is coming from in a SET operation.
//
// `REGISTER` indicates that daemon must fetch the data. This may be a numbered/named register that Clipbender just
// reads from, or it could be the clipboard/primary selection that Clipbender must request the data from at the time of
// the call.
//
// `INLINE` indicates the client is passing the data inline over the wire through the IPC message. These will tend to
// have "text/plain" as their mime type, but the client must do it's best job interpreting what mime the data most
// likely is.
Source_Kind :: enum u8 {
    REGISTER, // either a numbered/named register or clipboard/primary selection
    INLINE, // data that's passed inline in the IPC message e.g. stdin or string literal
}

// Bitmask filter assembled from GET args.
Cmd_Get_Filter :: bit_set[0 ..= 45;u64]
// Keywords for GET CLI
CMD_GET_FILTER_CLIPBOARD :: transmute(Cmd_Get_Filter)u64(0x3FF) // bits 0-9
CMD_GET_FILTER_NAMED :: transmute(Cmd_Get_Filter)(u64(0x3FFFFFF) << 10) // bits 10-35
CMD_GET_FILTER_PRIMARY :: transmute(Cmd_Get_Filter)(u64(0x3FF) << 36) // bits 36-45
CMD_GET_FILTER_NUMBERED :: CMD_GET_FILTER_CLIPBOARD + CMD_GET_FILTER_PRIMARY
CMD_GET_FILTER_ALL :: CMD_GET_FILTER_NAMED + CMD_GET_FILTER_NUMBERED

// Response status from daemon. IPC wire format:
//
// OK:    `[1 byte Response_Status]`
// ERROR: `[1 byte Response_Status][N bytes error message]`
// REGISTERS:  `[1 byte Response_Status][1 byte u8 count][count * Reg]`
Resp_Status :: enum u8 {
    OK,
    ERROR,
    REGISTERS,
}

// Register data daemon returns to client for a GET operation. IPC wire format:
//
// `[1 byte Reg_Id][8 bytes i64 timestamp][1 byte mime type len][M bytes mime type][4 bytes data length][N bytes data]`
Reg :: struct {
    id:    Reg_Id,
    entry: Reg_Entry,
}

free_reg_entry :: proc(reg_entry: ^Reg_Entry) {
    delete(reg_entry.data)
    delete(reg_entry.mime_type)
    reg_entry^ = {}
}

//// Encoding/decode to/from IPC wire format

// Client-side

// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
marshal_cmd_set_reg :: proc(dest: Reg_Id, source: Reg_Id, set_mode: Set_Mode, buf: []byte) -> int {
    buf[0] = byte(Command_Type.SET)
    buf[1] = byte(dest)
    buf[2] = byte(set_mode)
    buf[3] = byte(Source_Kind.REGISTER)
    buf[4] = byte(source)
    return size_of(Command_Type) + (2 * size_of(Reg_Id)) + size_of(Set_Mode) + size_of(Source_Kind)
}

// SET (INLINE): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime type len][M mime type][N data]`
marshal_cmd_set_inline :: proc(dest: Reg_Id, set_mode: Set_Mode, mime: string, data: []byte, buf: []byte) -> int {
    buf[0] = byte(Command_Type.SET)
    buf[1] = byte(dest)
    buf[2] = byte(set_mode)
    buf[3] = byte(Source_Kind.INLINE)
    mime_len := u8(len(mime))
    buf[4] = byte(mime_len)
    written := size_of(Command_Type) + size_of(Reg_Id) + size_of(Set_Mode) + size_of(Source_Kind) + size_of(mime_len)
    copy(buf[written:][:int(mime_len)], mime)
    written += int(mime_len)
    copy(buf[written:][:len(data)], data)
    written += len(data)
    return written
}

// GET: `[1b Message_Type][8b Cmd_Get_filter]`
marshal_cmd_get :: proc(filter: Cmd_Get_Filter, buf: []byte) -> int {
    buf[0] = byte(Command_Type.GET)
    bytes := transmute([8]byte)filter
    copy(buf[1:9], bytes[:])
    return size_of(Command_Type) + size_of(Cmd_Get_Filter)
}

// CLEAR: `[1b Message_Type][1b Reg_Id]`
marshal_cmd_clear :: proc(reg_id: Reg_Id, buf: []byte) -> int {
    buf[0] = byte(Command_Type.CLEAR)
    buf[1] = byte(reg_id)
    return size_of(Command_Type) + size_of(Reg_Id)
}

// SHUTDOWN: `[1b Message_Type]`
marshal_cmd_shutdown :: proc(buf: []byte) -> int {
    buf[0] = byte(Command_Type.SHUTDOWN)
    return size_of(Command_Type)
}

// ok/error responses handled inline
// REGISTERS: `[1 byte Response_Status][1 byte u8 count][count * Reg]`
// buf starts after first Response_Status byte
// NOTE: caller is responsible for freeing all entries in `regs`
unmarshal_resp_registers :: proc(buf: []byte, regs: ^[46]Reg) -> (count: u8) {
    count = u8(buf[0])

    offset := 1
    for i in 0 ..< count {
        reg_id := Reg_Id(buf[offset])
        offset += size_of(Reg_Id)

        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], buf[offset:][:size_of(i64)])
        time := transmute(i64)time_bytes
        offset += size_of(i64)

        mime_len := u8(buf[offset])
        offset += size_of(mime_len)
        mime := strings.clone(string(buf[offset:][:int(mime_len)]))
        offset += int(mime_len)

        data_len_bytes: [size_of(u32)]byte
        copy(data_len_bytes[:], buf[offset:][:size_of(u32)])
        data_len := transmute(u32)data_len_bytes
        offset += size_of(u32)
        data := slice.clone(buf[offset:][:int(data_len)])
        offset += int(data_len)

        reg_entry := Reg_Entry {
            data      = data,
            mime_type = mime,
            timestamp = time,
        }

        resp_reg := Reg {
            id    = reg_id,
            entry = reg_entry,
        }

        regs[i] = resp_reg
    }

    return count
}

// Daemon-side

// OK: `1 byte Response_Status]`
marshal_resp_ok :: proc(buf: []byte) -> int {
    buf[0] = byte(Resp_Status.OK)
    return size_of(Resp_Status)
}

// ERROR: `[1 byte Response_Status][N bytes error message]`
marshal_resp_error :: proc(message: string, buf: []byte) -> int {
    buf[0] = byte(Resp_Status.ERROR)
    copy(buf[1:][:len(message)], message)
    return size_of(Resp_Status) + len(message)
}

// REGISTERS: `[1 byte Response_Status][1 byte u8 count][count * Reg]`
marshal_resp_registers :: proc(regs: []Reg, buf: []byte) -> int {
    buf[0] = byte(Resp_Status.REGISTERS)
    count := u8(len(regs))
    buf[1] = byte(count)
    written := size_of(Resp_Status) + size_of(u8)

    for reg in regs {
        buf[written] = byte(reg.id)
        written += size_of(Reg_Id)

        time_bytes := transmute([size_of(i64)]byte)reg.entry.timestamp
        copy(buf[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        mime := reg.entry.mime_type
        mime_len := u8(len(mime))
        buf[written] = byte(mime_len)
        written += size_of(mime_len)
        copy(buf[written:][:int(mime_len)], mime)
        written += int(mime_len)

        data := reg.entry.data
        data_len := u32(len(data))
        data_len_bytes := transmute([size_of(u32)]byte)data_len
        copy(buf[written:][:size_of(u32)], data_len_bytes[:])
        written += size_of(u32)
        copy(buf[written:][:int(data_len)], data)
        written += int(data_len)
    }

    return written
}

// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
// buf starts after Source_Kind byte
unmarshal_cmd_set_reg :: proc(buf: []byte) -> Reg_Id {
    return Reg_Id(buf[0])
}

// SET (INLINE): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime type len][M mime type][N data]`
// buf starts after Source_Kind byte
unmarshal_cmd_set_inline :: proc(buf: []byte) -> (mime: string, data: []byte) {
    mime_len := u8(buf[0])
    mime = strings.clone(string(buf[1:1 + mime_len]))
    data = slice.clone(buf[1 + mime_len:])
    return mime, data
}

// GET: `[1b Message_Type][8b Cmd_Get_filter]`
// buf starts after first Message_Type byte
unmarshal_cmd_get :: proc(buf: []byte) -> Cmd_Get_Filter {
    filter_bytes: [8]byte
    copy(filter_bytes[:], buf)
    return transmute(Cmd_Get_Filter)(transmute(u64)(filter_bytes))
}

// CLEAR: `[1b Message_Type][1b Reg_Id]`
// buf starts after first Message_Type byte
unmarshal_cmd_clear :: proc(buf: []byte) -> Reg_Id {
    return Reg_Id(buf[0])
}

// OK: `[1 byte Response_Status]`
// No payload to unmarshal
unmarshal_resp_ok :: proc(buf: []byte) -> Resp_Status {
    return .OK
}

// ERROR: `[1 byte Response_Status][N bytes error message]`
// buf starts after first Response_Status byte
unmarshal_resp_error :: proc(buf: []byte) -> string {
    return string(buf)
}

