package main

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sys/linux"

import lib "libclipbender:base"
import ext_dc "wayland:ext-data-control"
import wl "wayland:odin-wayland"

// Preferred mime types in order of priority
PREFERRED_MIMES :: [?]string {
    "image/webp",
    "image/gif",
    "image/svg+xml",
    "image/png",
    "image/jpeg",
    "text/uri-list",
    "text/html",
    "text/css",
    "text/javascript",
    "text/markdown",
    "text/csv",
    "text/calendar",
    "text/plain;charset=utf-8",
    "text/plain",
}

Selection_State :: struct {
    // Copy: selection monitoring (push to recency registers)
    offer:       ^ext_dc.data_control_offer_v1,
    // Paste: selection writing (setting clipboard/primary for paste)
    source:      ^ext_dc.data_control_source_v1,
    source_data: []byte,
    source_mime: string,
}

Wayland_State :: struct {
    // General connection state
    display:                   ^wl.display,
    registry:                  ^wl.registry,
    seat:                      ^wl.seat,
    seat_name:                 uint,
    data_control_manager:      ^ext_dc.data_control_manager_v1,
    data_control_manager_name: uint,
    data_control_device:       ^ext_dc.data_control_device_v1,
    disabled:                  bool,
    // Selection state
    clipboard_state:           Selection_State,
    primary_state:             Selection_State,
    // Temporary set used to accumulate mimes from an offer and pass to selection/primary_selection event
    advertised_mimes:          map[string]struct{}, // map with zero-size value = hashset
}

wayland_init :: proc() -> Wayland_State {
    wl_state: Wayland_State

    // Get display
    wl_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if wl_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return {}
    }

    // Get registry
    wl_state.registry = wl.display_get_registry(wl_state.display)
    wl.registry_add_listener(wl_state.registry, &registry_listener, &wl_state)

    // Roundtrip to receive registry events (binds seat and data_control_manager)
    wl.display_roundtrip(wl_state.display)
    if wl_state.seat == nil {
        log.error("Failed to bind Wayland seat")
        return {}
    }
    if wl_state.data_control_manager == nil {
        log.error("Failed to bind Wayland data_control_manager")
        return {}
    }

    // Get data_control_device
    wl_state.data_control_device = ext_dc.data_control_manager_v1_get_data_device(
        wl_state.data_control_manager,
        wl_state.seat,
    )
    if wl_state.data_control_device == nil {
        log.error("Failed to get Wayland data_control_device, ran out of memory?")
        return {}
    }
    ext_dc.data_control_device_v1_add_listener(wl_state.data_control_device, &device_listener, &wl_state)

    // Roundtrip to receive initial selection state
    wl.display_roundtrip(wl_state.display)

    return wl_state
}

// Destroy in reverse order of creation, children before parents
wayland_cleanup :: proc(wl_state: ^Wayland_State) {
    // Cleanup clipboard/primary states
    if wl_state.clipboard_state.offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.clipboard_state.offer)}
    wayland_cleanup_source(&wl_state.clipboard_state)
    if wl_state.primary_state.offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.primary_state.offer)}
    wayland_cleanup_source(&wl_state.primary_state)

    // Cleanup connection state
    if wl_state.data_control_device != nil {ext_dc.data_control_device_v1_destroy(wl_state.data_control_device)}
    if wl_state.data_control_manager != nil {ext_dc.data_control_manager_v1_destroy(wl_state.data_control_manager)}
    if wl_state.seat != nil {wl.seat_release(wl_state.seat)}
    wl.registry_destroy(wl_state.registry)
    wl.display_disconnect(wl_state.display)
}

wayland_get_fd :: proc(wl_state: ^Wayland_State) -> linux.Fd {
    return cast(linux.Fd)wl.display_get_fd(wl_state.display)
}

wayland_dispatch :: proc(wl_state: ^Wayland_State) -> (ok: bool) {
    if wl_state.disabled {return false}
    wl.display_flush(wl_state.display)
    wl.display_dispatch(wl_state.display)
    return !wl_state.disabled
}

registry_listener := wl.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            wl_state.seat = cast(^wl.seat)wl.registry_bind(registry, name_, &wl.seat_interface, 1)
            wl_state.seat_name = name_
        case "ext_data_control_manager_v1":
            wl_state.data_control_manager = cast(^ext_dc.data_control_manager_v1)wl.registry_bind(
                registry,
                name_,
                &ext_dc.data_control_manager_v1_interface,
                1,
            )
            wl_state.data_control_manager_name = name_
        case:
            return
        }
        log.debugf("Successfully bound Wayland interface `%s`", interface_)
    },
    global_remove = proc "c" (data: rawptr, registry: ^wl.registry, name_: uint) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data

        if name_ == wl_state.seat_name || name_ == wl_state.data_control_manager_name {
            interface: string
            switch name_ {
            case wl_state.seat_name:
                interface = "wl_seat"
            case wl_state.data_control_manager_name:
                interface = "ext_data_control_manager_v1"
            }
            log.errorf("Critical Wayland global removed `%s`, shutting down", interface)
            wl_state.disabled = true
        }
    },
}

device_listener := ext_dc.data_control_device_v1_listener {
    data_offer = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data
        log.debug("Received ext_data_control_device_v1::data_offer event")
        // Attach offer listener to collect MIME types
        ext_dc.data_control_offer_v1_add_listener(id_, &offer_listener, wl_state)
    },
    selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data
        log.debug("Received ext_data_control_device_v1::selection event")
        wayland_handle_selection(wl_state, id_, .CLIPBOARD)
    },
    finished = proc "c" (data: rawptr, data_control_device_v1: ^ext_dc.data_control_device_v1) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data
        log.debug("Received ext_data_control_device_v1::finished event, disabling clipboard monitoring")
        wl_state.disabled = true
    },
    primary_selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data
        log.debug("Received ext_data_control_device_v1::primary_selection event")
        wayland_handle_selection(wl_state, id_, .PRIMARY)
    },
}

// Copy events
offer_listener := ext_dc.data_control_offer_v1_listener {
    offer = proc "c" (data: rawptr, data_control_offer_v1: ^ext_dc.data_control_offer_v1, mime_type_: cstring) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data
        log.debugf("Received ext_data_control_offer_v1::offer event (mime: %s)", mime_type_)

        wl_state.advertised_mimes[strings.clone_from_cstring(mime_type_, context.temp_allocator)] = {}
    },
}

// Paste events
source_listener := ext_dc.data_control_source_v1_listener {
    send = proc "c" (
        data: rawptr,
        data_control_source_v1: ^ext_dc.data_control_source_v1,
        mime_type_: cstring,
        fd_: int,
    ) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data

        switch data_control_source_v1 {
        case wl_state.clipboard_state.source:
            log.debugf("Received ext_data_control_source_v1::send event (clipboard)")
            wayland_send_source(&wl_state.clipboard_state, string(mime_type_), cast(linux.Fd)fd_)
        case wl_state.primary_state.source:
            log.debugf("Received ext_data_control_source_v1::send event (primary)")
            wayland_send_source(&wl_state.primary_state, string(mime_type_), cast(linux.Fd)fd_)
        }
    },
    cancelled = proc "c" (data: rawptr, data_control_source_v1: ^ext_dc.data_control_source_v1) {
        context = runtime.default_context()
        context.logger = _logger
        wl_state := cast(^Wayland_State)data

        switch data_control_source_v1 {
        case wl_state.clipboard_state.source:
            log.debugf("Received ext_data_control_source_v1::cancelled event (clipboard)")
            wayland_cleanup_source(&wl_state.clipboard_state)
        case wl_state.primary_state.source:
            log.debugf("Received ext_data_control_source_v1::cancelled event (primary)")
            wayland_cleanup_source(&wl_state.primary_state)
        }
    },
}

wayland_handle_selection :: proc(
    wl_state: ^Wayland_State,
    id_: ^ext_dc.data_control_offer_v1,
    type: lib.Selection_Type,
) {
    if id_ == nil {
        log.debug("Received offer is nil (selection was cleared)")
        return
    }

    // Cleanup existing data offer if exists
    cached_offer: ^^ext_dc.data_control_offer_v1
    switch type {
    case .CLIPBOARD:
        cached_offer = &wl_state.clipboard_state.offer
    case .PRIMARY:
        cached_offer = &wl_state.primary_state.offer
    }
    if cached_offer^ != nil {ext_dc.data_control_offer_v1_destroy(cached_offer^)}
    cached_offer^ = id_

    mime := pick_best_mime(wl_state.advertised_mimes)
    if mime == "" {
        log.errorf("No mime found for copied %v selection, canceling push to recency register", type)
        return
    }

    data := wayland_read_offer_data(id_, wl_state.display, mime)
    if data == nil {
        log.error("Couldn't read the data from offer with mime type `%s`", mime)
        return
    }

    push_recency_reg(data, mime, type)
    delete(data)
    // Clear the pending mime map, we've consumed it and have already selected + copied our chosen mime type
    clear(&wl_state.advertised_mimes)
}

// Pick the highest-priority mime type, fall back to any available if none match
pick_best_mime :: proc(avail_mimes: map[string]struct{}) -> string {
    if len(avail_mimes) == 0 {return ""}
    for preferred in PREFERRED_MIMES {
        if preferred in avail_mimes {
            return preferred
        }
    }

    for avail in avail_mimes {
        log.infof("No offered mime types matched preferred mimes, using offered mime: %s", avail)
        return avail
    }

    // Unreachable since we check empty `avail_mimes` at the start of the function
    unreachable()
}

// Caller is responsible for freeing `data`
wayland_read_offer_data :: proc(offer: ^ext_dc.data_control_offer_v1, display: ^wl.display, mime: string) -> []u8 {
    // Create pipe
    pipe_fds: [2]linux.Fd
    if linux.pipe2(&pipe_fds, {.CLOEXEC}) != nil {
        log.error("Failed to create pipe for data offer read")
        return nil
    }

    read_fd := pipe_fds[0]
    write_fd := pipe_fds[1]

    // Ask source to write data to our pipe
    ext_dc.data_control_offer_v1_receive(offer, strings.clone_to_cstring(mime, context.temp_allocator), int(write_fd))
    linux.close(write_fd)
    wl.display_flush(display)

    // Read all data from pipe until EOF
    buf: [4096]byte
    result: [dynamic]byte
    for {
        num_bytes, err := linux.read(read_fd, buf[:])
        if err != nil || num_bytes <= 0 {break}
        append(&result, ..buf[:num_bytes])
    }
    linux.close(read_fd)

    if len(result) == 0 {
        delete(result)
        return nil
    }

    return result[:]
}

wayland_set_selection :: proc(wl_state: ^Wayland_State, data: []byte, mime: string, type: lib.Selection_Type) {
    selection: ^Selection_State
    switch type {
    case .CLIPBOARD:
        selection = &wl_state.clipboard_state
    case .PRIMARY:
        selection = &wl_state.primary_state
    }

    // Cleanup any previous source set
    wayland_cleanup_source(selection)

    // Clone data + mime to selection state
    selection.source_data = slice.clone(data)
    selection.source_mime = strings.clone(mime)

    // Create new data source to advertise
    selection.source = ext_dc.data_control_manager_v1_create_data_source(wl_state.data_control_manager)
    if selection.source == nil {
        log.error("Failed to create data control source")
        return
    }

    // Offer mime type
    ext_dc.data_control_source_v1_offer(selection.source, strings.clone_to_cstring(mime, context.temp_allocator))

    // Attach listener for send/cancelled events
    ext_dc.data_control_source_v1_add_listener(selection.source, &source_listener, rawptr(wl_state))

    // Set selection on device
    switch type {
    case .CLIPBOARD:
        ext_dc.data_control_device_v1_set_selection(wl_state.data_control_device, selection.source)
    case .PRIMARY:
        ext_dc.data_control_device_v1_set_primary_selection(wl_state.data_control_device, selection.source)
    }

    // Flush display
    wl.display_flush(wl_state.display)
    log.debugf("Set %v selection with mime `%s` (%d bytes)", type, mime, len(data))
}

wayland_send_source :: proc(selection: ^Selection_State, mime_type: string, fd: linux.Fd) {
    if mime_type != selection.source_mime {
        log.errorf(
            "Requested mime `%s` does not match offered mime `%s`, this is unexpected",
            mime_type,
            selection.source_mime,
        )
        return
    }
    linux.write(fd, selection.source_data)
    linux.close(fd)
}

wayland_cleanup_source :: proc(selection: ^Selection_State) {
    if selection.source != nil {ext_dc.data_control_source_v1_destroy(selection.source)}
    selection.source = nil
    delete(selection.source_data)
    selection.source_data = nil
    delete(selection.source_mime)
    selection.source_mime = ""
}

