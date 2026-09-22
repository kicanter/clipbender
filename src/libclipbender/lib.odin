package libclipbender

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Max data allowed to pass over IPC
MAX_MSG_SIZE :: 65536 // 64 KiB

// One unique byte stream plus every mime name it answers to. A register holds several of these when an application
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

// Exact wire sizes for the fixed-length commands, so callers size their buffers from the format rather than counting
// bytes by hand. Each mirrors what the matching `marshal_*` returns.
//
// SET (INLINE) and GET have no constant: both carry variable-length payloads and use `MAX_MSG_SIZE` buffers.
CMD_SET_REG_SIZE :: size_of(Command_Type) + (2 * size_of(Reg_Id)) + size_of(Set_Mode) + size_of(Source_Kind)
CMD_CLEAR_SIZE :: size_of(Command_Type) + size_of(Reg_Id)
CMD_SHUTDOWN_SIZE :: size_of(Command_Type)
// Bytes every SET carries before its source-specific tail: REGISTER adds a source Reg_Id, INLINE adds a mime length.
// Both tails are at least one byte, so `CMD_SET_HEADER_SIZE + 1` is the shortest legal SET.
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
//
// `Ranked_Mime` represents the daemon picking the highest priority mime. `RICHEST` is a pure ranking with no boundary
// that degrades all the way to plain text, so it is effectively never empty. `PRINTABLE` is a filter *plus* a ranking
// e.g. an image is not a worse answer for a terminal, it is a wrong one that corrupts the output, so it will only
// include terminal-safe mimes.
Mime_Pref :: union #no_nil {
    Ranked_Mime, // daemon is in charge of selecting the highest prioritized mime
    Exact_Mime, // client passes exactly what mime type they want to receive
}
Ranked_Mime :: enum u8 {
    PRINTABLE, // safe to write to a terminal or redirect; excludes images, so it CAN come up empty
    RICHEST, // highest fidelity available; no boundary, degrades to plain text, effectively never empty
}
Exact_Mime :: distinct string // specify exactly what mime to receive
// Wire tag for the `Mime_Pref` union. `Ranked_Mime` variants encode as their own ordinals (PRINTABLE=0, RICHEST=1) and
// `Exact_Mime` takes the next value after them, derived so that adding a ranked variant shifts the sentinel
// automatically instead of silently colliding with it.
//
// This is the value one past the last ranked variant, not a count of wire tags. Deriving it from `len` only works while
// `Ranked_Mime` stays contiguous from zero -- assigning explicit values would leave `len` unchanged while moving the
// variants, so `Ranked_Mime(tag)` would decode garbage. The assert pins that down.
EXACT_MIME_TAG :: u8(len(Ranked_Mime))
// ensure the tag for `Exact_Mime` is one more than the last in `Ranked_Mime`
#assert(u8(max(Ranked_Mime)) + 1 == EXACT_MIME_TAG)

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
IMAGE_MIMES := [?]string {
    "image/png",
    "image/webp",
    "image/jpeg",
    "image/tiff",
    "image/bmp",
    "image/gif",
    "image/svg+xml",
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

// Pick which stored mime repr a GET group gets, as an index into `entry.reprs`. An `Exact_Mime` miss never falls back.
resolve_repr :: proc(entry: ^Reg_Entry, pref: Mime_Pref) -> (int, bool) {
    switch p in pref {
    case Exact_Mime:
        return repr_with_mime(entry, string(p))
    case Ranked_Mime:
        switch p {
        case .PRINTABLE:
            return first_match(entry, {TEXT_MIMES[:], STRUCTURED_MIMES[:], URI_MIMES[:], MARKUP_MIMES[:]})
        case .RICHEST:
            return first_match(
                entry,
                {IMAGE_MIMES[:], MARKUP_MIMES[:], STRUCTURED_MIMES[:], URI_MIMES[:], TEXT_MIMES[:]},
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
//     [1b mime len][mime len bytes]                       // the representation `data` holds; len 0 == none matched
//     [1b other count][[1b mime len][mime len bytes]...]  // every other name the register offers
//     [4b u32 data len][data len bytes]
//
// Every mime name the register offers, and the bytes of exactly one representation. If the first `mime len == 0` that
// implies there was no data sent.
Resp_Status :: enum u8 {
    OK,
    ERROR,
    REGISTERS,
}

// One register as returned by GET: a projection of a `Reg_Entry` through a mime preference, not the entry itself.
//
// `mime` names the representation `data` holds, and is `""` exactly when nothing matched the preference (in which case
// `data` is empty too). `other_mimes` are names the register also offers whose bytes were not sent including any
// additional names for the sent representation, since those describe the same bytes.
Resp_Reg :: struct {
    mime:        string,
    data:        []byte,
    other_mimes: []string,
    timestamp:   i64,
}

// True for a Reg_Id slot the response did not mention. A register that was returned always names at least one
// representation (in `mime` if one was sent, in `other_mimes` otherwise) so an absence of names is the marker.
resp_reg_is_empty :: proc(reg: Resp_Reg) -> bool {
    return reg.mime == "" && len(reg.other_mimes) == 0
}

// Free the mime names, the other_mimes slice, and the data, then zero the entry.
free_resp_reg :: proc(reg: ^Resp_Reg) {
    delete(reg.mime)
    for mime in reg.other_mimes {
        delete(mime)
    }
    delete(reg.other_mimes)
    delete(reg.data)
    reg^ = {}
}

// Magic bytes and their respective mime types
// A byte signature and every mime the matched content legitimately claims. Plural because text-based formats are
// genuinely more than one thing e.g. an RTF document is `application/rtf` *and* `text/plain`, while binary formats
// carry a single name. Ordered most-specific-first.
Magic :: struct {
    bytes: []byte,
    mimes: []string,
}
MAGIC_PNG :: Magic{{'\x89', 'P', 'N', 'G'}, {"image/png"}}
MAGIC_JPEG :: Magic{{'\xFF', '\xD8'}, {"image/jpeg"}}
MAGIC_BMP :: Magic{{'B', 'M'}, {"image/bmp"}}
MAGIC_GIF :: Magic{{'G', 'I', 'F', '8'}, {"image/gif"}}
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

// Free a repr.
free_data_repr :: proc(repr: Data_Repr) {
    delete(repr.data)
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
    buf[0] = byte(Command_Type.SET)
    buf[1] = byte(dest)
    buf[2] = byte(set_mode)
    buf[3] = byte(Source_Kind.REGISTER)
    buf[4] = byte(source)
    return CMD_SET_REG_SIZE
}

// SET (INLINE): `[1b Message_Type][1b destination Reg_Id][1b Set_Mode][1b Source_Kind][1b mime count]`
//               then `[1b mime len][M mime]` per mime, then `[N data]`.
//
// Callers must reject mimes longer than MAX_MIME_LEN beforehand; `write_resp_mime` clamps rather than failing.
marshal_cmd_set_inline :: proc(dest: Reg_Id, set_mode: Set_Mode, mimes: []string, data: []byte, buf: []byte) -> int {
    buf[0] = byte(Command_Type.SET)
    buf[1] = byte(dest)
    buf[2] = byte(set_mode)
    buf[3] = byte(Source_Kind.INLINE)
    buf[4] = u8(min(len(mimes), int(max(u8))))
    written := CMD_SET_HEADER_SIZE + size_of(u8)
    for mime in mimes[:int(buf[4])] {
        written += write_resp_mime(buf[written:], mime)
    }
    copy(buf[written:][:len(data)], data)
    written += len(data)
    return written
}

// Bytes `marshal_cmd_set_inline` will write, so the caller can size its buffer exactly.
cmd_set_inline_size :: proc(mimes: []string, data: []byte) -> int {
    size := CMD_SET_HEADER_SIZE + size_of(u8) + len(data)
    for mime in mimes {
        size += size_of(u8) + min(len(mime), MAX_MIME_LEN)
    }
    return size
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
    return CMD_CLEAR_SIZE
}

// SHUTDOWN: `[1b Message_Type]`
marshal_cmd_shutdown :: proc(buf: []byte) -> int {
    buf[0] = byte(Command_Type.SHUTDOWN)
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

        reg_id := Reg_Id(buf[offset])
        if !reg_id_is_valid(reg_id) {
            // Guards the array index below: Reg_Id is a u8, so an invalid one would write past a [MAX_REGS] array.
            return 0, fmt.tprintf("REGISTERS response entry %d has invalid register id %d", i, u8(reg_id))
        }
        offset += size_of(Reg_Id)

        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], buf[offset:][:size_of(i64)])
        regs[reg_id].timestamp = transmute(i64)time_bytes
        offset += size_of(i64)

        // The sent representation's mime. Length 0 means nothing matched the preference, leaving `mime` empty.
        mime, mime_err := read_resp_mime(buf, &offset)
        if mime_err != nil {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d mime (%s)", i, mime_err.?)
        }
        regs[reg_id].mime = mime

        if offset + size_of(u8) > len(buf) {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d other-mime count", i)
        }
        other_count := int(buf[offset])
        offset += size_of(u8)

        // Commit before filling so the deferred cleanup can free a partially decoded entry. `delete` on a zeroed string
        // is a no-op, so the untouched tail is safe to free.
        others := make([]string, other_count)
        regs[reg_id].other_mimes = others
        // Iterate through other mimes in response
        for m in 0 ..< other_count {
            other, other_err := read_resp_mime(buf, &offset)
            if other_err != nil {
                return 0, fmt.tprintf("REGISTERS response truncated: entry %d other mime %d (%s)", i, m, other_err.?)
            }
            others[m] = other
        }

        if offset + size_of(u32) > len(buf) {
            return 0, fmt.tprintf("REGISTERS response truncated: entry %d data length", i)
        }
        data_len_bytes: [size_of(u32)]byte
        copy(data_len_bytes[:], buf[offset:][:size_of(u32)])
        data_len := int(transmute(u32)data_len_bytes)
        offset += size_of(u32)
        if regs[reg_id].mime == "" && data_len != 0 {
            // `mime` empty means no representation was sent, so bytes here would contradict the header.
            return 0, fmt.tprintf("REGISTERS response entry %d carries %d data bytes with no mime", i, data_len)
        }
        if offset + data_len > len(buf) {
            return 0, fmt.tprintf(
                "REGISTERS response truncated: entry %d data needs %d bytes, %d remain",
                i,
                data_len,
                len(buf) - offset,
            )
        }
        // Skip the clone when nothing matched the preference: `slice.clone` calls `make` unconditionally, so cloning an
        // empty slice would allocate for every register whose content the preference rejected.
        if data_len > 0 {
            regs[reg_id].data = slice.clone(buf[offset:][:data_len])
            offset += data_len
        }
    }

    return count, nil
}

// Read `[1b mime len][mime len bytes]` at `offset`, advancing it. Returns an owned clone; a length of 0 yields "".
read_resp_mime :: proc(buf: []byte, offset: ^int) -> (mime: string, err: Maybe(string)) {
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
// `regs` is indexed by Reg_Id; only non-empty slots are packed onto the wire, each tagged with its Reg_Id. `prefs` is
// indexed the same way and says which representation each register should contribute.
//
// Returns `ok = false` if a complete response does not fit in `buf`.
marshal_resp_registers :: proc(
    regs: [MAX_REGS]^Reg_Entry,
    prefs: [MAX_REGS]Mime_Pref,
    buf: []byte,
) -> (
    written: int,
    ok: bool,
) {
    if len(buf) < size_of(Resp_Status) + size_of(u8) {return 0, false}

    buf[0] = byte(Resp_Status.REGISTERS)
    // Reserve the count byte, fill it in after we know how many non-empty entries there are
    written = size_of(Resp_Status) + size_of(u8)
    count: u8 = 0

    for entry_ptr, id in regs {
        if entry_ptr == nil {continue}

        // The representation this register contributes: its bytes, and the one name that goes in the mime slot. Every
        // other name the register offers becomes preview.
        chosen, has_blob := resolve_repr(entry_ptr, prefs[id])
        data: []byte
        mime: string
        if has_blob {
            data = entry_ptr.reprs[chosen].data
            mime = entry_ptr.reprs[chosen].mimes[0]
        }

        // Pre-size the entry so it is written all-or-nothing.
        other_count := 0
        size := size_of(Reg_Id) + size_of(i64) + size_of(u8) + len(mime) + size_of(u8)
        for repr in entry_ptr.reprs {
            for m in repr.mimes {
                if has_blob && m == mime {continue}
                other_count += 1
                size += size_of(u8) + len(m)
            }
        }
        size += size_of(u32) + len(data)
        if written + size > len(buf) {return 0, false}

        // Reg ID u8
        buf[written] = byte(id)
        written += size_of(Reg_Id)

        // Timestamp i64
        time_bytes := transmute([size_of(i64)]byte)entry_ptr.timestamp
        copy(buf[written:][:size_of(i64)], time_bytes[:])
        written += size_of(i64)

        // The sent representation's mime; length 0 when nothing matched the preference
        written += write_resp_mime(buf[written:], mime)

        // Other names u8 count, then each one
        buf[written] = u8(other_count)
        written += size_of(u8)
        for repr in entry_ptr.reprs {
            for m in repr.mimes {
                if has_blob && m == mime {continue}
                written += write_resp_mime(buf[written:], m)
            }
        }

        // Data length u32 + the sent representation's bytes (length 0 when nothing matched)
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
    return written, true
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
    mime_count := int(buf[0])
    if mime_count == 0 {
        return nil, nil, "SET request carries no mime"
    }

    // Odin `defer` cannot modify a return value (it is copied out first), so cleanup has to happen before an explicit
    // `return nil, ...` or the caller gets a slice of freed memory.
    offset := size_of(u8)
    decoded := make([]string, mime_count)
    filled := 0

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

    data = slice.clone(buf[offset:])
    return mimes, data, nil
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

// State-file serialization. Distinct from the GET response format: state persists FULL fidelity (every repr and every
// mime of every entry), whereas GET (marshal_resp_registers) is a query that packs a single mime/data per entry.
// Keeping them separate lets the GET format change without touching persistence.
//
// Wire format:
//   [1b count]
//   for entry in count:
//     [1b Reg_Id][8b i64 timestamp][1b blob_count]
//     for repr in blob_count:
//       [1b mime_count]
//       for mime in mime_count: [1b mime_len][mime_len bytes]
//       [4b u32 data_len][data_len bytes]
// Exact serialized size of `regs` in the state format, so a caller can allocate a buffer that fits instead of guessing.
state_size :: proc(regs: [MAX_REGS]^Reg_Entry) -> int {
    size := size_of(u8) // entry count
    for entry in regs {
        if entry == nil {continue}
        size += size_of(Reg_Id) + size_of(i64) + size_of(u8)
        for repr in entry.reprs {
            size += size_of(u8)
            for mime in repr.mimes {
                size += size_of(u8) + len(mime)
            }
            size += size_of(u32) + len(repr.data)
        }
    }
    return size
}

marshal_state :: proc(regs: [MAX_REGS]^Reg_Entry, buf: []byte) -> int {
    // Every write below is unchecked, so a short buffer would run off the end. Size it with `state_size`.
    assert(len(buf) >= state_size(regs), "marshal_state buffer too small; size it with state_size()")

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
        buf[written] = u8(len(entry_ptr.reprs))
        written += size_of(u8)

        for repr in entry_ptr.reprs {
            // Mime count u8, then each [mime_len u8][mime bytes]
            buf[written] = u8(len(repr.mimes))
            written += size_of(u8)
            for mime in repr.mimes {
                // Clamp rather than wrap: `u8(len(mime))` on a 256-byte name yields 0, which would write the mime's
                // bytes with a length of zero and desync every subsequent field. `write_resp_mime` clamps the same way.
                written += write_resp_mime(buf[written:], mime)
            }

            // Data length u32 + data bytes
            data_len := u32(len(repr.data))
            data_len_bytes := transmute([size_of(u32)]byte)data_len
            copy(buf[written:][:size_of(u32)], data_len_bytes[:])
            written += size_of(u32)
            copy(buf[written:][:int(data_len)], repr.data)
            written += int(data_len)
        }

        count += 1
    }

    buf[0] = byte(count)
    return written
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
    if len(buf) == 0 {
        return 0, "state file is empty"
    }
    count = u8(buf[0])

    offset := 1
    for entry_idx in 0 ..< int(count) {
        // Reg_Id + timestamp + blob count, read together since they are fixed-width.
        header_size := size_of(Reg_Id) + size_of(i64) + size_of(u8)
        if offset + header_size > len(buf) {
            err = fmt.tprintf("entry %d: header needs %d bytes, %d remain", entry_idx, header_size, len(buf) - offset)
            return
        }

        reg_id := Reg_Id(buf[offset])
        if !reg_id_is_valid(reg_id) {
            err = fmt.tprintf("entry %d: invalid register id %d", entry_idx, u8(reg_id))
            return
        }
        offset += size_of(Reg_Id)

        time_bytes: [size_of(i64)]byte
        copy(time_bytes[:], buf[offset:][:size_of(i64)])
        time := transmute(i64)time_bytes
        offset += size_of(i64)

        blob_count := int(buf[offset])
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

        for b in 0 ..< blob_count {
            if offset + size_of(u8) > len(buf) {
                err = fmt.tprintf("entry %d repr %d: missing mime count", entry_idx, b)
                return
            }
            mime_count := int(buf[offset])
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

            for m in 0 ..< mime_count {
                mime, mime_err := read_resp_mime(buf, &offset)
                if mime_err != nil {
                    err = fmt.tprintf("entry %d repr %d mime %d: %s", entry_idx, b, m, mime_err.?)
                    return
                }
                mimes[m] = mime
                mimes_filled += 1
            }

            if offset + size_of(u32) > len(buf) {
                err = fmt.tprintf("entry %d repr %d: missing data length", entry_idx, b)
                return
            }
            data_len_bytes: [size_of(u32)]byte
            copy(data_len_bytes[:], buf[offset:][:size_of(u32)])
            data_len := int(transmute(u32)data_len_bytes)
            offset += size_of(u32)

            // `int` arithmetic, so a `data_len` of 0xFFFFFFFF is caught here rather than wrapping the comparison.
            if offset + data_len > len(buf) {
                err = fmt.tprintf(
                    "entry %d repr %d: data needs %d bytes, %d remain",
                    entry_idx,
                    b,
                    data_len,
                    len(buf) - offset,
                )
                return
            }
            data := slice.clone(buf[offset:][:data_len])
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
