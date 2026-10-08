package libclipbender

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Semantic_Version :: struct {
    major: uint,
    minor: uint,
    patch: uint,
    pre:   string,
    build: string,
}
// `u8` because versions are serialized as a single byte in IPC protocol; widening is a breaking change to the protocol
// and state.
Monotonic_Version :: distinct u8

CLIPBENDER_VERSION :: Semantic_Version {
    major = 0,
    minor = 2,
    patch = 0,
    pre   = "alpha",
    build = #config(BUILD, ""),
}

// Version for IPC wire format protocol between client and daemon
PROTOCOL_VERSION :: Monotonic_Version(1)
// Version for state persistence serialization protocol
STATE_VERSION :: Monotonic_Version(1)

// Allocates, caller is responsible for freeing.
semantic_version_to_string :: proc(version: Semantic_Version, allocator := context.allocator) -> string {
    buf: [128]byte
    length := 0
    length += len(fmt.bprintf(buf[length:], "%d.%d.%d", version.major, version.minor, version.patch))
    if version.pre != "" {length += len(fmt.bprintf(buf[length:], "-%s", version.pre))}
    if version.build != "" {length += len(fmt.bprintf(buf[length:], "+%s", version.build))}
    return strings.clone_from_bytes(buf[:length], allocator)
}

version_string :: proc() -> string {
    return semantic_version_to_string(CLIPBENDER_VERSION, context.temp_allocator)
}

print_version :: proc() {
    fmt.printfln("clipbender %s", version_string())
}

// Max data allowed to pass over IPC in one message (TODO: until we implement passing memfd via `SCM_RIGHTS` instead of
// copying bytes).
MAX_MSG_SIZE :: 128 * 1024 // 128 KiB

// One unique data blob plus every mime name it answers to. A register holds several of these when an application
// offers the same selection in more than one format.
Data_Repr :: struct {
    data:  []byte,
    mimes: []string,
}

// One register: a `Data_Repr` per representation the selection was offered in, plus a timestamp.
Reg_Entry :: struct {
    reprs:     []Data_Repr,
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
        return "selection"
    } else if id == SELECTION_PRIMARY {
        return "@selection"
    }
    return "unknown reg id"
}

// `CLIPBOARD` is your typical copy/paste, `PRIMARY` is Linux's highlight + middle-click to paste feature.
Selection_Type :: enum u8 {
    CLIPBOARD,
    PRIMARY,
}

Session_Type :: enum u8 {
    NONE,
    WAYLAND,
    X11,
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
        return .NONE
    }
}

// Protocol/IPC

// A register can hold anything the user copied, including password-manager contents, so every path clipbender
// creates is owner-only.
CLIPBENDER_DIR_PERMS :: os.Permissions{.Read_User, .Write_User, .Execute_User} // 0700
CLIPBENDER_FILE_PERMS :: os.Permissions{.Read_User, .Write_User} // 0600

// Create `dir` and any missing parents, owner-only.
make_private_directory :: proc(dir: string) {
    os.make_directory_all(dir, CLIPBENDER_DIR_PERMS)
    // chmod the directory in case it already existed with different perms
    if err := os.chmod(dir, CLIPBENDER_DIR_PERMS); err != nil {
        log.warnf("Failed to restrict permissions on %s (do we own it?): %v", dir, err)
    }
}

// Return `<dir>/<subdir>/<filename>`, creating the directory owner-only.
// Caller is responsible for freeing returned string.
private_dir_path :: proc(dir: string, subdir: string, filename: string) -> string {
    full_dir := fmt.tprintf("%s/%s", dir, subdir)
    make_private_directory(full_dir)
    return fmt.aprintf("%s/%s", full_dir, filename)
}

// Return `<dir>/<subdir>`, creating it owner-only.
//
// Caller is responsible for freeing the returned string.
private_dir :: proc(dir: string, subdir: string) -> string {
    full_dir := fmt.aprintf("%s/%s", dir, subdir)
    make_private_directory(full_dir)
    return full_dir
}

// Return `<$env_var>/<subdir>/<filename>`, with `ok` false if the env var does not resolve to a directory. Unlike
// `env_path_with_fallback` there is deliberately no fallback.
//
// Caller is responsible for freeing the returned string but only when `ok`.
env_path_or_none :: proc(env_var: string, subdir: string, filename: string) -> (path: string, ok: bool) {
    env_var_dir := os.get_env(env_var, context.allocator)
    defer delete(env_var_dir)

    if len(env_var_dir) == 0 || !os.is_directory(env_var_dir) {
        if len(env_var_dir) > 0 {
            log.warnf("%s env var is not a directory, you should probably fix this (got %s)", env_var, env_var_dir)
        }
        return "", false
    }

    return private_dir_path(env_var_dir, subdir, filename), true
}

// Return `<$env_var>/<subdir>` as a directory, with `ok` false if the env var does not resolve to one. The directory
// counterpart of `env_path_or_none`, for callers that need to build several paths under it.
//
// Caller is responsible for freeing the returned string but only when `ok`.
env_dir_or_none :: proc(env_var: string, subdir: string) -> (path: string, ok: bool) {
    env_var_dir := os.get_env(env_var, context.allocator)
    defer delete(env_var_dir)

    if len(env_var_dir) == 0 || !os.is_directory(env_var_dir) {
        if len(env_var_dir) > 0 {
            log.warnf("%s env var is not a directory, you should probably fix this (got %s)", env_var, env_var_dir)
        }
        return "", false
    }

    return private_dir(env_var_dir, subdir), true
}

// Return a path built from an env var directory, using a fallback if the env var doesn't exist or isn't a directory.
// Fallback to using `fallback_dir` if the `env_var` doesn't exist or isn't a directory.
//
// Caller is responsible for freeing returned string.
env_path_with_fallback :: proc(env_var: string, subdir: string, filename: string, fallback_dir: string) -> string {
    env_var_dir := os.get_env(env_var, context.allocator)
    defer delete(env_var_dir)

    dir := env_var_dir
    if len(env_var_dir) == 0 || !os.is_directory(env_var_dir) {
        if len(env_var_dir) > 0 {
            log.warnf("%s env var is not a directory, you should probably fix this (got %s)", env_var, env_var_dir)
        }
        // Use fallback if we can't build a path from the env var
        dir = fallback_dir
    }

    return private_dir_path(dir, subdir, filename)
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

// Kinds of messages (commands) passed from client to daemon. Every message is `[1b PROTOCOL_VERSION][body]`; the bodies
// below are what follows the prefix. IPC wire format:
//
// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
// SET (INLINE):   `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime type len][M mime type][N data]`
// GET:            `[1b Message_Type][1b group count]` then per group:
//                 `[8b Cmd_Get_Filter][1b mime policy tag]` plus `[1b mime type len][M mime type]` for EXACT only
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

// Every command is prefixed with `PROTOCOL_VERSION`. The bytes after it are the command *body*, whose layout is what
// the `[1b Message_Type]...` comments above describe, so body offsets stay independent of the prefix.
CMD_VERSION_SIZE :: size_of(Monotonic_Version)

// Exact wire sizes for the fixed-length commands, prefix included, so callers size their buffers from the format rather
// than counting bytes by hand. Each mirrors what the matching `marshal_*` returns.
//
// SET (INLINE) and GET have no constant: both carry variable-length payloads and use `MAX_MSG_SIZE` buffers.
CMD_SET_REG_SIZE ::
    CMD_VERSION_SIZE + size_of(Command_Type) + (2 * size_of(Reg_Id)) + size_of(Set_Mode) + size_of(Source_Kind)
CMD_CLEAR_SIZE :: CMD_VERSION_SIZE + size_of(Command_Type) + size_of(Reg_Id)
CMD_SHUTDOWN_SIZE :: CMD_VERSION_SIZE + size_of(Command_Type)
// Bytes every SET body carries before its source-specific tail: REGISTER adds a source Reg_Id, INLINE adds a mime
// length. Body-relative, unlike the sizes above, because its only use is indexing into a body slice. Both tails are at
// least one byte, so `CMD_SET_HEADER_SIZE + 1` is the shortest legal SET body.
CMD_SET_HEADER_SIZE :: size_of(Command_Type) + size_of(Reg_Id) + size_of(Set_Mode) + size_of(Source_Kind)

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
// whether they want the daemon to handle picking the best mime that the repr provides or if the client wants to pass
// the exact mime they want to receive.
Mime_Policy :: union #no_nil {
    Ranked_Policy, // daemon picks by the named ordering
    Exact_Mime, // client names exactly what mime it wants
}
Ranked_Policy :: enum u8 {
    // For output a terminal or pipe consumes: {text, structured, URIs, markup}. A filter *plus* a ranking -- an image is
    // not a worse answer here but a wrong one that corrupts the output -- so it can legitimately match nothing.
    TEXTUAL,
    // For a visual preview: {images, media, URIs, text, structured, markup}. No boundary, degrades all the way to
    // markup, so it is effectively never empty.
    VISUAL,
}
Exact_Mime :: distinct string // specify exactly what mime to receive
// Wire tag for the `Mime_Policy` union. `Ranked_Policy` variants encode as their own ordinals (TEXTUAL=0, VISUAL=1) and
// `Exact_Mime` takes the next value after them, derived so that adding a ranked variant shifts the sentinel
// automatically instead of silently colliding with it.
//
// This is the value one past the last ranked variant, not a count of wire tags. Deriving it from `len` only works while
// `Ranked_Policy` stays contiguous from zero -- assigning explicit values would leave `len` unchanged while moving the
// variants, so `Ranked_Policy(tag)` would decode garbage. The assert pins that down.
EXACT_MIME_TAG :: u8(len(Ranked_Policy))
// ensure the tag for `Exact_Mime` is one more than the last in `Ranked_Policy`
#assert(u8(max(Ranked_Policy)) + 1 == EXACT_MIME_TAG)

// Max byte length of a mime string on the wire. Real mimes are typically far shorter ("text/plain;charset=utf-8" is 24)
MAX_MIME_LEN :: int(max(u8))
// SET INLINE prefixes its mime list with a single-byte count, so that is the ceiling on names per representation.
// `int`-typed to avoid a cast at every `len()` comparison, matching `MAX_MIME_LEN`.
MAX_MIME_COUNT :: int(max(u8))

// Ceiling on a single read from a source application's pipe; huge limit just to prevent fatal errors like OOM.
MAX_READ_SIZE :: 512 * 1024 * 1024 // 512 MiB

// Linux's default pipe capacity, used for reading in Wayland data offers from pipe.
PIPE_READ_SIZE :: 64 * 1024 // 64 KiB

// Mime categories, ordered within each. Every list is an *allowlist*.
// `@(rodata)` rather than `::` because `::` constants are not addressable and so cannot be sliced.
@(rodata)
TEXT_MIMES := [?]string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"}

@(rodata)
STRUCTURED_MIMES := [?]string {
    "application/json",
    "application/xml",
    "text/xml",
    "text/csv",
    "text/tab-separated-values",
}

@(rodata)
URI_MIMES := [?]string{"text/uri-list"}

@(rodata)
MARKUP_MIMES := [?]string{"text/html", "text/markdown", "text/rtf", "application/rtf"}

@(rodata)
MEDIA_MIMES := [?]string {
    "audio/flac",
    "audio/wav",
    "audio/ogg",
    "audio/mpeg",
    "video/mp4",
    "video/x-matroska",
    "video/x-msvideo",
}

@(rodata)
IMAGE_MIMES := [?]string {
    "image/png",
    "image/webp",
    "image/jpeg",
    "image/avif",
    "image/heic",
    "image/jxl",
    "image/tiff",
    "image/bmp",
    "image/gif",
    "image/qoi",
    "image/svg+xml",
}

// To reduce bytes passed over IPC, group registers together that share one mime preference. Grouping by *preference*
// rather than by register is what keeps ranges cheap: `+a:z=text/plain` is one group (22 bytes) because the mime string
// appears once and the registers collapse into the bitmask; keying by register would repeat the mime 26 times.
//
// The mime lives inside `policy` (as `Exact_Mime`) rather than in a separate field, so "ranked but with a mime" and
// "exact but with no mime" are both unrepresentable.
Cmd_Get_Group :: struct {
    filter: Cmd_Get_Filter,
    policy: Mime_Policy,
}

// A GET request cannot exceed MAX_MSG_SIZE by construction: every group must claim at least one register bit, so there
// are at most MAX_REGS groups, and each mime is capped at 255 bytes by its u8 length field. Worst case is 16962 bytes,
// ~26% of the buffer. This assert keeps that proof honest if the encoding ever grows.
#assert(
    CMD_VERSION_SIZE +
        size_of(Command_Type) +
        size_of(u8) +
        MAX_REGS * (size_of(Cmd_Get_Filter) + size_of(EXACT_MIME_TAG) + size_of(u8) + 255) <=
    MAX_MSG_SIZE,
)

// Pick which stored mime repr a GET group gets, as an index into `entry.reprs`. An `Exact_Mime` miss never falls back.
resolve_repr :: proc(entry: ^Reg_Entry, policy: Mime_Policy) -> (int, bool) {
    switch p in policy {
    case Exact_Mime:
        return repr_with_mime(entry, string(p))
    case Ranked_Policy:
        switch p {
        case .TEXTUAL:
            return first_match(entry, {TEXT_MIMES[:], STRUCTURED_MIMES[:], URI_MIMES[:], MARKUP_MIMES[:]})
        case .VISUAL:
            return first_match(
                entry,
                {IMAGE_MIMES[:], MEDIA_MIMES[:], URI_MIMES[:], TEXT_MIMES[:], STRUCTURED_MIMES[:], MARKUP_MIMES[:]},
            )
        }
    }
    return -1, false
}

// Walk `groups` in order, and each group's mimes in order, returning the first repr that offers one.
first_match :: proc(entry: ^Reg_Entry, groups: [][]string) -> (int, bool) {
    for group in groups {
        for mime in group {
            if i, ok := repr_with_mime(entry, mime); ok {return i, true}
        }
    }
    return -1, false
}

// Index of the first repr offering `mime`. Blobs carry several names for one byte stream, so this searches the whole
// name set. Ties resolve to the lowest index, though should not really be seen in practice since duplicate names across
// reprs would mean an app claimed the same mime for two different byte streams.
repr_with_mime :: proc(entry: ^Reg_Entry, mime: string) -> (int, bool) {
    for repr, i in entry.reprs {
        for m in repr.mimes {
            if m == mime {return i, true}
        }
    }
    return -1, false
}

// Response status from daemon. IPC wire format:
//
// OK:    `[1 byte Response_Status]`
// ERROR: `[1 byte Response_Status][N bytes error message]`
// REGISTERS:  `[1 byte Response_Status][1 byte u8 count][count * entry]`
//
// where each entry in REGISTERS is:
//
//     [1b Reg_Id][8b i64 timestamp]
//     [1b u8 repr count]
//     per repr:
//         [1b u8 mime count][[1b u8 mime len][mime len bytes]...]  // these names all resolve to one payload
//         [8b u64 size]                                            // size of this repr, sent or not
//         [1b Repr_Meta_Tag][1b u8 meta len][meta len bytes]       // NONE carries no payload
//     [1b u8 selected repr index]                                  // RESP_SELECTED_NONE when nothing matched
//     [selected repr's size bytes]                                 // length read from the selected descriptor
//
// Every repr is described, but only one carries bytes. A client showing a register whose image repr was not sent still
// needs its size and dimensions, and cannot derive them without the payload. It also lets a client that later wants a
// different mime check whether it already holds that payload e.g. names grouped under one repr share bytes, so no
// second request is needed.
Resp_Status :: enum u8 {
    OK,
    ERROR,
    REGISTERS,
}

// Pixel dimensions for images, read from a repr's own header. `u32` because every format that stores them fixed-width
// uses 32 bits or less.
Image_Dims :: struct {
    width:  u32,
    height: u32,
}

// Metadata about a repr that a client cannot derive on its own, because the repr's bytes may not have been sent.
//
// These meta tags are for info about the repr the user may want to see without the client having to fetch the entire
// payload.
Repr_Meta :: union {
    Image_Dims,
}

Repr_Meta_Tag :: enum u8 {
    NONE,
    IMAGE_DIMS,
}

// A single representation in a REGISTERS response.
Resp_Repr :: struct {
    mimes: []string,
    size:  u64,
    meta:  Repr_Meta,
}

// We use an index value to specify which repr in the list of reprs the associated data blob bytes correlate with, if
// any. If no data blob bytes were sent (no valid mime for the preference existed for the register), then we use this
// sentinel to denote it.
RESP_SELECTED_NONE :: 0xFF

// A single register in a REGISTERS response.
//
// `selected` is the index in `reprs` that the bytes in `data` belong to, or is `RESP_SELECTED_NONE` if no mime was
// found to be valid for the preference.
Resp_Reg :: struct {
    reprs:     []Resp_Repr,
    selected:  int,
    data:      []byte,
    timestamp: i64,
}

// True for a Reg_Id slot the response did not mention. A register that was returned always describes at least one repr.
resp_reg_is_empty :: proc(reg: Resp_Reg) -> bool {
    return len(reg.reprs) == 0
}

// The selected repr, or nil when the preference matched nothing.
resp_reg_selected :: proc(reg: Resp_Reg) -> ^Resp_Repr {
    if reg.selected < 0 || reg.selected >= len(reg.reprs) {return nil}
    return &reg.reprs[reg.selected]
}

// Free every repr's mime names, the reprs slice, and the data, then zero the entry.
free_resp_reg :: proc(reg: ^Resp_Reg) {
    for repr in reg.reprs {
        for mime in repr.mimes {
            delete(mime)
        }
        delete(repr.mimes)
    }
    delete(reg.reprs)
    zero_and_delete(reg.data)
    reg^ = {}
}

// Dimensions from a repr's header bytes, or `ok = false` when the format is unrecognised or the header is too short to
// hold them. Short is normal, not exceptional: the magic table matches a 4-byte prefix, so a register can legitimately be
// labelled `image/png` while holding fewer bytes than an IHDR chunk needs.
image_dimensions :: proc(data: []byte, mime: string) -> (dims: Image_Dims, ok: bool) {
    // `endian.get_*` bounds-check the slice it is handed, but slicing `data[off:]` would panic first on a short buffer.
    read_u32 :: proc(data: []byte, offset: int, order: endian.Byte_Order) -> (u32, bool) {
        if offset + size_of(u32) > len(data) {return 0, false}
        return endian.get_u32(data[offset:], order)
    }
    read_u16 :: proc(data: []byte, offset: int, order: endian.Byte_Order) -> (u16, bool) {
        if offset + size_of(u16) > len(data) {return 0, false}
        return endian.get_u16(data[offset:], order)
    }

    switch mime {
    case "image/png":
        // IHDR is the first chunk and its data begins at offset 16, big-endian.
        w, w_ok := read_u32(data, 16, .Big)
        h, h_ok := read_u32(data, 20, .Big)
        if !w_ok || !h_ok {return {}, false}
        return {w, h}, true
    case "image/gif":
        w, w_ok := read_u16(data, 6, .Little)
        h, h_ok := read_u16(data, 8, .Little)
        if !w_ok || !h_ok {return {}, false}
        return {u32(w), u32(h)}, true
    case "image/bmp":
        // Signed, and a negative height legitimately means the rows are stored top-down, so take the magnitude.
        w, w_ok := read_u32(data, 18, .Little)
        h, h_ok := read_u32(data, 22, .Little)
        if !w_ok || !h_ok {return {}, false}
        return {u32(abs(i32(w))), u32(abs(i32(h)))}, true
    case "image/qoi":
        // 4b "qoif", then width and height as big-endian u32: a 14-byte header with no chunk structure at all.
        w, w_ok := read_u32(data, 4, .Big)
        h, h_ok := read_u32(data, 8, .Big)
        if !w_ok || !h_ok {return {}, false}
        return {w, h}, true
    case "image/jpeg":
        return jpeg_dimensions(data)
    case "image/webp":
        return webp_dimensions(data)
    }
    return {}, false
}

// JPEG keeps dimensions in a Start-Of-Frame segment, reached by walking the segment chain from after the SOI marker.
//
// Note height precedes width in SOF, the reverse of every other format here.
jpeg_dimensions :: proc(data: []byte) -> (dims: Image_Dims, ok: bool) {
    if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {return {}, false}

    offset := 2
    for offset + 4 <= len(data) {
        if data[offset] != 0xFF {return {}, false}     // lost segment sync; refuse rather than hunt
        marker := data[offset + 1]
        if marker == 0xFF {
            offset += 1 // fill byte: any number of 0xFF may pad before a marker
            continue
        }
        // Standalone markers carry no length field: TEM, the restart markers, and a repeated SOI/EOI.
        if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
            offset += 2
            continue
        }
        seg_len, len_ok := endian.get_u16(data[offset + 2:], .Big)
        // A length under 2 cannot even cover its own field, and would stall the walk.
        if !len_ok || seg_len < 2 {return {}, false}

        if is_jpeg_sof(marker) {
            // SOF payload: [1b precision][2b height][2b width][1b component count]
            if offset + 9 > len(data) {return {}, false}
            h, h_ok := endian.get_u16(data[offset + 5:], .Big)
            w, w_ok := endian.get_u16(data[offset + 7:], .Big)
            if !h_ok || !w_ok {return {}, false}
            return {u32(w), u32(h)}, true
        }
        offset += 2 + int(seg_len)
    }
    return {}, false
}

// Frame headers are SOF0-3, SOF5-7, SOF9-11 and SOF13-15.
is_jpeg_sof :: proc(marker: byte) -> bool {
    switch marker {
    case 0xC0 ..= 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
        return true
    }
    return false
}

// WebP is a RIFF container e.g. `RIFF[4b size]WEBP` then chunks. The first chunk's tag says which of three codecs wrote
// it.
webp_dimensions :: proc(data: []byte) -> (dims: Image_Dims, ok: bool) {
    // 4b "RIFF" + 4b size + 4b "WEBP" + 4b chunk tag + 4b chunk size before any payload
    WEBP_BODY :: 20
    if len(data) < WEBP_BODY {return {}, false}
    if string(data[0:4]) != "RIFF" || string(data[8:12]) != "WEBP" {return {}, false}
    tag := string(data[12:16])
    body := data[WEBP_BODY:]

    switch tag {
    case "VP8X":
        // Extended
        // [4b flags][3b canvas width-1 LE][3b canvas height-1 LE]
        if len(body) < 10 {return {}, false}
        w := u32(body[4]) | u32(body[5]) << 8 | u32(body[6]) << 16
        h := u32(body[7]) | u32(body[8]) << 8 | u32(body[9]) << 16
        return {w + 1, h + 1}, true
    case "VP8 ":
        // Lossy
        // 3b frame tag, 3b start code, then width and height as 14-bit values in little-endian u16s, the top two bits
        // of each being a scale factor rather than part of the dimension.
        if len(body) < 10 {return {}, false}
        if body[3] != 0x9D || body[4] != 0x01 || body[5] != 0x2A {return {}, false}
        w, w_ok := endian.get_u16(body[6:], .Little)
        h, h_ok := endian.get_u16(body[8:], .Little)
        if !w_ok || !h_ok {return {}, false}
        return {u32(w & 0x3FFF), u32(h & 0x3FFF)}, true
    case "VP8L":
        // Lossless
        // 1b signature, then 14 bits of width-1 followed by 14 bits of height-1, packed little-endian.
        if len(body) < 5 || body[0] != 0x2F {return {}, false}
        bits, bits_ok := endian.get_u32(body[1:], .Little)
        if !bits_ok {return {}, false}
        return {(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1}, true
    }
    return {}, false
}

// Metadata for a repr, derived from its bytes and names. `NONE` whenever nothing is known, which is the common case.
repr_meta :: proc(repr: Data_Repr) -> Repr_Meta {
    for mime in repr.mimes {
        if dims, ok := image_dimensions(repr.data, mime); ok {return dims}
    }
    return nil
}

// Magic bytes and their respective mime types
//
// A byte signature and every mime the matched content legitimately claims. Plural because text-based formats can be
// more than one thing e.g. an RTF document is `application/rtf` and `text/plain`, while binary formats carry a single
// name. Loosely ordered most-specific-first.
Magic :: struct {
    bytes: []byte,
    mimes: []string,
}
MAGIC_PNG :: Magic{{'\x89', 'P', 'N', 'G'}, {"image/png"}}
MAGIC_JPEG :: Magic{{'\xFF', '\xD8'}, {"image/jpeg"}}
MAGIC_BMP :: Magic{{'B', 'M'}, {"image/bmp"}}
MAGIC_GIF :: Magic{{'G', 'I', 'F', '8'}, {"image/gif"}}
MAGIC_QOI :: Magic{{'q', 'o', 'i', 'f'}, {"image/qoi"}}
MAGIC_TIFF_LE :: Magic{{'I', 'I', '*', '\x00'}, {"image/tiff"}}
MAGIC_TIFF_BE :: Magic{{'M', 'M', '\x00', '*'}, {"image/tiff"}}
MAGIC_RTF :: Magic{{'{', '\\', 'r', 't', 'f', '1'}, {"application/rtf", "text/plain"}}
MAGIC_PDF :: Magic{{'%', 'P', 'D', 'F'}, {"application/pdf"}}
MAGIC_ZIP :: Magic{{'P', 'K', '\x03', '\x04'}, {"application/zip"}}
MAGIC_ZIP_EMPTY :: Magic{{'P', 'K', '\x05', '\x06'}, {"application/zip"}}
MAGIC_ZIP_SPANNED :: Magic{{'P', 'K', '\x07', '\x08'}, {"application/zip"}}
MAGIC_GZIP :: Magic{{'\x1F', '\x8B'}, {"application/gzip"}}
MAGIC_ZSTD :: Magic{{'(', '\xB5', '/', '\xFD'}, {"application/zstd"}}
MAGIC_XZ :: Magic{{'\xFD', '7', 'z', 'X', 'Z', '\x00'}, {"application/x-xz"}}
MAGIC_BZIP2 :: Magic{{'B', 'Z', 'h'}, {"application/x-bzip2"}}
MAGIC_7ZIP :: Magic{{'7', 'z', '\xBC', '\xAF', '\'', '\x1C'}, {"application/x-7z-compressed"}}
MAGIC_RAR :: Magic{{'R', 'a', 'r', '!', '\x1A', '\x07'}, {"application/vnd.rar"}}
MAGIC_POSTSCRIPT :: Magic{{'%', '!', 'P', 'S'}, {"application/postscript"}}
MAGIC_JPEG_XL_RAW :: Magic{{'\xFF', '\x0A'}, {"image/jxl"}}
MAGIC_JPEG_XL_BOX :: Magic {
    {'\x00', '\x00', '\x00', '\x0C', 'J', 'X', 'L', '\x20', '\x0D', '\x0A', '\x87', '\x0A'},
    {"image/jxl"},
}
MAGIC_OGG :: Magic{{'O', 'g', 'g', 'S'}, {"audio/ogg"}}
MAGIC_FLAC :: Magic{{'f', 'L', 'a', 'C'}, {"audio/flac"}}
MAGIC_MP3 :: Magic{{'I', 'D', '3'}, {"audio/mpeg"}}
MAGIC_MKV_WEBM :: Magic{{'\x1A', 'E', '\xDF', '\xA3'}, {"video/x-matroska"}}
@(rodata)
MAGICS := [?]Magic {
    MAGIC_PNG,
    MAGIC_JPEG,
    MAGIC_BMP,
    MAGIC_GIF,
    MAGIC_QOI,
    MAGIC_TIFF_LE,
    MAGIC_TIFF_BE,
    MAGIC_RTF,
    MAGIC_PDF,
    MAGIC_ZIP,
    MAGIC_ZIP_EMPTY,
    MAGIC_ZIP_SPANNED,
    MAGIC_GZIP,
    MAGIC_ZSTD,
    MAGIC_XZ,
    MAGIC_BZIP2,
    MAGIC_7ZIP,
    MAGIC_RAR,
    MAGIC_POSTSCRIPT,
    MAGIC_JPEG_XL_RAW,
    MAGIC_JPEG_XL_BOX,
    MAGIC_OGG,
    MAGIC_FLAC,
    MAGIC_MP3,
    MAGIC_MKV_WEBM,
}

// For 2-part container magics that use some sort of first magic followed by a second magic
Container_Magic :: struct {
    marker_offset: int,
    marker_bytes:  []byte,
    magic_offset:  int,
    magic_size:    int,
    magics:        []Magic,
}

// RIFF magics
MAGIC_WEBP :: Magic{{'W', 'E', 'B', 'P'}, {"image/webp"}}
MAGIC_WAV :: Magic{{'W', 'A', 'V', 'E'}, {"audio/wav"}}
MAGIC_AVI :: Magic{{'A', 'V', 'I', '\x20'}, {"video/x-msvideo"}}
@(rodata)
RIFF_CONTAINER := Container_Magic {
    marker_offset = 0,
    marker_bytes  = []byte{'R', 'I', 'F', 'F'},
    magic_offset  = 8,
    magic_size    = 4,
    magics        = []Magic{MAGIC_WEBP, MAGIC_WAV, MAGIC_AVI},
}

// ftyp magics
MAGIC_AVIF :: Magic{{'a', 'v', 'i', 'f'}, {"image/avif"}}
MAGIC_HEIC :: Magic{{'h', 'e', 'i', 'c'}, {"image/heic"}}
MAGIC_MP4 :: Magic{{'i', 's', 'o', 'm'}, {"video/mp4"}}
MAGIC_MP42 :: Magic{{'m', 'p', '4', '2'}, {"video/mp4"}}
@(rodata)
FTYP_CONTAINER := Container_Magic {
    marker_offset = 4,
    marker_bytes  = []byte{'f', 't', 'y', 'p'},
    magic_offset  = 8,
    magic_size    = 4,
    magics        = []Magic{MAGIC_AVIF, MAGIC_HEIC, MAGIC_MP4, MAGIC_MP42},
}

// Fallback results, as `@(rodata)` arrays rather than `::` slice constants: a `::` compound literal is backed by the
// caller's stack frame, so returning a slice of one would dangle (Odin rejects it outright).
@(rodata)
PLAINTEXT_RESULT := [?]string{"text/plain;charset=utf-8", "text/plain"}
@(rodata)
BINARY_RESULT := [?]string{"application/octet-stream"}

// Mimes resolved from magic bytes in binary header or fallback to text if UTF-8 or octet-stream otherwise, for input
// arriving without one (stdin / inline `SET`). Most specific first.
//
// **Borrowed, not owned:** every string is a `.rodata` literal and the slices point into static storage, so this
// allocates nothing and the result outlives any caller. Callers that *store* the mimes must clone each one.
resolve_mimes :: proc(data: []byte) -> []string {
    for magic in MAGICS {
        if slice.has_prefix(data, magic.bytes) {
            return magic.mimes
        }
    }
    // RIFF and ISO-BMFF put a length field between their two markers, so neither is a contiguous prefix.
    if mimes, ok := container_mimes(data, RIFF_CONTAINER); ok {return mimes}
    if mimes, ok := container_mimes(data, FTYP_CONTAINER); ok {return mimes}

    // Last, so ASCII-valid formats (RTF, PostScript) claim their specific mime before falling back to text.
    if utf8.valid_string(string(data)) {
        if mimes, found_mime := sniff_text(string(data)); found_mime {return mimes}
        return PLAINTEXT_RESULT[:]
    }

    // Fallback to octet-stream if absolutely nothing else applies.
    return BINARY_RESULT[:]
}

// Text formats have no byte signature to match, so they are sniffed from their opening markup instead -- and only after
// `utf8.valid_string` has confirmed the payload is text at all.
@(rodata)
SVG_RESULT := [?]string{"image/svg+xml", "application/xml", "text/plain;charset=utf-8", "text/plain"}
@(rodata)
XML_RESULT := [?]string{"application/xml", "text/plain;charset=utf-8", "text/plain"}
@(rodata)
HTML_RESULT := [?]string{"text/html", "text/plain;charset=utf-8", "text/plain"}
@(rodata)
JSON_RESULT := [?]string{"application/json", "text/plain;charset=utf-8", "text/plain"}

// How far in to look for mime-indicating text e.g. `<svg`: past a BOM, an `<?xml ...?>` declaration, a DOCTYPE, etc.
SNIFF_WINDOW :: 512

@(rodata)
XML_MARKER := "<?xml"
@(rodata)
SVG_MARKER := "<svg"
@(rodata)
HTML_MARKERS := [?]string{"<!doctype html", "<html", "<head", "<body"}

// Every mime a text payload claims, or `ok = false` to fall through to plain text.
//
// Order is deliberate: SVG before XML (an SVG opens with `<?xml`, so testing XML first would classify every SVG as
// plain XML), and JSON last because it is the only one needing a real parse.
//
// Markdown is absent on purpose since all plain text is valid markdown, so no signature exists and `mime=text/markdown`
// is the only honest way to say it. CSV/TSV are absent because delimiter-consistency heuristics false-positive on any
// prose containing commas.
sniff_text :: proc(text: string) -> (mimes: []string, found_mime: bool) {
    // A BOM is legal in front of any of these and would defeat a bare prefix test.
    trimmed := text
    trimmed = strings.trim_prefix(trimmed, "\xEF\xBB\xBF")
    trimmed = strings.trim_left_space(trimmed)

    head := trimmed if len(trimmed) < SNIFF_WINDOW else trimmed[:SNIFF_WINDOW]
    lower_head := strings.to_lower(head, context.temp_allocator)

    // SVG: either the root element directly, or an XML declaration with `<svg` somewhere in the window after it.
    if strings.has_prefix(lower_head, SVG_MARKER) ||
       (strings.has_prefix(lower_head, XML_MARKER) && strings.contains(lower_head, SVG_MARKER)) {
        return SVG_RESULT[:], true
    }

    for marker in HTML_MARKERS {
        if strings.has_prefix(lower_head, marker) {return HTML_RESULT[:], true}
    }

    if strings.has_prefix(lower_head, XML_MARKER) {return XML_RESULT[:], true}

    // Only bother checking json if first char is `{` or `[` since we have to validate the entire text.
    if len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[') {
        if json.is_valid(transmute([]byte)trimmed) {return JSON_RESULT[:], true}
    }

    return nil, false
}

container_mimes :: proc(data: []byte, container: Container_Magic) -> (mimes: []string, ok: bool) {
    needed_bytes := max(
        container.marker_offset + len(container.marker_bytes),
        container.magic_offset + container.magic_size,
    )
    if len(data) < needed_bytes {return nil, false}
    if !slice.equal(
        data[container.marker_offset:][:len(container.marker_bytes)],
        container.marker_bytes,
    ) {return nil, false}

    magic := data[container.magic_offset:][:container.magic_size]
    for candidate in container.magics {
        if slice.equal(magic, candidate.bytes) {return candidate.mimes, true}
    }
    return nil, false
}

// Heap-allocate a one-representation slice, taking ownership of `data` and `mime` (both must be heap-allocated).
//
// The slice has to be heap-allocated: a composite literal would be backed by a temporary in the caller's frame, so the
// store would hold a dangling pointer once the caller returned. Used by the paths that genuinely produce one
// representation -- SET inline, and register-to-register copies; M4's capture path builds multi-repr slices directly.
data_repr_single :: proc(data: []byte, mime: string) -> []Data_Repr {
    mimes := make([]string, 1)
    mimes[0] = mime

    reprs := make([]Data_Repr, 1)
    reprs[0] = Data_Repr {
        data  = data,
        mimes = mimes,
    }
    return reprs
}

// Clones a `Data_Repr`, caller is responsible for freeing returned value.
clone_data_repr :: proc(repr: Data_Repr) -> Data_Repr {
    cloned_data := slice.clone(repr.data)
    cloned_mimes := make([]string, len(repr.mimes))
    for i in 0 ..< len(repr.mimes) {
        cloned_mimes[i] = strings.clone(repr.mimes[i])
    }
    return Data_Repr{data = cloned_data, mimes = cloned_mimes}
}

// Clones a slice of `Data_Repr`s, caller is responsible for freeing returned value.
clone_data_reprs :: proc(reprs: []Data_Repr) -> []Data_Repr {
    cloned_reprs := make([]Data_Repr, len(reprs))
    for repr, i in reprs {
        cloned_reprs[i] = clone_data_repr(repr)
    }
    return cloned_reprs
}

// Safe on a nil or zero-length slice.
zero_and_delete_slice :: proc(
    array: $T/[]$E,
    allocator := context.allocator,
    loc := #caller_location,
) -> mem.Allocator_Error {
    mem.zero_explicit(raw_data(array), size_of(E) * len(array))
    return delete(array, allocator, loc)
}

// Zeroes the whole capacity rather than `len`: a caller that shrinks `len` after a partial fill would otherwise leave
// content in the tail.
zero_and_delete_dynamic :: proc(array: $T/[dynamic]$E, loc := #caller_location) -> mem.Allocator_Error {
    mem.zero_explicit(raw_data(array), size_of(E) * cap(array))
    return delete(array, loc)
}

// Free a repr and zero `data` before it is released, so freed clipboard contents are not left readable in the heap
// block until something else happens to reuse it. Safe on a nil or zero-length slice.
zero_and_delete :: proc {
    zero_and_delete_slice,
    zero_and_delete_dynamic,
}

// Only `data` is zeroed: the mimes are format names, not content.
free_data_repr :: proc(repr: Data_Repr) {
    zero_and_delete(repr.data)
    for mime in repr.mimes {
        delete(mime)
    }
    delete(repr.mimes)
}

// Free every repr in the slice plus the reprs slice itself.
free_data_reprs :: proc(reprs: []Data_Repr) {
    for repr in reprs {
        free_data_repr(repr)
    }
    delete(reprs)
}

// Free every repr in the entry plus the reprs slice itself, then zero the entry.
free_reg_entry :: proc(reg_entry: ^Reg_Entry) {
    free_data_reprs(reg_entry.reprs)
    reg_entry^ = {}
}

//// Encoding/decode to/from IPC wire format

// Client-side

// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
marshal_cmd_set_reg :: proc(dest: Reg_Id, source: Reg_Id, set_mode: Set_Mode, buf: []byte) -> int {
    // Version prefix
    buf[0] = byte(PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    // Header
    body[0] = byte(Command_Type.SET)
    body[1] = byte(dest)
    body[2] = byte(set_mode)
    body[3] = byte(Source_Kind.REGISTER)
    // Source register
    body[4] = byte(source)
    return CMD_SET_REG_SIZE
}

// SET (INLINE): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime count]`
//               then `[1b mime len][M mime]` per mime, then `[N data]`.
//
// Callers must reject mimes longer than MAX_MIME_LEN beforehand; `write_resp_mime` clamps rather than failing.
marshal_cmd_set_inline :: proc(dest: Reg_Id, set_mode: Set_Mode, mimes: []string, data: []byte, buf: []byte) -> int {
    // Version prefix
    buf[0] = byte(PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    // Header
    body[0] = byte(Command_Type.SET)
    body[1] = byte(dest)
    body[2] = byte(set_mode)
    body[3] = byte(Source_Kind.INLINE)
    // Mime count, then each name
    body[4] = u8(min(len(mimes), int(max(u8))))
    written := CMD_SET_HEADER_SIZE + size_of(u8)
    for mime in mimes[:int(body[4])] {
        written += write_resp_mime(body[written:], mime)
    }
    // Payload
    copy(body[written:][:len(data)], data)
    written += len(data)
    return CMD_VERSION_SIZE + written
}

// Bytes `marshal_cmd_set_inline` will write, so the caller can size its buffer exactly.
cmd_set_inline_size :: proc(mimes: []string, data: []byte) -> int {
    size := CMD_VERSION_SIZE + CMD_SET_HEADER_SIZE + size_of(u8) + len(data)
    for mime in mimes {
        size += size_of(u8) + min(len(mime), MAX_MIME_LEN)
    }
    return size
}

// GET: `[1b Message_Type][1b group_count]` then per group:
//      `[8b Cmd_Get_Filter][1b mime policy tag]` followed by `[1b mime len][M mime]` for EXACT only.
//
// The trailing mime is present only for EXACT, so a ranked group is 9 bytes and `get ++all` is 11.
// Callers must reject mimes longer than MAX_MIME_LEN before calling; this truncates rather than failing, matching
// marshal_cmd_set_inline.
marshal_cmd_get :: proc(groups: []Cmd_Get_Group, buf: []byte) -> int {
    // Version prefix
    buf[0] = byte(PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    // Header and group count
    body[0] = byte(Command_Type.GET)
    body[1] = u8(len(groups))
    written := size_of(Command_Type) + size_of(u8)

    // One group per iteration
    for group in groups {
        // Register bitmask
        filter_bytes := transmute([8]byte)group.filter
        copy(body[written:][:size_of(Cmd_Get_Filter)], filter_bytes[:])
        written += size_of(Cmd_Get_Filter)

        // Mime policy: a tag alone when ranked, a tag plus the name when exact
        switch policy in group.policy {
        case Ranked_Policy:
            body[written] = u8(policy)
            written += size_of(EXACT_MIME_TAG)
        case Exact_Mime:
            body[written] = EXACT_MIME_TAG
            written += size_of(EXACT_MIME_TAG)
            mime_len := u8(min(len(policy), MAX_MIME_LEN))
            body[written] = byte(mime_len)
            written += size_of(mime_len)
            copy(body[written:][:int(mime_len)], string(policy))
            written += int(mime_len)
        }
    }

    return CMD_VERSION_SIZE + written
}

// CLEAR: `[1b Message_Type][1b Reg_Id]`
marshal_cmd_clear :: proc(reg_id: Reg_Id, buf: []byte) -> int {
    // Version prefix
    buf[0] = byte(PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    // Header and target register
    body[0] = byte(Command_Type.CLEAR)
    body[1] = byte(reg_id)
    return CMD_CLEAR_SIZE
}

// SHUTDOWN: `[1b Message_Type]`
marshal_cmd_shutdown :: proc(buf: []byte) -> int {
    // Version prefix
    buf[0] = byte(PROTOCOL_VERSION)
    body := buf[CMD_VERSION_SIZE:]
    // Header only; SHUTDOWN carries no payload
    body[0] = byte(Command_Type.SHUTDOWN)
    return CMD_SHUTDOWN_SIZE
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

// REGISTERS: `[1 byte Response_Status][1 byte u8 count][count * entry]`
// buf starts after first Response_Status byte
//
// Scatters each packed wire entry into its Reg_Id slot in `regs`. Slots not present in the response are left zeroed.
//
// NOTE: caller is responsible for freeing all entries via `free_resp_reg`.
unmarshal_resp_registers :: proc(buf: []byte, regs: ^[MAX_REGS]Resp_Reg) -> (count: int, err: Maybe(string)) {
    regs^ = {}
    defer if err != nil {
        for &reg in regs {
            free_resp_reg(&reg)
        }
        regs^ = {}
        count = 0
    }

    if len(buf) == 0 {
        return 0, "REGISTERS response truncated: missing entry count"
    }
    // Entry count
    count = int(buf[0])
    if count > MAX_REGS {
        return 0, fmt.tprintf("REGISTERS response entry count %d exceeds %d", count, MAX_REGS)
    }

    offset := size_of(u8)
    // Iterate through registers in response
    for i in 0 ..< count {
        if offset + size_of(Reg_Id) + size_of(i64) > len(buf) {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d header", i)
        }

        // Register id
        reg_id := Reg_Id(buf[offset])
        if !reg_id_is_valid(reg_id) {
            // Guards the array index below: Reg_Id is a u8, so an invalid one would write past a [MAX_REGS] array.
            return 0, fmt.tprintf("REGISTERS response entry %d has invalid register id %d", i, u8(reg_id))
        }
        offset += size_of(Reg_Id)

        // Timestamp
        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], buf[offset:][:size_of(i64)])
        regs[reg_id].timestamp = transmute(i64)time_bytes
        offset += size_of(i64)

        // Repr count
        if offset + size_of(u8) > len(buf) {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d repr count", i)
        }
        repr_count := int(buf[offset])
        offset += size_of(u8)
        if repr_count == 0 {
            // A returned register always holds something; zero reprs would decode as an absent slot.
            return 0, fmt.tprintf("REGISTERS response entry %d has zero reprs", i)
        }

        // Commit before filling so the deferred cleanup can free a partially decoded entry.
        reprs := make([]Resp_Repr, repr_count)
        regs[reg_id].reprs = reprs
        // One descriptor per iteration
        for r in 0 ..< repr_count {
            // Mime count
            if offset + size_of(u8) > len(buf) {
                return 0, fmt.tprintf("REGISTERS response truncated: entry %d repr %d mime count", i, r)
            }
            mime_count := int(buf[offset])
            offset += size_of(u8)
            if mime_count == 0 {
                return 0, fmt.tprintf("REGISTERS response entry %d repr %d has zero mimes", i, r)
            }
            if mime_count > MAX_MIME_COUNT {
                return 0, fmt.tprintf("REGISTERS response entry %d repr %d names %d mimes", i, r, mime_count)
            }

            // Names sharing this repr's payload
            mimes := make([]string, mime_count)
            reprs[r].mimes = mimes
            for m in 0 ..< mime_count {
                mime, mime_err := read_resp_mime(buf, &offset)
                if mime_err != nil {
                    return 0, fmt.tprintf(
                        "REGISTERS response truncated: entry %d repr %d mime %d (%s)",
                        i,
                        r,
                        m,
                        mime_err.?,
                    )
                }
                if mime == "" {
                    return 0, fmt.tprintf("REGISTERS response entry %d repr %d mime %d is empty", i, r, m)
                }
                mimes[m] = mime
            }

            // Size, present whether or not these bytes were sent
            if offset + size_of(u64) > len(buf) {
                return 0, fmt.tprintf("REGISTERS response truncated: entry %d repr %d size", i, r)
            }
            size_bytes: [size_of(u64)]byte
            copy(size_bytes[:], buf[offset:][:size_of(u64)])
            reprs[r].size = transmute(u64)size_bytes
            offset += size_of(u64)

            // Optional metadata
            meta, meta_err := read_repr_meta(buf, &offset)
            if meta_err != nil {
                return 0, fmt.tprintf("REGISTERS response entry %d repr %d meta: %s", i, r, meta_err.?)
            }
            reprs[r].meta = meta
        }

        // Which repr's bytes follow, if any
        if offset + size_of(u8) > len(buf) {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d selected index", i)
        }
        selected := int(buf[offset])
        offset += size_of(u8)
        if selected == RESP_SELECTED_NONE {
            regs[reg_id].selected = RESP_SELECTED_NONE
            continue
        }
        if selected >= repr_count {
            return 0, fmt.tprintf("REGISTERS response entry %d selects repr %d of %d", i, selected, repr_count)
        }
        regs[reg_id].selected = selected

        // Length of the payload is the selected descriptor's size rather than a second copy of it on the wire.
        data_len := int(reprs[selected].size)
        if data_len < 0 || offset + data_len > len(buf) {
            return 0, fmt.tprintf(
                "REGISTERS response truncated: entry %d data needs %d bytes, %d remain",
                i,
                data_len,
                len(buf) - offset,
            )
        }
        // Skip the clone for an empty payload
        if data_len > 0 {
            regs[reg_id].data = slice.clone(buf[offset:][:data_len])
            offset += data_len
        }
    }

    return count, nil
}

// Read `[1b mime len][mime len bytes]` at `offset`, advancing it. Returns an owned clone; a length of 0 yields "".
read_resp_mime :: proc(buf: []byte, offset: ^int) -> (mime: string, err: Maybe(string)) {
    // Length
    if offset^ + size_of(u8) > len(buf) {
        return "", "missing length"
    }
    mime_len := int(buf[offset^])
    offset^ += size_of(u8)
    if offset^ + mime_len > len(buf) {
        return "", fmt.tprintf("needs %d bytes, %d remain", mime_len, len(buf) - offset^)
    }
    if mime_len == 0 {return "", nil}
    mime = strings.clone(string(buf[offset^:][:mime_len]))
    offset^ += mime_len
    return mime, nil
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

// REGISTERS: `[1 byte Response_Status][1 byte u8 count][count * entry]`
// `regs` is indexed by Reg_Id; only non-empty slots are packed onto the wire, each tagged with its Reg_Id. `policies` is
// indexed the same way and says which representation each register should contribute.
//
// Returns `ok = false` if a complete response does not fit in `buf`.
marshal_resp_registers :: proc(
    regs: [MAX_REGS]^Reg_Entry,
    policies: [MAX_REGS]Mime_Policy,
    buf: []byte,
) -> (
    written: int,
    ok: bool,
) {
    if len(buf) < size_of(Resp_Status) + size_of(u8) {return 0, false}

    // Status byte
    buf[0] = byte(Resp_Status.REGISTERS)
    // Reserve the count byte, fill it in after we know how many non-empty entries there are
    written = size_of(Resp_Status) + size_of(u8)
    count: u8 = 0

    // One non-empty register per iteration
    for entry_ptr, id in regs {
        if entry_ptr == nil {continue}

        // Which repr contributes its bytes. Every repr is still described.
        chosen, has_blob := resolve_repr(entry_ptr, policies[id])
        data: []byte
        if has_blob {data = entry_ptr.reprs[chosen].data}

        // Pre-size the descriptors, which are written all-or-nothing.
        size := size_of(Reg_Id) + size_of(i64) + size_of(u8)
        metas := make([]Repr_Meta, len(entry_ptr.reprs), context.temp_allocator)
        for repr, i in entry_ptr.reprs {
            metas[i] = repr_meta(repr)
            size += size_of(u8)
            for m in repr.mimes {
                size += size_of(u8) + min(len(m), MAX_MIME_LEN)
            }
            size += size_of(u64) + size_of(Repr_Meta_Tag) + size_of(u8) + repr_meta_size(metas[i])
        }
        size += size_of(u8) // selected index

        // When the payload will not fit, send the entry described but unselected rather than failing the whole response.
        if has_blob && written + size + len(data) > len(buf) {
            has_blob = false
            data = nil
        }
        // Not even the descriptors fit, so there is nothing honest left to send.
        if written + size > len(buf) {return 0, false}

        // Reg ID u8
        buf[written] = byte(id)
        written += size_of(Reg_Id)

        // Timestamp i64
        time_bytes := transmute([size_of(i64)]byte)entry_ptr.timestamp
        copy(buf[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        // Repr count u8, then a descriptor per repr
        buf[written] = u8(len(entry_ptr.reprs))
        written += size_of(u8)
        for repr, i in entry_ptr.reprs {
            // Every name resolving to this repr's payload, so a client can tell which names share bytes
            buf[written] = u8(len(repr.mimes))
            written += size_of(u8)
            for m in repr.mimes {
                written += write_resp_mime(buf[written:], m)
            }

            // Size u64, whether or not these bytes are being sent
            size_bytes := transmute([size_of(u64)]byte)u64(len(repr.data))
            copy(buf[written:][:size_of(u64)], size_bytes[:])
            written += size_of(u64)

            // Optional metadata
            written += write_repr_meta(buf[written:], metas[i])
        }

        // Which repr's bytes follow, then the bytes themselves. Length is the selected descriptor's size.
        buf[written] = u8(chosen) if has_blob else u8(RESP_SELECTED_NONE)
        written += size_of(u8)
        copy(buf[written:][:len(data)], data)
        written += len(data)

        count += 1
    }

    // Count
    buf[1] = byte(count)
    return written, true
}

// Payload bytes a `Repr_Meta` variant occupies on the wire, excluding its tag and length byte.
repr_meta_size :: proc(meta: Repr_Meta) -> int {
    switch _ in meta {
    case Image_Dims:
        return 2 * size_of(u32)
    }
    return 0
}

// Write `[1b Repr_Meta_Tag][1b u8 len][len bytes]`. The length is what lets a client skip a tag it does not know instead
// of losing its place in the stream.
write_repr_meta :: proc(buf: []byte, meta: Repr_Meta) -> (written: int) {
    switch m in meta {
    case Image_Dims:
        buf[0] = byte(Repr_Meta_Tag.IMAGE_DIMS)
        buf[1] = u8(repr_meta_size(meta))
        dims := transmute([2 * size_of(u32)]byte)m
        copy(buf[2:][:len(dims)], dims[:])
        return size_of(Repr_Meta_Tag) + size_of(u8) + len(dims)
    }
    buf[0] = byte(Repr_Meta_Tag.NONE)
    buf[1] = 0
    return size_of(Repr_Meta_Tag) + size_of(u8)
}

// Read `[1b Repr_Meta_Tag][1b u8 len][len bytes]`. An unrecognised tag is skipped via its length and reported as no
// metadata, so a newer daemon does not break an older client.
read_repr_meta :: proc(buf: []byte, offset: ^int) -> (meta: Repr_Meta, err: Maybe(string)) {
    if offset^ + size_of(Repr_Meta_Tag) + size_of(u8) > len(buf) {
        return nil, "truncated meta header"
    }
    tag := Repr_Meta_Tag(buf[offset^])
    meta_len := int(buf[offset^ + 1])
    offset^ += size_of(Repr_Meta_Tag) + size_of(u8)
    if offset^ + meta_len > len(buf) {
        return nil, fmt.tprintf("meta needs %d bytes, %d remain", meta_len, len(buf) - offset^)
    }
    payload := buf[offset^:][:meta_len]
    offset^ += meta_len

    switch tag {
    case .IMAGE_DIMS:
        if meta_len != 2 * size_of(u32) {
            return nil, fmt.tprintf("IMAGE_DIMS meta is %d bytes, expected %d", meta_len, 2 * size_of(u32))
        }
        dims_bytes: [2 * size_of(u32)]byte
        copy(dims_bytes[:], payload)
        return transmute(Image_Dims)dims_bytes, nil
    case .NONE:
        return nil, nil
    }
    // Unknown tag, already skipped by its length, so the stream is still aligned.
    return nil, nil
}

// Write `[1b mime len][mime len bytes]`, returning the bytes written. Caller has already verified the entry fits.
write_resp_mime :: proc(buf: []byte, mime: string) -> (written: int) {
    mime_len := u8(min(len(mime), MAX_MIME_LEN))
    buf[0] = byte(mime_len)
    written = size_of(mime_len)
    copy(buf[written:][:int(mime_len)], mime)
    return written + int(mime_len)
}


// SET (REGISTER): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b source Reg_Id]`
// buf starts after Source_Kind byte
unmarshal_cmd_set_reg :: proc(buf: []byte) -> Reg_Id {
    return Reg_Id(buf[0])
}

// SET (INLINE): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime type len][M mime type][N data]`
// buf starts after Source_Kind byte
//
// Returns owned `mimes` and `data`; the caller frees both. On error nothing is allocated.
unmarshal_cmd_set_inline :: proc(buf: []byte) -> (mimes: []string, data: []byte, err: Maybe(string)) {
    if len(buf) == 0 {
        return nil, nil, "SET request truncated: missing mime count"
    }
    // Mime count
    mime_count := int(buf[0])
    if mime_count == 0 {
        return nil, nil, "SET request carries no mime"
    }

    // Odin `defer` cannot modify a return value (it is copied out first), so cleanup has to happen before an explicit
    // `return nil, ...` or the caller gets a slice of freed memory.
    offset := size_of(u8)
    decoded := make([]string, mime_count)
    filled := 0

    // One mime name per iteration
    for i in 0 ..< mime_count {
        mime, mime_err := read_resp_mime(buf, &offset)
        if mime_err != nil {
            for m in decoded[:filled] {delete(m)}
            delete(decoded)
            return nil, nil, fmt.tprintf("SET request truncated: mime %d %s", i, mime_err.?)
        }
        decoded[i] = mime
        filled += 1
    }
    mimes = decoded

    // Everything after the names is the payload
    data = slice.clone(buf[offset:])
    return mimes, data, nil
}

// GET: `[1b Message_Type][1b group_count]` then per group:
//      `[8b Cmd_Get_Filter][1b mime policy tag]` followed by `[1b mime len][M mime]` for EXACT only.
// buf starts after first Message_Type byte
//
// Decodes into a caller-provided fixed array so an untrusted `group_count` cannot drive an allocation. Every length is
// bounds-checked against `buf` before use, and an unknown policy tag is rejected *before* the offset advances: group size
// depends on that byte, so guessing it would read the next group's filter bytes as a mime length and desync the rest of
// the message.
//
// Exact mimes borrow from `buf` rather than cloning; the daemon's receive buffer outlives the handler.
unmarshal_cmd_get :: proc(buf: []byte, groups: ^[MAX_REGS]Cmd_Get_Group) -> (count: int, err: Maybe(string)) {
    if len(buf) == 0 {
        return 0, "GET request truncated: missing group count"
    }
    // Group count
    count = int(buf[0])
    if count == 0 || count > MAX_REGS {
        return 0, fmt.tprintf("GET request group count %d out of range (1 ..= %d)", count, MAX_REGS)
    }

    offset := size_of(u8)
    // One group per iteration
    for i in 0 ..< count {
        if offset + size_of(Cmd_Get_Filter) + size_of(EXACT_MIME_TAG) > len(buf) {
            return 0, fmt.tprintf("GET request truncated: group %d missing filter/preference", i)
        }

        // Register bitmask
        filter_bytes: [size_of(Cmd_Get_Filter)]byte
        copy(filter_bytes[:], buf[offset:][:size_of(Cmd_Get_Filter)])
        filter := transmute(Cmd_Get_Filter)(transmute(u64)filter_bytes)
        offset += size_of(Cmd_Get_Filter)

        // Validate before advancing: the remaining group size depends on this tag.
        tag := buf[offset]
        if tag > EXACT_MIME_TAG {
            return 0, fmt.tprintf("GET request group %d has unknown mime preference %d", i, tag)
        }
        policy: Mime_Policy = Ranked_Policy(tag) if tag < EXACT_MIME_TAG else Ranked_Policy{}
        offset += size_of(EXACT_MIME_TAG)

        // Exact policies carry a trailing mime name; ranked ones do not
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
            policy = Exact_Mime(string(buf[offset:][:mime_len]))
            offset += mime_len
        }

        groups[i] = Cmd_Get_Group {
            filter = filter,
            policy = policy,
        }
    }

    return count, nil
}

// CLEAR: `[1b Message_Type][1b Reg_Id]`
// buf starts after first Message_Type byte
unmarshal_cmd_clear :: proc(buf: []byte) -> Reg_Id {
    return Reg_Id(buf[0])
}

// State-file serialization. Distinct from the GET response format: state persists FULL fidelity (every repr and every
// mime of every entry), whereas GET (marshal_resp_registers) is a query that packs a single mime/data per entry.
// Keeping them separate lets the GET format change without touching persistence.
//
// Wire format:
//   ["IROH" magic][1b STATE_VERSION]
//   [1b count]
//   for entry in count:
//     [1b Reg_Id][8b i64 timestamp][1b blob_count]
//     for repr in blob_count:
//       [1b mime_count]
//       for mime in mime_count: [1b mime_len][mime_len bytes]
//       [8b u64 data_len][data_len bytes]

// Our state file magic.
STATE_MAGIC :: "IROH"

// Bytes the magic and version prefix occupy. Everything after is the state *body*, so the per-entry offsets above are
// independent of the prefix.
STATE_HEADER_SIZE :: len(STATE_MAGIC) + size_of(Monotonic_Version)

// Exact serialized size of `regs` in the state format, so a caller can allocate a buffer that fits instead of guessing.
state_size :: proc(regs: [MAX_REGS]^Reg_Entry) -> int {
    size := STATE_HEADER_SIZE + size_of(u8) // magic + version + entry count
    for entry in regs {
        if entry == nil {continue}
        size += size_of(Reg_Id) + size_of(i64) + size_of(u8)
        for repr in entry.reprs {
            size += size_of(u8)
            for mime in repr.mimes {
                size += size_of(u8) + len(mime)
            }
            size += size_of(u64) + len(repr.data)
        }
    }
    return size
}

marshal_state :: proc(regs: [MAX_REGS]^Reg_Entry, buf: []byte) -> int {
    // Every write below is unchecked, so a short buffer would run off the end. Size it with `state_size`.
    assert(len(buf) >= state_size(regs), "marshal_state buffer too small; size it with state_size()")

    // Version prefix
    copy(buf[:len(STATE_MAGIC)], STATE_MAGIC)
    buf[len(STATE_MAGIC)] = byte(STATE_VERSION)
    body := buf[STATE_HEADER_SIZE:] // every offset below is relative to the body, not the file

    written := size_of(u8) // reserve count byte
    count: u8 = 0

    // One non-empty register per iteration
    for entry_ptr, id in regs {
        if entry_ptr == nil {continue}

        // Reg ID u8
        body[written] = byte(id)
        written += size_of(Reg_Id)

        // Timestamp i64
        time_bytes := transmute([size_of(i64)]byte)entry_ptr.timestamp
        copy(body[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        // Blob count u8
        body[written] = u8(len(entry_ptr.reprs))
        written += size_of(u8)

        // One repr per iteration
        for repr in entry_ptr.reprs {
            // Mime count u8, then each [mime_len u8][mime bytes]
            body[written] = u8(len(repr.mimes))
            written += size_of(u8)
            for mime in repr.mimes {
                // Clamp rather than wrap: `u8(len(mime))` on a 256-byte name yields 0, which would write the mime's
                // bytes with a length of zero and desync every subsequent field. `write_resp_mime` clamps the same way.
                written += write_resp_mime(body[written:], mime)
            }

            // Data length u64 + data bytes
            data_len := u64(len(repr.data))
            data_len_bytes := transmute([size_of(u64)]byte)data_len
            copy(body[written:][:size_of(u64)], data_len_bytes[:])
            written += size_of(u64)
            copy(body[written:][:int(data_len)], repr.data)
            written += int(data_len)
        }

        count += 1
    }

    // Backfill the reserved count byte
    body[0] = byte(count)
    return STATE_HEADER_SIZE + written
}

// Deserialize state into owned entries indexed by Reg_Id. Slots not present are left zeroed.
//
// On error, entries decoded so far are freed and `regs` is zeroed, so the caller never sees a half-populated array.
// NOTE: on success the caller is responsible for freeing all entries in `regs`.
unmarshal_state :: proc(buf: []byte, regs: ^[MAX_REGS]Reg_Entry) -> (count: u8, err: Maybe(string)) {
    count, err = unmarshal_state_entries(buf, regs)
    if err != nil {
        // Discard whatever parsed before the failure. `free_reg_entry` is a no-op on a zeroed entry, so sweeping the
        // whole array is simpler than tracking which slots were filled -- and this is the only place that can honestly
        // report `count = 0`, since an Odin `defer` cannot modify a return value.
        for &entry in regs {free_reg_entry(&entry)}
        regs^ = {}
        return 0, err
    }
    return count, nil
}

// Decoding half of `unmarshal_state`. Leaves `regs` partially filled on error; the caller sweeps it.
unmarshal_state_entries :: proc(buf: []byte, regs: ^[MAX_REGS]Reg_Entry) -> (count: u8, err: Maybe(string)) {
    regs^ = {}
    if len(buf) < STATE_HEADER_SIZE {
        return 0, "state file is empty"
    }

    // Check magic bytes.
    if string(buf[:len(STATE_MAGIC)]) != STATE_MAGIC {
        return 0, fmt.tprintf(
            "not a clipbender state file (magic %q, expected %q)",
            string(buf[:len(STATE_MAGIC)]),
            STATE_MAGIC,
        )
    }

    // Check state serialization version
    version := Monotonic_Version(buf[len(STATE_MAGIC)])
    if version != STATE_VERSION {
        return 0, fmt.tprintf("state file version %d, expected %d", version, STATE_VERSION)
    }
    body := buf[STATE_HEADER_SIZE:] // every offset below is relative to the body, not the file

    if len(body) == 0 {
        return 0, "state file has no entry count"
    }
    // Entry count
    count = u8(body[0])

    offset := 1
    // One register per iteration
    for entry_idx in 0 ..< int(count) {
        // Reg_Id + timestamp + blob count, read together since they are fixed-width.
        header_size := size_of(Reg_Id) + size_of(i64) + size_of(u8)
        if offset + header_size > len(body) {
            err = fmt.tprintf("entry %d: header needs %d bytes, %d remain", entry_idx, header_size, len(body) - offset)
            return
        }

        // Register id
        reg_id := Reg_Id(body[offset])
        if !reg_id_is_valid(reg_id) {
            err = fmt.tprintf("entry %d: invalid register id %d", entry_idx, u8(reg_id))
            return
        }
        offset += size_of(Reg_Id)

        // Timestamp
        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], body[offset:][:size_of(i64)])
        time := transmute(i64)time_bytes
        offset += size_of(i64)

        // Repr count
        blob_count := int(body[offset])
        offset += size_of(u8)

        // Counts are `u8`, so they cannot drive a large allocation,  but a repeated `reg_id` would leak the entry
        // already stored in that slot, so reject rather than overwrite.
        if len(regs[reg_id].reprs) != 0 {
            err = fmt.tprintf("entry %d: register %s appears twice", entry_idx, reg_id_to_string(reg_id))
            return
        }

        reprs := make([]Data_Repr, blob_count)
        // In-flight work needs its own cleanup: this entry is not in `regs` yet, so `unmarshal_state`'s sweep cannot
        // see it. These defers only free, they never assign to `err` or `count`.
        reprs_filled := 0
        defer if err != nil {
            for i in 0 ..< reprs_filled {free_data_repr(reprs[i])}
            delete(reprs)
        }

        // One repr per iteration
        for b in 0 ..< blob_count {
            // Mime count
            if offset + size_of(u8) > len(body) {
                err = fmt.tprintf("entry %d repr %d: missing mime count", entry_idx, b)
                return
            }
            mime_count := int(body[offset])
            offset += size_of(u8)
            if mime_count == 0 {
                err = fmt.tprintf("entry %d repr %d: no mimes", entry_idx, b)
                return
            }

            mimes := make([]string, mime_count)
            mimes_filled := 0
            defer if err != nil {
                for i in 0 ..< mimes_filled {delete(mimes[i])}
                delete(mimes)
            }

            // Each name for this repr
            for m in 0 ..< mime_count {
                mime, mime_err := read_resp_mime(body, &offset)
                if mime_err != nil {
                    err = fmt.tprintf("entry %d repr %d mime %d: %s", entry_idx, b, m, mime_err.?)
                    return
                }
                mimes[m] = mime
                mimes_filled += 1
            }

            // Data length
            if offset + size_of(u64) > len(body) {
                err = fmt.tprintf("entry %d repr %d: missing data length", entry_idx, b)
                return
            }
            data_len_bytes: [size_of(u64)]byte
            copy(data_len_bytes[:], body[offset:][:size_of(u64)])
            data_len_u64 := transmute(u64)data_len_bytes
            offset += size_of(u64)

            // Range-check data length is not larger than the rest of the bytes in the blob.
            if data_len_u64 > u64(len(body) - offset) {
                err = fmt.tprintf(
                    "entry %d repr %d: data length %d exceeds the %d bytes remaining",
                    entry_idx,
                    b,
                    data_len_u64,
                    len(body) - offset,
                )
                return
            }
            data_len := int(data_len_u64)

            if offset + data_len > len(body) {
                err = fmt.tprintf(
                    "entry %d repr %d: data needs %d bytes, %d remain",
                    entry_idx,
                    b,
                    data_len,
                    len(body) - offset,
                )
                return
            }
            // Payload
            data := slice.clone(body[offset:][:data_len])
            offset += data_len

            reprs[b] = Data_Repr {
                data  = data,
                mimes = mimes,
            }
            reprs_filled += 1
            mimes_filled = 0 // ownership moved into `reprs[b]`, freed by the outer cleanup from here on
        }

        regs[reg_id] = Reg_Entry {
            reprs     = reprs,
            timestamp = time,
        }
        reprs_filled = 0 // ownership moved into `regs[reg_id]`, so `unmarshal_state`'s sweep frees it from here on
    }

    return count, nil
}
