package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:simd"
import "core:strings"
import "core:sys/linux"
import "vendor:stb/truetype"

import xkb "bindings:xkbcommon"
import lib "src:libclipbender"
import wl "wayland:odin-wayland"
import wlr_ls "wayland:wlr-layer-shell"

// Dimensions
POPUP_WIDTH :: 800
POPUP_HEIGHT :: 900

// Colors
BG_COLOR: u32 : 0xFF2E3440 // full alpha, dark gray
FG_COLOR: u32 : 0xFFFFFFFF // full alpha, all white

// Font
FONT_SIZE :: 14 // pixel height of font
FONT_PATHS :: [?]string {
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf", // Fedora
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", // Debian/Ubuntu
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf", // Arch
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf", // Other
    "/usr/share/fonts/DejaVuSansMono.ttf", // Other
}

// Text Layout
TEXT_PADDING_X :: 16 // left margin
TEXT_PADDING_Y :: 16 // top margin
LINE_HEIGHT :: 18 // spacing between rows, doesn't include font size so needs to be greater than FONT_SIZE

XKB_KEYSYM_ESCAPE :: xkb.Xkb_Keysym(0xFF1B)

Frame_Buffer :: struct {
    buffer:   ^wl.buffer,
    shm_pool: ^wl.shm_pool,
    shm_fd:   linux.Fd,
    pixels:   [^]u32, // mmap'd pixel data
    width:    uint,
    height:   uint,
}

Keyboard :: struct {
    keyboard: ^wl.keyboard,
    ctx:      ^xkb.Xkb_Context,
    keymap:   ^xkb.Xkb_Keymap,
    state:    ^xkb.Xkb_State,
    prefix:   Maybe(rune),
}

Font :: struct {
    info:  truetype.fontinfo,
    data:  []byte, // loaded TTF file (must outlive info)
    scale: f32,
}

Gui_State :: struct {
    // Daemon IPC
    client_fd:        linux.Fd,
    // General connection state
    display:          ^wl.display,
    registry:         ^wl.registry,
    seat:             ^wl.seat,
    seat_name:        uint,
    compositor:       ^wl.compositor,
    compositor_name:  uint,
    shm:              ^wl.shm,
    shm_name:         uint,
    layer_shell:      ^wlr_ls.layer_shell_v1,
    layer_shell_name: uint,
    running:          bool,
    // Surface-specific state
    surface:          ^wl.surface,
    layer_surface:    ^wlr_ls.layer_surface_v1,
    // Buffer of pixels
    frame_buf:        Frame_Buffer,
    // Keyboard input
    kb:               Keyboard,
    // Font
    font:             Font,
    // Register data, indexed by Reg_Id
    regs:             [lib.MAX_REGS]lib.Reg_Entry,
}

gui_init_surface :: proc(gui_state: ^Gui_State) {
    // Init wl_surface and wlr_layer_surface
    gui_state.surface = wl.compositor_create_surface(gui_state.compositor)
    gui_state.layer_surface = wlr_ls.layer_shell_v1_get_layer_surface(
        gui_state.layer_shell,
        gui_state.surface,
        nil, // output = `nil` means let the compositor choose
        .overlay,
        "clipbender",
    )

    // Configure layer surface
    width: uint = POPUP_WIDTH
    height: uint = POPUP_HEIGHT
    wlr_ls.layer_surface_v1_set_size(gui_state.layer_surface, width, height)
    wlr_ls.layer_surface_v1_set_keyboard_interactivity(gui_state.layer_surface, .on_demand)

    // Add listener
    wlr_ls.layer_surface_v1_add_listener(gui_state.layer_surface, &layer_surface_listener, rawptr(gui_state))
    wl.surface_commit(gui_state.surface)
}

// combine fg_color * alpha and bg_color * inv(alpha)
alpha_blend :: proc(fg_color: u32, alpha: u8, bg_color: u32) -> u32 {
    a := u32(alpha)
    inv_a := 255 - a
    r := (((fg_color >> 16) & 0xFF) * a + ((bg_color >> 16) & 0xFF) * inv_a) / 255
    g := (((fg_color >> 8) & 0xFF) * a + ((bg_color >> 8) & 0xFF) * inv_a) / 255
    b := ((fg_color & 0xFF) * a + (bg_color & 0xFF) * inv_a) / 255
    return 0xFF000000 | (r << 16) | (g << 8) | b
}

// Draw a single character
draw_char :: proc(frame_buf: ^Frame_Buffer, x: uint, y: uint, char: rune, color: u32, font: ^Font) {
    // Get bitmap from truetype font
    width, height, xoff, yoff: i32
    bitmap := truetype.GetCodepointBitmap(&font.info, 0, font.scale, char, &width, &height, &xoff, &yoff)
    if bitmap == nil {return}
    defer truetype.FreeBitmap(bitmap, nil)

    // Set each pixel according to bitmap
    for row in 0 ..< uint(height) {
        for col in 0 ..< uint(width) {
            alpha := bitmap[row * uint(width) + col] // How opaque pixel at (row,col) is
            if alpha == 0 {continue}     // Fully transparent, nothing to draw

            // Bounds check
            px_i := i32(x) + i32(col) + xoff
            py_i := i32(y) + i32(row) + yoff
            if px_i < 0 || py_i < 0 || uint(px_i) >= frame_buf.width || uint(py_i) >= frame_buf.height {continue}

            // Alpha blend text color over background
            px := uint(px_i)
            py := uint(py_i)
            frame_buf.pixels[py * frame_buf.width + px] = alpha_blend(
                color,
                alpha,
                frame_buf.pixels[py * frame_buf.width + px],
            )
        }
    }
}

// Draw a single string
draw_string :: proc(frame_buf: ^Frame_Buffer, x: uint, y: uint, text: string, color: u32, font: ^Font) {
    cursor_x := x
    for char in text {
        draw_char(frame_buf, cursor_x, y, char, color, font)
        // Advance cursor past char
        advance, lsb: i32
        truetype.GetCodepointHMetrics(&font.info, char, &advance, &lsb)
        cursor_x += uint(f32(advance) * font.scale)
    }
}

gui_init_font :: proc(gui_state: ^Gui_State) -> bool {
    for path in FONT_PATHS {
        font_data, err := os.read_entire_file(path, context.allocator)
        if err != nil {continue}
        if len(font_data) == 0 {
            delete(font_data)
            continue
        }

        font_info: truetype.fontinfo
        if !truetype.InitFont(&font_info, raw_data(font_data), 0) {
            log.warnf("Failed to parse font file: %s", path)
            delete(font_data)
            continue
        }

        gui_state.font.data = font_data
        gui_state.font.info = font_info
        gui_state.font.scale = truetype.ScaleForPixelHeight(&font_info, FONT_SIZE)
        log.debugf(
            "Loaded font from %s (scale=%.3f, glyphs=%d)",
            path,
            gui_state.font.scale,
            gui_state.font.info.numGlyphs,
        )
        return true
    }

    log.error("Failed to load font from any known path")
    return false
}

// Fill pixel buffer with single color using 8 SIMD lanes
fill_pixels_simdx8 :: proc(pixels: [^]u32, count: uint, color: u32) {
    // 8 pixels at a time using 256-bit SIMD (8 lanes x u32 bits in each lane)
    color_vec := simd.u32x8{color, color, color, color, color, color, color, color}

    chunks := count / 8
    rem := count % 8

    pixel_vecs := cast([^]simd.u32x8)pixels
    for i in 0 ..< chunks {
        pixel_vecs[i] = color_vec
    }

    rem_offset := chunks * 8
    for i in 0 ..< rem {
        pixels[rem_offset + i] = color
    }
}

gui_init_buffer :: proc(gui_state: ^Gui_State) -> (err: Maybe(string)) {
    // Create shared memory fd
    errno: linux.Errno
    gui_state.frame_buf.shm_fd, errno = linux.memfd_create("clipbender", {.CLOEXEC})
    if errno != .NONE {
        return fmt.tprintf("Failed to create mem-backed shm FD: errno %v", errno)
    }

    // Truncate size to 4 bytes per pixel (#argb8888)
    width := gui_state.frame_buf.width
    height := gui_state.frame_buf.height
    area_bytes := 4 * width * height
    errno = linux.ftruncate(gui_state.frame_buf.shm_fd, i64(area_bytes))
    if errno != .NONE {
        return fmt.tprintf("Failed to truncate shm FD: errno %v", errno)
    }

    // Map FD into address space to write pixels to
    pixels_ptr: rawptr
    pixels_ptr, errno = linux.mmap(0, area_bytes, {.READ, .WRITE}, {.SHARED}, gui_state.frame_buf.shm_fd, 0)
    if errno != .NONE {
        return fmt.tprintf("Failed to mmap shm FD for pixel array: errno %v", errno)
    }
    gui_state.frame_buf.pixels = cast([^]u32)pixels_ptr

    // Set color of buffer
    fill_pixels_simdx8(gui_state.frame_buf.pixels, width * height, BG_COLOR)

    // Create shm_pool
    gui_state.frame_buf.shm_pool = wl.shm_create_pool(gui_state.shm, int(gui_state.frame_buf.shm_fd), int(area_bytes))

    // Create buffer from the pool and attach to surface
    gui_state.frame_buf.buffer = wl.shm_pool_create_buffer(
        gui_state.frame_buf.shm_pool,
        0,
        int(width),
        int(height),
        int(width * 4), // stride is bytes per row, we have 4 bytes for every pixel in width
        .argb8888,
    )
    wl.surface_attach(gui_state.surface, gui_state.frame_buf.buffer, 0, 0)

    // Commit configuration
    wl.surface_commit(gui_state.surface)

    return nil
}

gui_init :: proc(gui_state: ^Gui_State) -> Maybe(string) {
    gui_state.running = true

    gui_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if gui_state.display == nil {
        return fmt.tprint("Failed to connect to default Wayland display")
    }

    // Get registry
    gui_state.registry = wl.display_get_registry(gui_state.display)
    wl.registry_add_listener(gui_state.registry, &registry_listener, gui_state)

    // Roundtrip to receive registry events (binds seat, compositor, shm, and layer_shell)
    wl.display_roundtrip(gui_state.display)
    if gui_state.seat == nil {
        return fmt.tprint("Failed to bind Wayland seat")
    }
    if gui_state.compositor == nil {
        return fmt.tprint("Failed to bind Wayland compositor")
    }
    if gui_state.shm == nil {
        return fmt.tprint("Failed to bind Wayland shm")
    }
    if gui_state.layer_shell == nil {
        return fmt.tprint("Failed to bind Wayland wlr_layer_shell")
    }

    // Init surface resources and commit
    gui_init_surface(gui_state)
    if gui_state.surface == nil {
        return fmt.tprint("Failed to init Wayland surface")
    }
    if gui_state.layer_surface == nil {
        return fmt.tprint("Failed to init Wayland wlr_layer_surface")
    }

    // Initialize font info (must be before roundtrip since configure callback may render)
    if !gui_init_font(gui_state) {
        return fmt.tprint("Failed to initialize font from file at any known path")
    }

    // Add seat listener to get keyboard
    wl.seat_add_listener(gui_state.seat, &seat_listener, gui_state)

    // Roundtrip to receive configure event for layer_surface_listener
    wl.display_roundtrip(gui_state.display)

    return nil
}

gui_cleanup_font :: proc(gui_state: ^Gui_State) {
    if gui_state.font.data != nil {delete(gui_state.font.data)}
}

gui_cleanup_keyboard :: proc(gui_state: ^Gui_State) {
    if gui_state.kb.state != nil {xkb.xkb_state_unref(gui_state.kb.state)}
    if gui_state.kb.keymap != nil {xkb.xkb_keymap_unref(gui_state.kb.keymap)}
    if gui_state.kb.ctx != nil {xkb.xkb_context_unref(gui_state.kb.ctx)}
    if gui_state.kb.keyboard != nil {wl.keyboard_release(gui_state.kb.keyboard)}
}

gui_cleanup_buffer :: proc(gui_state: ^Gui_State) {
    if gui_state.frame_buf.buffer != nil {wl.buffer_destroy(gui_state.frame_buf.buffer)}
    if gui_state.frame_buf.shm_pool != nil {wl.shm_pool_destroy(gui_state.frame_buf.shm_pool)}
    if gui_state.frame_buf.pixels != nil {
        linux.munmap(rawptr(gui_state.frame_buf.pixels), 4 * gui_state.frame_buf.width * gui_state.frame_buf.height)
    }
    _ = linux.close(gui_state.frame_buf.shm_fd)
}

gui_cleanup_surface :: proc(gui_state: ^Gui_State) {
    if gui_state.layer_surface != nil {wlr_ls.layer_surface_v1_destroy(gui_state.layer_surface)}
    if gui_state.surface != nil {wl.surface_destroy(gui_state.surface)}
}

gui_cleanup :: proc(gui_state: ^Gui_State) {
    // Cleanup register data (indexed by Reg_Id; empty slots free harmlessly)
    for &entry in gui_state.regs {
        lib.free_reg_entry(&entry)
    }
    // Cleanup font
    gui_cleanup_font(gui_state)
    // Cleanup keyboard
    gui_cleanup_keyboard(gui_state)
    // Cleanup buffer
    gui_cleanup_buffer(gui_state)
    // Cleanup surface
    gui_cleanup_surface(gui_state)
    // Cleanup connection state
    if gui_state.layer_shell != nil {wlr_ls.layer_shell_v1_destroy(gui_state.layer_shell)}
    if gui_state.shm != nil {wl.shm_destroy(gui_state.shm)}
    if gui_state.compositor != nil {wl.compositor_destroy(gui_state.compositor)}
    if gui_state.seat != nil {wl.seat_release(gui_state.seat)}
    wl.registry_destroy(gui_state.registry)
    wl.display_disconnect(gui_state.display)

}

registry_listener := wl.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            gui_state.seat = cast(^wl.seat)wl.registry_bind(registry, name_, &wl.seat_interface, 1)
            gui_state.seat_name = name_
        case "wl_compositor":
            gui_state.compositor = cast(^wl.compositor)wl.registry_bind(registry, name_, &wl.compositor_interface, 1)
            gui_state.compositor_name = name_
        case "wl_shm":
            gui_state.shm = cast(^wl.shm)wl.registry_bind(registry, name_, &wl.shm_interface, 1)
            gui_state.shm_name = name_
        case "zwlr_layer_shell_v1":
            gui_state.layer_shell = cast(^wlr_ls.layer_shell_v1)wl.registry_bind(
                registry,
                name_,
                &wlr_ls.layer_shell_v1_interface,
                1,
            )
            gui_state.layer_shell_name = name_
        case:
            return
        }
        log.debugf("Successfully bound Wayland interface `%s`", interface_)
    },
    global_remove = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        if name_ == gui_state.seat_name ||
           name_ == gui_state.compositor_name ||
           name_ == gui_state.shm_name ||
           name_ == gui_state.layer_shell_name {
            interface: string
            switch name_ {
            case gui_state.seat_name:
                interface = "wl_seat"
            case gui_state.compositor_name:
                interface = "wl_compositor"
            case gui_state.shm_name:
                interface = "wl_shm"
            case gui_state.layer_shell_name:
                interface = "zwlr_layer_shell_v1"
            }
            log.errorf("Critical Wayland global removed `%s`, shutting down", interface)
            // TODO: Handle exit
        }
    },
}

layer_surface_listener := wlr_ls.layer_surface_v1_listener {
    configure = proc "c" (
        data: rawptr,
        layer_surface_v1: ^wlr_ls.layer_surface_v1,
        serial_: uint,
        width_: uint,
        height_: uint,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received zwlr_layer_surface_v1::configure event")

        if width_ == 0 || height_ == 0 {
            // Set width & height to default
            gui_state.frame_buf.width = POPUP_WIDTH
            gui_state.frame_buf.height = POPUP_HEIGHT
        } else {
            gui_state.frame_buf.width = width_
            gui_state.frame_buf.height = height_
        }
        wlr_ls.layer_surface_v1_set_size(layer_surface_v1, gui_state.frame_buf.width, gui_state.frame_buf.height)

        // Must ack configure before attach/commit
        wlr_ls.layer_surface_v1_ack_configure(layer_surface_v1, serial_)

        // Clear buf if not empty
        if gui_state.frame_buf.pixels != nil {
            gui_cleanup_buffer(gui_state)
        }
        // Init buf, attach to surface, and commit surface
        err := gui_init_buffer(gui_state)
        if err != nil {
            log.errorf("Failed to init GUI frame buffer: %v", err.?)
            gui_state.running = false
            return
        }

        // Render the GUI pixels if we've already fetched registers
        gui_render(gui_state)
    },
    closed = proc "c" (data: rawptr, layer_surface_v1: ^wlr_ls.layer_surface_v1) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received zwlr_layer_surface_v1::closed event")
        gui_state.running = false
    },
}

// We don't need the name callback here, we're only going to really use one seat
seat_listener := wl.seat_listener {
    capabilities = proc "c" (data: rawptr, seat: ^wl.seat, capabilities_: wl.seat_capability) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received wl_seat::capabilities event")

        if uint(capabilities_) & uint(wl.seat_capability.keyboard) != 0 {
            gui_state.kb.keyboard = wl.seat_get_keyboard(seat)
            wl.keyboard_add_listener(gui_state.kb.keyboard, &keyboard_listener, gui_state)
        }
    },
    name = proc "c" (data: rawptr, seat: ^wl.seat, name_: cstring) {},
}

keyboard_listener := wl.keyboard_listener {
    keymap = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        format_: wl.keyboard_keymap_format,
        fd_: int,
        size_: uint,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        if format_ != .xkb_v1 {
            log.error("Unsupported keymap format")
            return
        }

        // mmap the keymap fd
        map_ptr, mmap_err := linux.mmap(0, size_, {.READ}, {.PRIVATE}, cast(linux.Fd)fd_, 0)
        linux.close(cast(linux.Fd)fd_)
        if mmap_err != .NONE {
            log.error("Failed to mmap keymap fd: errno %v", mmap_err)
            return
        }
        defer linux.munmap(map_ptr, size_)

        // Create xkb context if not yet created
        if gui_state.kb.ctx == nil {
            gui_state.kb.ctx = xkb.xkb_context_new(.XKB_CONTEXT_NO_FLAGS)
            if gui_state.kb.ctx == nil {
                log.error("Failed to create xkb context")
                return
            }
        }

        // Release previous keymap/state if exists
        if gui_state.kb.state != nil {xkb.xkb_state_unref(gui_state.kb.state)}
        if gui_state.kb.keymap != nil {xkb.xkb_keymap_unref(gui_state.kb.keymap)}

        // Create keymap from the mmap'd string
        gui_state.kb.keymap = xkb.xkb_keymap_new_from_string(
            gui_state.kb.ctx,
            cast(cstring)map_ptr,
            .XKB_KEYMAP_FORMAT_TEXT_V1,
            .XKB_KEYMAP_COMPILE_NO_FLAGS,
        )
        if gui_state.kb.keymap == nil {
            log.error("Failed to create xkb keymap from compositor keymap string")
            return
        }

        // Create state from keymap
        gui_state.kb.state = xkb.xkb_state_new(gui_state.kb.keymap)
        if gui_state.kb.state == nil {
            log.error("Failed to create xkb state")
            return
        }

        log.debug("xkb keymap and state initialized successfully")
    },
    enter = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface, keys_: wl.array) {},
    leave = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data
        log.debug("Received wl_keyboard::leave event")
        gui_state.running = false
    },
    key = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        serial_: uint,
        time_: uint,
        key_: uint,
        state_: wl.keyboard_key_state,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        gui_state := cast(^Gui_State)data

        // Right now we don't care about any repeated/released keystrokes
        if state_ != .pressed {return}

        if gui_state.kb.state == nil {return}

        // evdev keycodes need +8 offset for xkbcommon
        keycode := xkb.Xkb_Keycode(key_ + 8)

        // Use the keysym (not the UTF-32 codepoint) as the logical key for dispatch. The keysym accounts for the user's
        // layout and any remaps, and it is NOT subject to the control-character transformation that
        // `xkb_state_key_get_utf32` applies (e.g. <C-a> yields codepoint 1, but keysym stays `XKB_KEY_a`). For the
        // ASCII printable range, keysym values equal their ASCII codepoint, so `rune(keysym)` is the char.
        keysym := xkb.xkb_state_key_get_one_sym(gui_state.kb.state, keycode)
        // ESC to exit GUI
        if keysym == XKB_KEYSYM_ESCAPE {
            gui_state.running = false
            return
        }

        codepoint := rune(keysym)

        // Check modifier state
        ctrl_active := xkb.xkb_state_mod_name_is_active(gui_state.kb.state, "Control", .XKB_STATE_MODS_EFFECTIVE) == 1
        shift_active := xkb.xkb_state_mod_name_is_active(gui_state.kb.state, "Shift", .XKB_STATE_MODS_EFFECTIVE) == 1

        log.debugf(
            "Key pressed: keysym='%d' (codepoint='%c'), ctrl=%v, shift=%v",
            keysym,
            codepoint,
            ctrl_active,
            shift_active,
        )

        // Check prefix keys first, regardless of modifiers
        if codepoint == '@' || codepoint == '*' {
            if gui_state.kb.prefix != nil {
                gui_state.kb.prefix = nil
                return
            }
            gui_state.kb.prefix = codepoint
            return
        }

        // Otherwise, consume the keypress and reset prefix to nil.
        // These operations invoke a SET call from the daemon one way or another.
        msg: [5]byte // SET with source reg is 5-byte message
        dest_reg: lib.Reg_Id
        source_reg: lib.Reg_Id
        set_mode: lib.Set_Mode
        defer gui_state.kb.prefix = nil

        // The GUI always writes to the clipboard; `@` is only a source modifier (read from primary recency).
        if ctrl_active {
            // <C-[>       | cancel / exit edit
            // <C-{alpha}> | clipboard -> overwrite named register, dismiss
            switch codepoint {
            case '[':
                // Ctrl+[ dismisses (same as Escape)
                gui_state.running = false
                return
            case 'a' ..= 'z':
                if gui_state.kb.prefix != nil {
                    log.debugf("`%v<C-%c>` is not a valid key sequence", gui_state.kb.prefix, codepoint)
                    return
                }
                // Send message of form `SET {alpha} clipboard OVERWRITE`
                source_reg = lib.SELECTION_CLIPBOARD
                dest_reg = lib.reg_id_from_named_index(cast(u8)(codepoint - 'a'))
            case:
                return
            }
            set_mode = lib.Set_Mode.OVERWRITE
        } else if shift_active {
            // <S-{alpha}> | clipboard -> append named register, dismiss
            switch codepoint {
            case 'A' ..= 'Z':
                if gui_state.kb.prefix != nil {
                    log.debugf("`%v<S-%c>` is not a valid key sequence", gui_state.kb.prefix, codepoint)
                    return
                }
                // Send message of form `SET {ALPHA} clipboard APPEND`
                source_reg = lib.SELECTION_CLIPBOARD
                dest_reg = lib.reg_id_from_named_index(cast(u8)(codepoint - 'A'))
            case:
                return
            }
            set_mode = lib.Set_Mode.APPEND
        } else {
            // {digit}  | clipboard recency -> clipboard, dismiss
            // @{digit} | primary recency -> clipboard, dismiss
            // {alpha}  | named register -> clipboard, dismiss
            // The GUI always copies to the clipboard, never the primary selection.
            dest_reg = lib.SELECTION_CLIPBOARD
            switch codepoint {
            case '0' ..= '9':
                // Send message of form `SET clipboard {digit}`
                switch gui_state.kb.prefix {
                case nil:
                    source_reg = lib.reg_id_from_clipboard_index(cast(u8)(codepoint - '0'))
                case '@':
                    source_reg = lib.reg_id_from_primary_index(cast(u8)(codepoint - '0'))
                case '*':
                    log.debugf(
                        "`*%c` is not a valid key sequence, inline edit only works for named registers, did you mean `*{alpha}`?",
                        codepoint,
                    )
                    return
                }
            case 'a' ..= 'z':
                // Send message of form `SET clipboard {alpha}`
                switch gui_state.kb.prefix {
                case nil:
                    source_reg = lib.reg_id_from_named_index(cast(u8)(codepoint - 'a'))
                case '@':
                    log.debugf(
                        "`@%c` is not a valid key sequence, `@` only applies to primary recency digits",
                        codepoint,
                    )
                    return
                case '*':
                    // TODO: inline edit from empty and overwrite register
                    return
                }
            case:
                return
            }
            set_mode = lib.Set_Mode.OVERWRITE
        }

        // Encode and send the SET message
        written := lib.marshal_cmd_set_reg(dest_reg, source_reg, set_mode, msg[:])
        _, send_err := linux.send(gui_state.client_fd, msg[:written], {.NOSIGNAL})
        if send_err != nil {
            log.errorf(
                "Failed sending SET reg `%s` from reg `%s` to daemon: errno %v",
                lib.reg_id_to_string(dest_reg),
                lib.reg_id_to_string(source_reg),
                send_err,
            )
            return
        }

        // Receive response from daemon
        resp_buf: [RESP_BUF_SMALL]u8
        bytes_read, recv_err := linux.recv(gui_state.client_fd, resp_buf[:], {})
        if recv_err != .NONE || bytes_read <= 0 {
            log.errorf(
                "Failed receiving SET reg `%s` from reg `%s`: errno %v",
                lib.reg_id_to_string(dest_reg),
                lib.reg_id_to_string(source_reg),
                recv_err,
            )
            return
        }

        status := lib.Resp_Status(resp_buf[0])
        switch status {
        case .OK:
            // TODO: highlight green or something, indicate success
            // Close GUI
            gui_state.running = false
        case .ERROR:
            err_msg := string(resp_buf[1:bytes_read])
            log.errorf(
                "Failed setting register `%s` from register `%s`: %v",
                lib.reg_id_to_string(dest_reg),
                lib.reg_id_to_string(source_reg),
                err_msg,
            )
        // TODO: highlight red or something, indicate failure
        case .REGISTERS:
            log.error("Unexpected REGISTERS response for `set` command")
        // TODO: wtf how'd we get here?
        }
    },
    modifiers = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        serial_: uint,
        mods_depressed_: uint,
        mods_latched_: uint,
        mods_locked_: uint,
        group_: uint,
    ) {
        gui_state := cast(^Gui_State)data
        if gui_state.kb.state == nil {return}
        xkb.xkb_state_update_mask(
            gui_state.kb.state,
            cast(xkb.Xkb_Mod_Mask)mods_depressed_,
            cast(xkb.Xkb_Mod_Mask)mods_latched_,
            cast(xkb.Xkb_Mod_Mask)mods_locked_,
            cast(xkb.Xkb_Layout_Index)0,
            cast(xkb.Xkb_Layout_Index)0,
            cast(xkb.Xkb_Layout_Index)group_,
        )
    },
    repeat_info = proc "c" (data: rawptr, keyboard: ^wl.keyboard, rate_: int, delay_: int) {},
}

gui_fetch_registers :: proc(client_fd: linux.Fd, gui_state: ^Gui_State) -> (err: Maybe(string)) {
    // Send GET message for all registers
    msg: [9]byte
    written := lib.marshal_cmd_get(lib.CMD_GET_FILTER_ALL, msg[:])
    _, send_err := linux.send(client_fd, msg[:written], {.NOSIGNAL})
    if send_err != nil {
        return fmt.tprintf("Failed sending GET to daemon: errno %v", send_err)
    }

    // Receive response from daemon
    resp_buf: [RESP_BUF_LARGE]u8
    bytes_read, recv_err := linux.recv(client_fd, resp_buf[:], {})
    if recv_err != .NONE || bytes_read <= 0 {
        return fmt.tprintf("No response from daemon when fetching registers: errno %v", recv_err)
    }

    status := lib.Resp_Status(resp_buf[0])
    switch status {
    case .OK:
        return fmt.tprint("Unexpected OK response when fetching registers")
    case .ERROR:
        err_msg := string(resp_buf[1:bytes_read])
        return fmt.tprintf("%s", err_msg)
    case .REGISTERS:
        lib.unmarshal_resp_registers(resp_buf[1:bytes_read], &gui_state.regs)
    }

    return nil
}

draw_register :: proc(gui_state: ^Gui_State, reg_id: lib.Reg_Id, x: uint, y: uint, color: u32) {
    CONTENT_WIDTH :: 100
    reg_fmt := "% 8s  % -" + "100s"

    // `regs` is indexed by Reg_Id; an empty slot (nil data) renders as a blank register line
    entry := gui_state.regs[reg_id]
    content := "" if entry.data == nil else truncate_content(string(entry.data), CONTENT_WIDTH)
    reg_str := fmt.tprintf(reg_fmt, lib.reg_id_to_string(reg_id), content)

    draw_string(&gui_state.frame_buf, x, y, reg_str, color, &gui_state.font)
}

draw_all_registers :: proc(gui_state: ^Gui_State, x: uint, y: uint, color: u32) {
    cursor_x := x
    cursor_y := y

    // Draw all clipboard registers first
    for i := lib.CLIPBOARD_START; i <= lib.CLIPBOARD_END; i += 1 {
        draw_register(gui_state, i, cursor_x, cursor_y, color)
        cursor_y += LINE_HEIGHT
    }

    // TODO: Probably increase cursor_x to place clipboard + primary side-by-side at some point
    // Draw all primary registers
    for i := lib.PRIMARY_START; i <= lib.PRIMARY_END; i += 1 {
        draw_register(gui_state, i, cursor_x, cursor_y, color)
        cursor_y += LINE_HEIGHT
    }

    // TODO: If clipboard + primary are side-by-side, reset cursor_x to x
    // Draw all named registers
    for i := lib.NAMED_START; i <= lib.NAMED_END; i += 1 {
        draw_register(gui_state, i, cursor_x, cursor_y, color)
        cursor_y += LINE_HEIGHT
    }
}

gui_render :: proc(gui_state: ^Gui_State) {
    draw_all_registers(gui_state, TEXT_PADDING_X, TEXT_PADDING_Y, FG_COLOR)
}

run_gui :: proc(client_fd: linux.Fd) {
    // Single-instance lock to prevent multiple popups
    lock_path := lib.clipbender_lock_path()
    defer delete(lock_path)

    lock_fd, open_err := linux.open(
        strings.clone_to_cstring(lock_path, context.temp_allocator),
        {.CREAT, .RDWR},
        {.IRUSR, .IWUSR},
    )
    if open_err != .NONE {
        fmt.eprintfln("Error: could not open lock file at %s: errno %v", lock_path, open_err)
        os.exit(1)
    }
    defer linux.close(lock_fd)
    flock_err := linux.flock(lock_fd, {.EX, .NB})
    if flock_err != .NONE {
        fmt.eprintln("Error: another clipbender popup is already running")
        os.exit(0)
    }

    gui_state: Gui_State
    gui_state.client_fd = client_fd
    err := gui_init(&gui_state)
    if err != nil {
        fmt.eprintfln("Error: could not initialize GUI state: %s", err)
        os.exit(1)
    }
    defer gui_cleanup(&gui_state)
    log.debug("GUI initialized")

    // Fetch registers
    err = gui_fetch_registers(client_fd, &gui_state)
    if err != nil {
        fmt.eprintfln("Error: could not fetch registers: %s", err)
    }

    gui_render(&gui_state)
    log.debug("GUI rendered, entering event loop")

    for gui_state.running {
        wl.display_dispatch(gui_state.display)
    }
}
