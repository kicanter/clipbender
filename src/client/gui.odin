package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:simd"
import "core:sys/linux"
import "vendor:stb/truetype"

import wl "wayland:odin-wayland"
import wlr_ls "wayland:wlr-layer-shell"

// Dimensions
POPUP_WIDTH :: 800
POPUP_HEIGHT :: 600

// Colors
BG_COLOR: u32 : 0xFF2E3440 // full alpha, dark gray
FG_COLOR: u32 : 0xFFFFFFFF // full alpha, all white

// Font
FONT_SIZE :: 16 // pixel height of font
FONT_PATHS :: [?]string {
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf", // Fedora
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", // Debian/Ubuntu
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf", // Arch
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf", // Other
    "/usr/share/fonts/DejaVuSansMono.ttf", // Other
}

// Text Layout
TEXT_PADDING_X :: 100 // left margin
TEXT_PADDING_Y :: 100 // top margin
LINE_HEIGHT :: 20 // spacing between rows

Frame_Buffer :: struct {
    buffer:   ^wl.buffer,
    shm_pool: ^wl.shm_pool,
    shm_fd:   linux.Fd,
    pixels:   [^]u32, // mmap'd pixel data
    width:    uint,
    height:   uint,
}

Font :: struct {
    info:  truetype.fontinfo,
    data:  []byte, // loaded TTF file (must outlive info)
    scale: f32,
}

Gui_State :: struct {
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
    keyboard:         ^wl.keyboard,
    // Font
    font:             Font,
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
    wlr_ls.layer_surface_v1_set_keyboard_interactivity(gui_state.layer_surface, .exclusive)

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

        font_info: truetype.fontinfo
        truetype.InitFont(&font_info, raw_data(font_data), 0)

        gui_state.font.data = font_data
        gui_state.font.info = font_info
        gui_state.font.scale = truetype.ScaleForPixelHeight(&font_info, FONT_SIZE)
        return true
    }

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
        return fmt.tprintf("Failed to create mem-backed shm FD, errno: %v", errno)
    }

    // Truncate size to 4 bytes per pixel (#argb8888)
    width := gui_state.frame_buf.width
    height := gui_state.frame_buf.height
    area_bytes := 4 * width * height
    errno = linux.ftruncate(gui_state.frame_buf.shm_fd, i64(area_bytes))
    if errno != .NONE {
        return fmt.tprintf("Failed to truncate shm FD, errno: %v", errno)
    }

    // Map FD into address space to write pixels to
    pixels_ptr: rawptr
    pixels_ptr, errno = linux.mmap(0, area_bytes, {.READ, .WRITE}, {.SHARED}, gui_state.frame_buf.shm_fd, 0)
    if errno != .NONE {
        return fmt.tprintf("Failed to mmap shm FD for pixel array, errno: %v", errno)
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

gui_init :: proc() -> Gui_State {
    gui_state: Gui_State
    gui_state.running = true

    gui_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if gui_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return {}
    }

    // Get registry
    gui_state.registry = wl.display_get_registry(gui_state.display)
    wl.registry_add_listener(gui_state.registry, &registry_listener, &gui_state)

    // Roundtrip to receive registry events (binds seat, compositor, shm, and layer_shell)
    wl.display_roundtrip(gui_state.display)
    if gui_state.seat == nil {
        log.error("Failed to bind Wayland seat")
        gui_state.running = false
        return {}
    }
    if gui_state.compositor == nil {
        log.error("Failed to bind Wayland compositor")
        gui_state.running = false
        return {}
    }
    if gui_state.shm == nil {
        log.error("Failed to bind Wayland shm")
        gui_state.running = false
        return {}
    }
    if gui_state.layer_shell == nil {
        log.error("Failed to bind Wayland wlr_layer_shell")
        gui_state.running = false
        return {}
    }

    // Init surface resources and commit
    gui_init_surface(&gui_state)
    if gui_state.surface == nil {
        log.error("Failed to init Wayland surface")
        gui_state.running = false
        return {}
    }
    if gui_state.layer_surface == nil {
        log.error("Failed to init Wayland wlr_layer_surface")
        gui_state.running = false
        return {}
    }

    // Add seat listener to get keyboard
    wl.seat_add_listener(gui_state.seat, &seat_listener, &gui_state)

    // Roundtrip to receive configure event for layer_surface_listener
    wl.display_roundtrip(gui_state.display)

    // Initialize font info
    if !gui_init_font(&gui_state) {
        log.error("Failed to initialize font from file at any known path")
        return {}
    }

    return gui_state
}

gui_cleanup_font :: proc(gui_state: ^Gui_State) {
    if gui_state.font.data != nil {delete(gui_state.font.data)}
}

gui_cleanup_keyboard :: proc(gui_state: ^Gui_State) {
    if gui_state.keyboard != nil {wl.keyboard_release(gui_state.keyboard)}
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
            log.debugf("Uninterested in Wayland registry global callback for interface `%s`", interface_)
            return
        }
        log.debugf("Successfully bound Wayland interface `%s`", interface_)
    },
    global_remove = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint) {
        context = runtime.default_context()
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

        // Render the GUI pixels
        gui_render(gui_state)
    },
    closed = proc "c" (data: rawptr, layer_surface_v1: ^wlr_ls.layer_surface_v1) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data
        log.debug("Received zwlr_layer_surface_v1::closed event")
        gui_state.running = false
    },
}

// We don't need the name callback here, we're only going to really use one seat
seat_listener := wl.seat_listener {
    capabilities = proc "c" (data: rawptr, seat: ^wl.seat, capabilities_: wl.seat_capability) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data
        log.debug("Received wl_seat::capabilities event")

        if uint(capabilities_) & uint(wl.seat_capability.keyboard) != 0 {
            gui_state.keyboard = wl.seat_get_keyboard(seat)
            wl.keyboard_add_listener(gui_state.keyboard, &keyboard_listener, gui_state)
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
    ) {},
    enter = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface, keys_: wl.array) {},
    leave = proc "c" (data: rawptr, keyboard: ^wl.keyboard, serial_: uint, surface_: ^wl.surface) {},
    key = proc "c" (
        data: rawptr,
        keyboard: ^wl.keyboard,
        serial_: uint,
        time_: uint,
        key_: uint,
        state_: wl.keyboard_key_state,
    ) {
        context = runtime.default_context()
        gui_state := cast(^Gui_State)data
        log.debugf("Received wl_keyboard::key event (key: %d, state: %v)", key_, state_)
        // Escape keycode = 1, pressed = 1
        if state_ == .pressed {
            switch key_ {
            // ESC
            case 1:
                gui_state.running = false
                return
            }
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
    ) {},
    repeat_info = proc "c" (data: rawptr, keyboard: ^wl.keyboard, rate_: int, delay_: int) {},
}

gui_render :: proc(gui_state: ^Gui_State) {
    draw_string(&gui_state.frame_buf, 200, 200, "Hello Clipbender", FG_COLOR, &gui_state.font)
}

run_gui :: proc(socket_fd: linux.Fd) {
    gui_state := gui_init()
    if gui_state.display == nil {
        fmt.eprintln("Error: failed to connect to Wayland compositor")
        os.exit(1)
    }
    defer gui_cleanup(&gui_state)

    fmt.println("GUI popup successfully connected to Wayland")
    for gui_state.running {
        wl.display_dispatch(gui_state.display)
    }
}

