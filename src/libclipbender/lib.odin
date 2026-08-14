package libclipbender

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

// Max data allowed to pass over IPC
MAX_MSG_SIZE :: 65536 // 64 KiB

// Representation of a single unique data blob and a list of mimes it can represent
Mime_Blob :: struct {
    data:  []byte,
    mimes: []string,
}

// Info related to a single register entry, includes a `Mime_Blob` for every mime associated with the selection and a
// timestamp.
Reg_Entry :: struct {
    blobs:     []Mime_Blob,
    timestamp: i64, // unix epoch time
}

// Register IDs
// Pack into a single byte to reduce data sent across IPC
RECENCY_SIZE :: 10
NAMED_SIZE :: 26

Reg_Id :: distinct u8
CLIPBOARD_START :: Reg_Id(0)
CLIPBOARD_END :: Reg_Id(9)
NAMED_START :: Reg_Id(10)
NAMED_END :: Reg_Id(35)
PRIMARY_START :: Reg_Id(36)
PRIMARY_END :: Reg_Id(45)
// Live system selections. Kept in the top of the 0-63 range so they fit in the Cmd_Get_Filter bit_set (u64-backed)
// and can be filtered/returned by GET like any other register. Bits 46-61 are reserved for future expansion.
SELECTION_PRIMARY :: Reg_Id(62)
SELECTION_CLIPBOARD :: Reg_Id(63)

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

// `CLIPBOARD` is your typical copy/paste, `PRIMARY` is Linux's highlight + middle-click to paste feature.
Selection_Type :: enum u8 {
    CLIPBOARD,
    PRIMARY,
}

// Runtime polymoprhic struct to dynamically dispatch to Wayland or X11.
Clipboard_Backend :: struct {
    fd:            linux.Fd,
    dispatch:      proc(state: rawptr) -> bool,
    cleanup:       proc(state: rawptr),
    set_selection: proc(state: rawptr, data: []u8, mime: string, type: Selection_Type),
    state:         rawptr,
}

// `OTHER` is unused.
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
// GET:            `[1b Message_Type][1b group count]` then per group:
//                 `[8b Cmd_Get_Filter][1b mime pref tag]` plus `[1b mime type len][M mime type]` for EXACT only
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
Cmd_Get_Filter :: bit_set[0 ..= 63;u64]
// Keywords for GET CLI
CMD_GET_FILTER_NUMBERED :: transmute(Cmd_Get_Filter)u64(0x3FF) // clipboard recency, bits 0-9
CMD_GET_FILTER_NAMED :: transmute(Cmd_Get_Filter)(u64(0x3FFFFFF) << 10) // named a-z, bits 10-35
CMD_GET_FILTER_PRIMARY_NUMBERED :: transmute(Cmd_Get_Filter)(u64(0x3FF) << 36) // primary recency, bits 36-45
CMD_GET_FILTER_PRIMARY_SELECTION :: transmute(Cmd_Get_Filter)(u64(1) << 62) // live primary selection, bit 62
CMD_GET_FILTER_SELECTION :: transmute(Cmd_Get_Filter)(u64(1) << 63) // live clipboard selection, bit 63
CMD_GET_FILTER_ALL ::
    CMD_GET_FILTER_NUMBERED +
    CMD_GET_FILTER_NAMED +
    CMD_GET_FILTER_PRIMARY_NUMBERED +
    CMD_GET_FILTER_SELECTION +
    CMD_GET_FILTER_PRIMARY_SELECTION

// Total number of allowed registers i.e. the size of a register-indexed array. Bits 46-61 are currently unused but
// reserved.
MAX_REGS :: 64

// Preference of mime type to pass data for from daemon -> client. Clients use this in their GET IPC request to indicate
// whether they want the daemon to handle picking the best mime that the blob provides or if the client wants to pass
// the exact mime they want to receive.
//
// `Ranked_Mime` represents the daemon picking the highest priority mime. `SIMPLEST` meaning less fidelity e.g.
// plaintext mimes and `RICHEST` meaning more fidelity e.g. images, richtext, uri-list, etc.
//
// `Exact_Mime` represents the client picking the mime they want to receive. It's just an alias for a string which will
// be the literal mime type for the daemon to fetch.
Mime_Pref :: union #no_nil {
    Ranked_Mime, // daemon is in charge of selecting the highest prioritized mime
    Exact_Mime, // client passes exactly what mime type they want to receive
}
Ranked_Mime :: enum u8 {
    SIMPLEST, // prefer simpler mimes like plaintext first
    RICHEST, // prefer richer mimes like images or richtext first
}
Exact_Mime :: distinct string // specify exactly what mime to receive
// Wire tag for the `Mime_Pref` union. `Ranked_Mime` variants encode as their own ordinals (SIMPLEST=0, RICHEST=1) and
// `Exact_Mime` takes the next value after them, derived so that adding a ranked variant shifts the sentinel
// automatically instead of silently colliding with it.
//
// This is the value one past the last ranked variant, not a count of wire tags. Deriving it from `len` only works while
// `Ranked_Mime` stays contiguous from zero -- assigning explicit values would leave `len` unchanged while moving the
// variants, so `Ranked_Mime(tag)` would decode garbage. The assert pins that down.
EXACT_MIME_TAG :: u8(len(Ranked_Mime))
// ensure the tag for `Exact_Mime` is one more than the last in `Ranked_Mime`
#assert(u8(max(Ranked_Mime)) + 1 == EXACT_MIME_TAG)

// Max byte length of a mime string on the wire. Lengths are encoded as a u8, and unmarshaling computes `1 + mime_len`,
// so 255 wraps to 0 and produces invalid slice indices; 254 is the ceiling. Real mimes are far shorter
// ("text/plain;charset=utf-8" is 24), so callers must reject anything longer rather than truncate: a truncated mime
// still matches *something* on the daemon side, silently returning the wrong blob.
MAX_MIME_LEN :: 254

SIMPLEST_MIMES :: [?]string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"}
RICHEST_MIMES :: [?]string {
    "image/png",
    "image/webp",
    "image/jpeg",
    "image/gif",
    "image/svg+xml",
    "text/html",
    "text/uri-list",
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
}

// To reduce bytes passed over IPC, group registers together that share one mime preference. Grouping by *preference*
// rather than by register is what keeps ranges cheap: `+a:z=text/plain` is one group (22 bytes) because the mime string
// appears once and the registers collapse into the bitmask; keying by register would repeat the mime 26 times.
//
// The mime lives inside `pref` (as `Exact_Mime`) rather than in a separate field, so "ranked but with a mime" and
// "exact but with no mime" are both unrepresentable.
Cmd_Get_Group :: struct {
    filter: Cmd_Get_Filter,
    pref:   Mime_Pref,
}

// A GET request cannot exceed MAX_MSG_SIZE by construction: every group must claim at least one register bit, so there
// are at most MAX_REGS groups, and each mime is capped at 255 bytes by its u8 length field. Worst case is 16962 bytes,
// ~26% of the buffer. This assert keeps that proof honest if the encoding ever grows.
#assert(
    size_of(Command_Type) +
        size_of(u8) +
        MAX_REGS * (size_of(Cmd_Get_Filter) + size_of(EXACT_MIME_TAG) + size_of(u8) + 255) <=
    MAX_MSG_SIZE,
)

// Response status from daemon. IPC wire format:
//
// OK:    `[1 byte Response_Status]`
// ERROR: `[1 byte Response_Status][N bytes error message]`
// REGISTERS:  `[1 byte Response_Status][1 byte u8 count][count * entry]`
//
// where each GET response entry is:
// `[1 byte Reg_Id][8 bytes i64 timestamp][1 byte mime len][M bytes mime][4 bytes u32 data len][N bytes data]`
//
// One mime + one data blob per entry: GET is a query, so it packs only the representation the client
// asked for. The state file (see marshal_state) persists full fidelity instead.
Resp_Status :: enum u8 {
    OK,
    ERROR,
    REGISTERS,
}

// Construct a single-mime Mime_Blob, taking ownership of `data` and `mime` (both must be heap-allocated).
mime_blob_single :: proc(data: []byte, mime: string) -> Mime_Blob {
    mimes := make([]string, 1)
    mimes[0] = mime
    return Mime_Blob{data = data, mimes = mimes}
}

// Heap-allocate a single-element []Mime_Blob (a composite-literal slice would point at stack memory).
mime_blob_slice :: proc(blob: Mime_Blob) -> []Mime_Blob {
    blobs := make([]Mime_Blob, 1)
    blobs[0] = blob
    return blobs
}

free_mime_data :: proc(mime_data: Mime_Blob) {
    delete(mime_data.data)
    for mime in mime_data.mimes {
        delete(mime)
    }
    delete(mime_data.mimes)
}

// Free every blob in the entry plus the blobs slice itself, then zero the entry.
free_reg_entry :: proc(reg_entry: ^Reg_Entry) {
    for mime_data in reg_entry.blobs {
        free_mime_data(mime_data)
    }
    delete(reg_entry.blobs)
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

// GET: `[1b Message_Type][1b group_count]` then per group:
//      `[8b Cmd_Get_Filter][1b mime pref tag]` followed by `[1b mime len][M mime]` for EXACT only.
//
// The trailing mime is present only for EXACT, so a ranked group is 9 bytes and `get ++all` is 11.
// Callers must reject mimes longer than MAX_MIME_LEN before calling; this truncates rather than failing, matching
// marshal_cmd_set_inline.
marshal_cmd_get :: proc(groups: []Cmd_Get_Group, buf: []byte) -> int {
    buf[0] = byte(Command_Type.GET)
    buf[1] = u8(len(groups))
    written := size_of(Command_Type) + size_of(u8)

    for group in groups {
        filter_bytes := transmute([8]byte)group.filter
        copy(buf[written:][:size_of(Cmd_Get_Filter)], filter_bytes[:])
        written += size_of(Cmd_Get_Filter)

        switch pref in group.pref {
        case Ranked_Mime:
            buf[written] = u8(pref)
            written += size_of(EXACT_MIME_TAG)
        case Exact_Mime:
            buf[written] = EXACT_MIME_TAG
            written += size_of(EXACT_MIME_TAG)
            mime_len := u8(min(len(pref), MAX_MIME_LEN))
            buf[written] = byte(mime_len)
            written += size_of(mime_len)
            copy(buf[written:][:int(mime_len)], string(pref))
            written += int(mime_len)
        }
    }

    return written
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

// ok/error responses handled inline
// REGISTERS: `[1 byte Response_Status][1 byte u8 count][count * Reg]`
// buf starts after first Response_Status byte
// Scatters each packed wire entry into its Reg_Id slot in `regs`. Slots not present in the response are left zeroed.
// NOTE: caller is responsible for freeing all entries in `regs`
unmarshal_resp_registers :: proc(buf: []byte, regs: ^[MAX_REGS]Reg_Entry) -> (count: u8) {
    regs^ = {}
    count = u8(buf[0])

    offset := 1
    for _ in 0 ..< count {
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

        // Index by Reg_Id: the array position implicitly encodes the register identity.
        // M1: single blob, single mime per entry. Heap-allocate the blobs slice so it outlives
        // this stack frame (a composite-literal slice would point at reused stack memory).
        regs[reg_id] = Reg_Entry {
            blobs     = mime_blob_slice(mime_blob_single(data, mime)),
            timestamp = time,
        }
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
// `regs` is indexed by Reg_Id; only non-empty slots are packed onto the wire, each tagged with its Reg_Id.
marshal_resp_registers :: proc(regs: [MAX_REGS]^Reg_Entry, buf: []byte) -> int {
    buf[0] = byte(Resp_Status.REGISTERS)
    // Reserve the count byte, fill it in after we know how many non-empty entries there are
    written := size_of(Resp_Status) + size_of(u8)
    count: u8 = 0

    for entry_ptr, id in regs {
        if entry_ptr == nil {continue}

        // Reg ID u8
        buf[written] = byte(id)
        written += size_of(Reg_Id)

        // Timestamp i64
        time_bytes := transmute([size_of(i64)]byte)entry_ptr.timestamp
        copy(buf[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        // M1: single blob, single mime per entry
        blob := entry_ptr.blobs[0]

        // Mime length u8 + mime string bytes
        mime := blob.mimes[0]
        mime_len := u8(len(mime))
        buf[written] = byte(mime_len)
        written += size_of(mime_len)
        copy(buf[written:][:int(mime_len)], mime)
        written += int(mime_len)

        // Data length u32 + data blob bytes
        data := blob.data
        data_len := u32(len(data))
        data_len_bytes := transmute([size_of(u32)]byte)data_len
        copy(buf[written:][:size_of(u32)], data_len_bytes[:])
        written += size_of(u32)
        copy(buf[written:][:int(data_len)], data)
        written += int(data_len)

        count += 1
    }

    // Count
    buf[1] = byte(count)
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

// GET: `[1b Message_Type][1b group_count]` then per group:
//      `[8b Cmd_Get_Filter][1b mime pref tag]` followed by `[1b mime len][M mime]` for EXACT only.
// buf starts after first Message_Type byte
//
// Decodes into a caller-provided fixed array so an untrusted `group_count` cannot drive an allocation. Every length is
// bounds-checked against `buf` before use, and an unknown pref tag is rejected *before* the offset advances: group size
// depends on that byte, so guessing it would read the next group's filter bytes as a mime length and desync the rest of
// the message.
//
// Exact mimes borrow from `buf` rather than cloning; the daemon's receive buffer outlives the handler.
unmarshal_cmd_get :: proc(buf: []byte, groups: ^[MAX_REGS]Cmd_Get_Group) -> (count: int, err: Maybe(string)) {
    if len(buf) == 0 {
        return 0, "GET request truncated: missing group count"
    }
    count = int(buf[0])
    if count == 0 || count > MAX_REGS {
        return 0, fmt.tprintf("GET request group count %d out of range (1 ..= %d)", count, MAX_REGS)
    }

    offset := size_of(u8)
    for i in 0 ..< count {
        if offset + size_of(Cmd_Get_Filter) + size_of(EXACT_MIME_TAG) > len(buf) {
            return 0, fmt.tprintf("GET request truncated: group %d missing filter/preference", i)
        }

        filter_bytes: [size_of(Cmd_Get_Filter)]byte
        copy(filter_bytes[:], buf[offset:][:size_of(Cmd_Get_Filter)])
        filter := transmute(Cmd_Get_Filter)(transmute(u64)filter_bytes)
        offset += size_of(Cmd_Get_Filter)

        // Validate before advancing: the remaining group size depends on this tag.
        tag := buf[offset]
        if tag > EXACT_MIME_TAG {
            return 0, fmt.tprintf("GET request group %d has unknown mime preference %d", i, tag)
        }
        pref: Mime_Pref = Ranked_Mime(tag) if tag < EXACT_MIME_TAG else Ranked_Mime{}
        offset += size_of(EXACT_MIME_TAG)

        if tag == EXACT_MIME_TAG {
            if offset + size_of(u8) > len(buf) {
                return 0, fmt.tprintf("GET request truncated: group %d missing mime length", i)
            }
            mime_len := int(buf[offset])
            offset += size_of(u8)
            if mime_len == 0 {
                return 0, fmt.tprintf("GET request group %d has an empty exact mime", i)
            }
            if offset + mime_len > len(buf) {
                return 0, fmt.tprintf(
                    "GET request truncated: group %d mime needs %d bytes, %d remain",
                    i,
                    mime_len,
                    len(buf) - offset,
                )
            }
            pref = Exact_Mime(string(buf[offset:][:mime_len]))
            offset += mime_len
        }

        groups[i] = Cmd_Get_Group {
            filter = filter,
            pref   = pref,
        }
    }

    return count, nil
}

// CLEAR: `[1b Message_Type][1b Reg_Id]`
// buf starts after first Message_Type byte
unmarshal_cmd_clear :: proc(buf: []byte) -> Reg_Id {
    return Reg_Id(buf[0])
}

// State-file serialization. Distinct from the GET response format: state persists FULL fidelity (every blob and every
// mime of every entry), whereas GET (marshal_resp_registers) is a query that packs a single mime/data per entry.
// Keeping them separate lets the GET format change without touching persistence.
//
// Wire format:
//   [1b count]
//   for entry in count:
//     [1b Reg_Id][8b i64 timestamp][1b blob_count]
//     for blob in blob_count:
//       [1b mime_count]
//       for mime in mime_count: [1b mime_len][mime_len bytes]
//       [4b u32 data_len][data_len bytes]
marshal_state :: proc(regs: [MAX_REGS]^Reg_Entry, buf: []byte) -> int {
    written := size_of(u8) // reserve count byte
    count: u8 = 0

    for entry_ptr, id in regs {
        if entry_ptr == nil {continue}

        // Reg ID u8
        buf[written] = byte(id)
        written += size_of(Reg_Id)

        // Timestamp i64
        time_bytes := transmute([size_of(i64)]byte)entry_ptr.timestamp
        copy(buf[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        // Blob count u8
        buf[written] = u8(len(entry_ptr.blobs))
        written += size_of(u8)

        for blob in entry_ptr.blobs {
            // Mime count u8, then each [mime_len u8][mime bytes]
            buf[written] = u8(len(blob.mimes))
            written += size_of(u8)
            for mime in blob.mimes {
                mime_len := u8(len(mime))
                buf[written] = byte(mime_len)
                written += size_of(mime_len)
                copy(buf[written:][:int(mime_len)], mime)
                written += int(mime_len)
            }

            // Data length u32 + data bytes
            data_len := u32(len(blob.data))
            data_len_bytes := transmute([size_of(u32)]byte)data_len
            copy(buf[written:][:size_of(u32)], data_len_bytes[:])
            written += size_of(u32)
            copy(buf[written:][:int(data_len)], blob.data)
            written += int(data_len)
        }

        count += 1
    }

    buf[0] = byte(count)
    return written
}

// Deserialize state into owned entries indexed by Reg_Id. Slots not present are left zeroed.
// NOTE: caller is responsible for freeing all entries in `regs`.
unmarshal_state :: proc(buf: []byte, regs: ^[MAX_REGS]Reg_Entry) -> (count: u8) {
    regs^ = {}
    count = u8(buf[0])

    offset := 1
    for _ in 0 ..< count {
        reg_id := Reg_Id(buf[offset])
        offset += size_of(Reg_Id)

        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], buf[offset:][:size_of(i64)])
        time := transmute(i64)time_bytes
        offset += size_of(i64)

        blob_count := u8(buf[offset])
        offset += size_of(u8)

        blobs := make([]Mime_Blob, int(blob_count))
        for b in 0 ..< int(blob_count) {
            mime_count := u8(buf[offset])
            offset += size_of(u8)
            mimes := make([]string, int(mime_count))
            for m in 0 ..< int(mime_count) {
                mime_len := u8(buf[offset])
                offset += size_of(mime_len)
                mimes[m] = strings.clone(string(buf[offset:][:int(mime_len)]))
                offset += int(mime_len)
            }

            data_len_bytes: [size_of(u32)]byte
            copy(data_len_bytes[:], buf[offset:][:size_of(u32)])
            data_len := transmute(u32)data_len_bytes
            offset += size_of(u32)
            data := slice.clone(buf[offset:][:int(data_len)])
            offset += int(data_len)

            blobs[b] = Mime_Blob {
                data  = data,
                mimes = mimes,
            }
        }

        regs[reg_id] = Reg_Entry {
            blobs     = blobs,
            timestamp = time,
        }
    }

    return count
}

