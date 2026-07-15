package main

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sys/linux"

import lib "src:libclipbender"
import ext_dc "wayland:ext-data-control"
import wl "wayland:odin-wayland"
import wlr_dc "wayland:wlr-data-control"

// ============================== Constants ==============================

EXT_STR :: "ext_data_control"
WLR_STR :: "wlr_data_control"

// Preferred mime types in order of priority
PREFERRED_MIMES :: [?]string {
    "image/webp",
    "image/gif",
    "image/svg+xml",
    "image/png",
    "image/jpeg",
    "text/uri-list",
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
    "text/html",
    "text/css",
    "text/javascript",
    "text/markdown",
    "text/csv",
    "text/calendar",
}

// ============================== Types ==============================

// The data-control protocol objects are represented as tagged unions over the ext and wlr pointer variants. The
// compositor advertises one protocol or the other (ext preferred); the active variant is set once at bind time and
// stays constant for the connection. Protocol-specific requests are dispatched through the wrappers at the bottom.

Data_Control_Manager :: union {
    ^ext_dc.data_control_manager_v1,
    ^wlr_dc.data_control_manager_v1,
}

Data_Control_Device :: union {
    ^ext_dc.data_control_device_v1,
    ^wlr_dc.data_control_device_v1,
}

Data_Control_Offer :: union {
    ^ext_dc.data_control_offer_v1,
    ^wlr_dc.data_control_offer_v1,
}

Data_Control_Source :: union {
    ^ext_dc.data_control_source_v1,
    ^wlr_dc.data_control_source_v1,
}

Selection_State :: struct {
    // Copy: selection monitoring (push to recency registers)
    offer:       Data_Control_Offer,
    mimes:       map[string]struct{}, // Transferred from `advertised_mimes` upon selection event
    staged:      bool, // Check whether we are in a debounce window
    // Paste: selection writing (setting clipboard/primary for paste)
    source:      Data_Control_Source,
    source_data: []byte,
    source_mime: string,
}

Wayland_State :: struct {
    // General connection state
    display:                   ^wl.display,
    registry:                  ^wl.registry,
    seat:                      ^wl.seat,
    seat_name:                 uint,
    data_control_manager:      Data_Control_Manager,
    data_control_manager_name: uint,
    data_control_device:       Data_Control_Device,
    disabled:                  bool,
    // Selection state
    clipboard_state:           Selection_State,
    primary_state:             Selection_State,
    // Temporary set used to accumulate mimes from an offer and pass to selection/primary_selection event
    advertised_mimes:          map[string]struct{}, // map with zero-size value = hashset
}

// ============================== Connection Lifecycle ==============================

wayland_init :: proc(wl_state: ^Wayland_State) -> (ok: bool) {
    // Get display
    wl_state.display = wl.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if wl_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return false
    }

    // Get registry
    wl_state.registry = wl.display_get_registry(wl_state.display)
    wl.registry_add_listener(wl_state.registry, &registry_listener, wl_state)

    // Roundtrip to receive registry events (binds seat and data_control_manager)
    wl.display_roundtrip(wl_state.display)
    if wl_state.seat == nil {
        log.error("Failed to bind Wayland seat")
        return false
    }
    if wl_state.data_control_manager == nil {
        log.error("Failed to bind Wayland data_control_manager, didn't find ext_data_control nor wlr_data_control")
        return false
    }

    // Get data_control_device
    wl_state.data_control_device = data_control_manager_v1_get_data_device_wrapper(
        wl_state.data_control_manager,
        wl_state.seat,
    )
    if wl_state.data_control_device == nil {
        log.error("Failed to get Wayland data_control_device, ran out of memory?")
        return false
    }
    data_control_device_v1_add_listener_wrapper(wl_state.data_control_device, wl_state)

    // Roundtrip to receive initial selection state
    wl.display_roundtrip(wl_state.display)

    return true
}

wayland_cleanup_source :: proc(selection: ^Selection_State) {
    if selection.source != nil {data_control_source_v1_destroy_wrapper(selection.source)}
    selection.source = nil
    delete(selection.source_data)
    selection.source_data = nil
    delete(selection.source_mime)
    selection.source_mime = ""
}

wayland_cleanup_selection :: proc(selection: ^Selection_State) {
    if selection.offer != nil {data_control_offer_v1_destroy_wrapper(selection.offer)}
    selection.offer = nil
    wayland_cleanup_source(selection)
    for mime in selection.mimes {delete(mime)}
    delete(selection.mimes)
    selection.mimes = {}
}

// Destroy in reverse order of creation, children before parents
wayland_cleanup :: proc(wl_state: ^Wayland_State) {
    wayland_cleanup_selection(&wl_state.clipboard_state)
    wayland_cleanup_selection(&wl_state.primary_state)
    delete(wl_state.advertised_mimes)

    // Cleanup connection state
    if wl_state.data_control_device != nil {data_control_device_v1_destroy_wrapper(wl_state.data_control_device)}
    if wl_state.data_control_manager != nil {data_control_manager_v1_destroy_wrapper(wl_state.data_control_manager)}
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

// ============================== Registry Listener ==============================

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
        case "zwlr_data_control_manager_v1":
            // If we already assigned ext_data_control, don't replace it with wlr_data_control
            if wl_state.data_control_manager != nil {
                log.debugf("Wayland interface `%s` was found but ext_data_control is in-use and preferred", interface_)
                return
            }
            wl_state.data_control_manager = cast(^wlr_dc.data_control_manager_v1)wl.registry_bind(
                registry,
                name_,
                &wlr_dc.data_control_manager_v1_interface,
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

// ============================== Device Listener ==============================
// Shared handlers take the union types; the per-protocol ext/wlr listener structs are thin adapters that forward the
// concrete pointers into them.

device_listener_data_offer :: proc "c" (
    data: rawptr,
    data_control_device_v1: Data_Control_Device,
    id_: Data_Control_Offer,
) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_device::data_offer event"
    // Attach offer listener to collect MIME types
    switch device in data_control_device_v1 {
    case ^ext_dc.data_control_device_v1:
        log.debugf(logstr, EXT_STR)
        ext_dc.data_control_offer_v1_add_listener(id_.(^ext_dc.data_control_offer_v1), &ext_offer_listener, wl_state)
    case ^wlr_dc.data_control_device_v1:
        log.debugf(logstr, WLR_STR)
        wlr_dc.data_control_offer_v1_add_listener(id_.(^wlr_dc.data_control_offer_v1), &wlr_offer_listener, wl_state)
    }
}

device_listener_selection :: proc "c" (
    data: rawptr,
    data_control_device_v1: Data_Control_Device,
    id_: Data_Control_Offer,
) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_device::selection event"
    switch device in data_control_device_v1 {
    case ^ext_dc.data_control_device_v1:
        log.debugf(logstr, EXT_STR)
    case ^wlr_dc.data_control_device_v1:
        log.debugf(logstr, WLR_STR)
    }
    wayland_stage_selection(wl_state, &wl_state.clipboard_state, id_)
}

device_listener_finished :: proc "c" (data: rawptr, data_control_device_v1: Data_Control_Device) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_device::finished event, disabling clipboard monitoring"
    switch device in data_control_device_v1 {
    case ^ext_dc.data_control_device_v1:
        log.debugf(logstr, EXT_STR)
    case ^wlr_dc.data_control_device_v1:
        log.debugf(logstr, WLR_STR)
    }
    wl_state.disabled = true
}

device_listener_primary_selection :: proc "c" (
    data: rawptr,
    data_control_device_v1: Data_Control_Device,
    id_: Data_Control_Offer,
) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_device::primary_selection event"
    switch device in data_control_device_v1 {
    case ^ext_dc.data_control_device_v1:
        log.debugf(logstr, EXT_STR)
    case ^wlr_dc.data_control_device_v1:
        log.debugf(logstr, WLR_STR)
    }
    wayland_stage_selection(wl_state, &wl_state.primary_state, id_)
}

ext_device_listener := ext_dc.data_control_device_v1_listener {
    data_offer = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        device_listener_data_offer(data, data_control_device_v1, id_)
    },
    selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        device_listener_selection(data, data_control_device_v1, id_)
    },
    finished = proc "c" (data: rawptr, data_control_device_v1: ^ext_dc.data_control_device_v1) {
        device_listener_finished(data, data_control_device_v1)
    },
    primary_selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        device_listener_primary_selection(data, data_control_device_v1, id_)
    },
}

wlr_device_listener := wlr_dc.data_control_device_v1_listener {
    data_offer = proc "c" (
        data: rawptr,
        data_control_device_v1: ^wlr_dc.data_control_device_v1,
        id_: ^wlr_dc.data_control_offer_v1,
    ) {
        device_listener_data_offer(data, data_control_device_v1, id_)
    },
    selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^wlr_dc.data_control_device_v1,
        id_: ^wlr_dc.data_control_offer_v1,
    ) {
        device_listener_selection(data, data_control_device_v1, id_)
    },
    finished = proc "c" (data: rawptr, data_control_device_v1: ^wlr_dc.data_control_device_v1) {
        device_listener_finished(data, data_control_device_v1)
    },
    primary_selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^wlr_dc.data_control_device_v1,
        id_: ^wlr_dc.data_control_offer_v1,
    ) {
        device_listener_primary_selection(data, data_control_device_v1, id_)
    },
}

// ============================== Offer Listener (Copy events) ==============================

offer_listener_offer :: proc "c" (data: rawptr, data_control_offer_v1: Data_Control_Offer, mime_type_: cstring) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_offer::offer event (mime: %s)"
    switch offer in data_control_offer_v1 {
    case ^ext_dc.data_control_offer_v1:
        log.debugf(logstr, EXT_STR, mime_type_)
    case ^wlr_dc.data_control_offer_v1:
        log.debugf(logstr, WLR_STR, mime_type_)
    }
    wl_state.advertised_mimes[strings.clone_from_cstring(mime_type_, context.temp_allocator)] = {}
}

ext_offer_listener := ext_dc.data_control_offer_v1_listener {
    offer = proc "c" (data: rawptr, data_control_offer_v1: ^ext_dc.data_control_offer_v1, mime_type_: cstring) {
        offer_listener_offer(data, data_control_offer_v1, mime_type_)
    },
}

wlr_offer_listener := wlr_dc.data_control_offer_v1_listener {
    offer = proc "c" (data: rawptr, data_control_offer_v1: ^wlr_dc.data_control_offer_v1, mime_type_: cstring) {
        offer_listener_offer(data, data_control_offer_v1, mime_type_)
    },
}

// ============================== Source Listener (Paste events) ==============================

source_listener_send :: proc "c" (
    data: rawptr,
    data_control_source_v1: Data_Control_Source,
    mime_type_: cstring,
    fd_: int,
) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_source::send event (%s)"
    protostr := EXT_STR
    if _, is_wlr := data_control_source_v1.(^wlr_dc.data_control_source_v1); is_wlr {protostr = WLR_STR}
    switch data_control_source_v1 {
    case wl_state.clipboard_state.source:
        log.debugf(logstr, protostr, "clipboard")
        wayland_send_source(&wl_state.clipboard_state, string(mime_type_), cast(linux.Fd)fd_)
    case wl_state.primary_state.source:
        log.debugf(logstr, protostr, "primary")
        wayland_send_source(&wl_state.primary_state, string(mime_type_), cast(linux.Fd)fd_)
    }
}

source_listener_cancelled :: proc "c" (data: rawptr, data_control_source_v1: Data_Control_Source) {
    context = runtime.default_context()
    context.logger = _logger
    wl_state := cast(^Wayland_State)data

    logstr := "Received %s_source::cancelled event (%s)"
    protostr := EXT_STR
    if _, is_wlr := data_control_source_v1.(^wlr_dc.data_control_source_v1); is_wlr {protostr = WLR_STR}
    switch data_control_source_v1 {
    case wl_state.clipboard_state.source:
        log.debugf(logstr, protostr, "clipboard")
        wayland_cleanup_source(&wl_state.clipboard_state)
    case wl_state.primary_state.source:
        log.debugf(logstr, protostr, "primary")
        wayland_cleanup_source(&wl_state.primary_state)
    }
}

ext_source_listener := ext_dc.data_control_source_v1_listener {
    send = proc "c" (
        data: rawptr,
        data_control_source_v1: ^ext_dc.data_control_source_v1,
        mime_type_: cstring,
        fd_: int,
    ) {
        source_listener_send(data, data_control_source_v1, mime_type_, fd_)
    },
    cancelled = proc "c" (data: rawptr, data_control_source_v1: ^ext_dc.data_control_source_v1) {
        source_listener_cancelled(data, data_control_source_v1)
    },
}

wlr_source_listener := wlr_dc.data_control_source_v1_listener {
    send = proc "c" (
        data: rawptr,
        data_control_source_v1: ^wlr_dc.data_control_source_v1,
        mime_type_: cstring,
        fd_: int,
    ) {
        source_listener_send(data, data_control_source_v1, mime_type_, fd_)
    },
    cancelled = proc "c" (data: rawptr, data_control_source_v1: ^wlr_dc.data_control_source_v1) {
        source_listener_cancelled(data, data_control_source_v1)
    },
}

// ============================== Selection Monitoring (Copy) ==============================

// Stage a selection event for debounced processing. Stores the offer and mimes, sets the pending flag.
wayland_stage_selection :: proc(wl_state: ^Wayland_State, selection: ^Selection_State, id_: Data_Control_Offer) {
    if id_ == nil {
        log.debug("Received offer is nil (selection was cleared)")
        return
    }

    // Destroy previous pending offer if replacing (debounce reset)
    if selection.offer != nil {
        data_control_offer_v1_destroy_wrapper(selection.offer)
    }
    selection.offer = id_

    // Snapshot advertised mimes into this selection's state
    for mime in selection.mimes {delete(mime)}
    clear(&selection.mimes)
    for mime in wl_state.advertised_mimes {
        selection.mimes[strings.clone(mime)] = {}
    }
    clear(&wl_state.advertised_mimes)
    selection.staged = true
}

// Called when a debounce timer successfully expires. Reads the pending offer and pushes to recency ring.
// Returns true if it pushed a new entry to the recency ring (a persistable mutation), false otherwise.
wayland_commit_selection :: proc(
    wl_state: ^Wayland_State,
    store: ^Register_Store,
    type: lib.Selection_Type,
) -> (
    pushed: bool,
) {
    selection: ^Selection_State
    switch type {
    case .CLIPBOARD:
        selection = &wl_state.clipboard_state
    case .PRIMARY:
        selection = &wl_state.primary_state
    }

    offer := selection.offer
    if offer == nil {return false}

    data: []u8
    mime: string
    // Check if this selection event was triggered by clipbender setting the clipboard/primary, this means we still
    // have ownership of the clipboard at this point. In these scenarios, the sequence of events is:
    // 1. Set clipboard/primary with register e.g. `clipbender set clipboard a`
    // 2. Daemon sets the clipboard selection to register `a` (clipbender takes ownership of clipboard)
    // 3. We set the cached clipboard selection source to this one
    // 4. Compositor echoes a selection event and we arrive back here
    //
    // If we didn't have this check, we would try to read the data offer and timeout because we would also have to be
    // the one sending it (in `wayland_read_offer_data()` the pipe read would time out waiting for us to write).
    self_source := false
    if selection.source != nil {
        // Reuse the data from our own cache to give to the register
        data = selection.source_data
        mime = selection.source_mime
        self_source = true
    } else {
        // Allocates mime
        mime = pick_best_mime(selection.mimes)
        if mime == "" {
            log.errorf("No mime found for debounced %v selection, canceling push to recency register", type)
            return false
        }

        // Allocates data
        data = wayland_read_offer_data(offer, wl_state.display, mime)
        if data == nil {
            log.errorf("Couldn't read data from debounced %v offer", type)
            delete(mime)
            return false
        }
    }

    // Update only timestamp of cached live selection if duplicate, otherwise update the cached live selection.
    live_selection := get_live_selection(store, type)
    if live_selection != nil && live_selection.mime_type == mime && slice.equal(live_selection.data, data) {
        bump_live_selection(store, type)
    } else {
        // Clone data and mime since recency reg push takes ownership.
        set_live_selection(store, type, slice.clone(data), strings.clone(mime))
    }

    // Deduplicate: don't push if identical to the most recent entry, but bump the live selection's timestamp
    head_reg := get_recency_reg(store, type, 0)
    if head_reg != nil && head_reg.mime_type == mime && slice.equal(head_reg.data, data) {
        log.debugf("Got duplicate %v copy, suppressing register push", type)
        if !self_source {
            delete(data)
            delete(mime)
        }
        return false
    }

    // Clone the data if it's pointing at our owned selection.
    self_source_str := ""
    if self_source {
        data, mime = slice.clone(data), strings.clone(mime)
        self_source_str = " (self-source)"
    }
    // Ownership of data and mime transferred
    push_recency_reg(store, type, data, mime)
    data, mime = {}, {}
    log.infof("Pushed to %v recency register%s", type, self_source_str)
    return true
}

// Pick the highest-priority mime type, fall back to any available if none match.
// Caller is responsible for cleaning up the returned string.
pick_best_mime :: proc(avail_mimes: map[string]struct{}) -> string {
    if len(avail_mimes) == 0 {return ""}
    for preferred in PREFERRED_MIMES {
        if preferred in avail_mimes {
            return strings.clone(preferred)
        }
    }

    for avail in avail_mimes {
        log.infof("No offered mime types matched preferred mimes, using offered mime: %s", avail)
        return strings.clone(avail)
    }

    // Unreachable since we check empty `avail_mimes` at the start of the function
    unreachable()
}

// Caller is responsible for freeing returned data
wayland_read_offer_data :: proc(offer: Data_Control_Offer, display: ^wl.display, mime: string) -> []u8 {
    // Create pipe
    pipe_fds: [2]linux.Fd
    if linux.pipe2(&pipe_fds, {.CLOEXEC}) != nil {
        log.error("Failed to create pipe for data offer read")
        return nil
    }

    read_fd := pipe_fds[0]
    write_fd := pipe_fds[1]

    // Ask source to write data to our pipe
    data_control_offer_v1_receive_wrapper(offer, strings.clone_to_cstring(mime, context.temp_allocator), int(write_fd))
    linux.close(write_fd)
    wl.display_flush(display)

    // Wait for source app to write data, with timeout to avoid blocking forever on hung apps
    poll_fds := [1]linux.Poll_Fd{{fd = read_fd, events = {.IN}}}
    timeout: i32 = 2000 // 2s timeout
    poll_ret, poll_err := linux.poll(poll_fds[:], timeout)
    if poll_err != .NONE || poll_ret <= 0 {
        log.errorf("Timed out waiting for source app to write clipboard data: errno %v", poll_err)
        linux.close(read_fd)
        return nil
    }

    // Read all data from pipe until EOF
    buf: [4096]byte
    result: [dynamic]byte
    for {
        num_bytes, err := linux.read(read_fd, buf[:])
        if err != .NONE || num_bytes <= 0 {break}
        append(&result, ..buf[:num_bytes])
    }
    linux.close(read_fd)

    if len(result) == 0 {
        delete(result)
        return nil
    }

    return result[:]
}

// ============================== Selection Writing (Paste) ==============================

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

    // Take ownership of data + mime
    selection.source_data = data
    selection.source_mime = mime

    // Create new data source to advertise
    selection.source = data_control_manager_v1_create_data_source_wrapper(wl_state.data_control_manager)
    if selection.source == nil {
        log.error("Failed to create data control source")
        return
    }

    // Offer mime type
    data_control_source_v1_offer_wrapper(selection.source, strings.clone_to_cstring(mime, context.temp_allocator))

    // Attach listener for send/cancelled events
    data_control_source_v1_add_listener_wrapper(selection.source, rawptr(wl_state))

    // Set selection on device
    switch type {
    case .CLIPBOARD:
        data_control_device_v1_set_selection_wrapper(wl_state.data_control_device, selection.source)
    case .PRIMARY:
        data_control_device_v1_set_primary_selection_wrapper(wl_state.data_control_device, selection.source)
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

// ============================== Protocol Wrappers ==============================
// Each wrapper dispatches a union to the concrete ext/wlr request with identical arguments. The manager is guaranteed
// non-nil past init (checked in wayland_init), so wrappers that need a return value use #partial switch + unreachable().

data_control_manager_v1_get_data_device_wrapper :: proc "contextless" (
    data_control_manager_v1_: Data_Control_Manager,
    seat_: ^wl.seat,
) -> Data_Control_Device {
    #partial switch manager in data_control_manager_v1_ {
    case ^ext_dc.data_control_manager_v1:
        return ext_dc.data_control_manager_v1_get_data_device(manager, seat_)
    case ^wlr_dc.data_control_manager_v1:
        return wlr_dc.data_control_manager_v1_get_data_device(manager, seat_)
    }
    unreachable()
}

data_control_manager_v1_create_data_source_wrapper :: proc "contextless" (
    data_control_manager_v1_: Data_Control_Manager,
) -> Data_Control_Source {
    #partial switch manager in data_control_manager_v1_ {
    case ^ext_dc.data_control_manager_v1:
        return ext_dc.data_control_manager_v1_create_data_source(manager)
    case ^wlr_dc.data_control_manager_v1:
        return wlr_dc.data_control_manager_v1_create_data_source(manager)
    }
    unreachable()
}

data_control_manager_v1_destroy_wrapper :: proc "contextless" (data_control_manager_v1_: Data_Control_Manager) {
    switch manager in data_control_manager_v1_ {
    case ^ext_dc.data_control_manager_v1:
        ext_dc.data_control_manager_v1_destroy(manager)
    case ^wlr_dc.data_control_manager_v1:
        wlr_dc.data_control_manager_v1_destroy(manager)
    }
}

data_control_device_v1_add_listener_wrapper :: proc "contextless" (
    data_control_device_v1_: Data_Control_Device,
    data: rawptr,
) {
    switch device in data_control_device_v1_ {
    case ^ext_dc.data_control_device_v1:
        ext_dc.data_control_device_v1_add_listener(device, &ext_device_listener, data)
    case ^wlr_dc.data_control_device_v1:
        wlr_dc.data_control_device_v1_add_listener(device, &wlr_device_listener, data)
    }
}

// The device and source are always the same protocol (source was created from the same manager as the device),
// so the two-value type assertion always succeeds; it just avoids the panic path of the single-value form.
data_control_device_v1_set_selection_wrapper :: proc "contextless" (
    data_control_device_v1_: Data_Control_Device,
    data_control_source_v1_: Data_Control_Source,
) {
    switch device in data_control_device_v1_ {
    case ^ext_dc.data_control_device_v1:
        source, _ := data_control_source_v1_.(^ext_dc.data_control_source_v1)
        ext_dc.data_control_device_v1_set_selection(device, source)
    case ^wlr_dc.data_control_device_v1:
        source, _ := data_control_source_v1_.(^wlr_dc.data_control_source_v1)
        wlr_dc.data_control_device_v1_set_selection(device, source)
    }
}

data_control_device_v1_set_primary_selection_wrapper :: proc "contextless" (
    data_control_device_v1_: Data_Control_Device,
    data_control_source_v1_: Data_Control_Source,
) {
    switch device in data_control_device_v1_ {
    case ^ext_dc.data_control_device_v1:
        source, _ := data_control_source_v1_.(^ext_dc.data_control_source_v1)
        ext_dc.data_control_device_v1_set_primary_selection(device, source)
    case ^wlr_dc.data_control_device_v1:
        source, _ := data_control_source_v1_.(^wlr_dc.data_control_source_v1)
        wlr_dc.data_control_device_v1_set_primary_selection(device, source)
    }
}

data_control_device_v1_destroy_wrapper :: proc "contextless" (data_control_device_v1_: Data_Control_Device) {
    switch device in data_control_device_v1_ {
    case ^ext_dc.data_control_device_v1:
        ext_dc.data_control_device_v1_destroy(device)
    case ^wlr_dc.data_control_device_v1:
        wlr_dc.data_control_device_v1_destroy(device)
    }
}

data_control_offer_v1_receive_wrapper :: proc "contextless" (
    data_control_offer_v1_: Data_Control_Offer,
    mime_type_: cstring,
    fd_: int,
) {
    switch offer in data_control_offer_v1_ {
    case ^ext_dc.data_control_offer_v1:
        ext_dc.data_control_offer_v1_receive(offer, mime_type_, fd_)
    case ^wlr_dc.data_control_offer_v1:
        wlr_dc.data_control_offer_v1_receive(offer, mime_type_, fd_)
    }
}

data_control_offer_v1_destroy_wrapper :: proc "contextless" (data_control_offer_v1_: Data_Control_Offer) {
    switch offer in data_control_offer_v1_ {
    case ^ext_dc.data_control_offer_v1:
        ext_dc.data_control_offer_v1_destroy(offer)
    case ^wlr_dc.data_control_offer_v1:
        wlr_dc.data_control_offer_v1_destroy(offer)
    }
}

data_control_source_v1_offer_wrapper :: proc "contextless" (
    data_control_source_v1_: Data_Control_Source,
    mime_type_: cstring,
) {
    switch source in data_control_source_v1_ {
    case ^ext_dc.data_control_source_v1:
        ext_dc.data_control_source_v1_offer(source, mime_type_)
    case ^wlr_dc.data_control_source_v1:
        wlr_dc.data_control_source_v1_offer(source, mime_type_)
    }
}

data_control_source_v1_add_listener_wrapper :: proc "contextless" (
    data_control_source_v1_: Data_Control_Source,
    data: rawptr,
) {
    switch source in data_control_source_v1_ {
    case ^ext_dc.data_control_source_v1:
        ext_dc.data_control_source_v1_add_listener(source, &ext_source_listener, data)
    case ^wlr_dc.data_control_source_v1:
        wlr_dc.data_control_source_v1_add_listener(source, &wlr_source_listener, data)
    }
}

data_control_source_v1_destroy_wrapper :: proc "contextless" (data_control_source_v1_: Data_Control_Source) {
    switch source in data_control_source_v1_ {
    case ^ext_dc.data_control_source_v1:
        ext_dc.data_control_source_v1_destroy(source)
    case ^wlr_dc.data_control_source_v1:
        wlr_dc.data_control_source_v1_destroy(source)
    }
}
