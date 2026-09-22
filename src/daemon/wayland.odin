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

// Copy (incoming): selection monitoring (push to recency registers).
// This is what an application is offering us. We only store the mimes advertised from it; data is not read until the
// debounce fires because many of these offers will be superseded before they commit.
Offer_State :: struct {
    handle: Data_Control_Offer,
    mimes:  []string, // Transferred from `advertised_mimes` upon selection event
    staged: bool, // Check whether we are in a debounce window
}

// Paste (outgoing): selection writing (setting clipboard/primary for paste).
// This is what we advertise while we own the selection.
Source_State :: struct {
    handle: Data_Control_Source,
    reprs:  []lib.Data_Repr,
}

Selection_State :: struct {
    offer:  Offer_State,
    source: Source_State,
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
    // Accumulates mimes from an offer's repeated "offer" events and pass to selection/primary_selection event
    advertised_mimes:          [dynamic]string,
}

X11_State :: struct {}

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

wayland_cleanup_offer :: proc(offer: ^Offer_State) {
    if offer.handle != nil {data_control_offer_v1_destroy_wrapper(offer.handle)}
    offer.handle = nil
    wayland_clear_offer_mimes(offer)
}

// Free just the staged mime names, leaving the handle alone. Staging a replacement offer needs this rather than
// `wayland_cleanup_offer`, which would destroy the handle it is about to use.
wayland_clear_offer_mimes :: proc(offer: ^Offer_State) {
    for mime in offer.mimes {delete(mime)}
    delete(offer.mimes)
    offer.mimes = nil
}

wayland_cleanup_source :: proc(source: ^Source_State) {
    if source.handle != nil {data_control_source_v1_destroy_wrapper(source.handle)}
    source.handle = nil
    lib.free_data_reprs(source.reprs)
    source.reprs = nil
}

wayland_cleanup_selection :: proc(selection: ^Selection_State) {
    wayland_cleanup_offer(&selection.offer)
    wayland_cleanup_source(&selection.source)
}

// Destroy in reverse order of creation, children before parents
wayland_cleanup :: proc(wl_state: ^Wayland_State) {
    wayland_cleanup_selection(&wl_state.clipboard_state)
    wayland_cleanup_selection(&wl_state.primary_state)
    for mime in wl_state.advertised_mimes {delete(mime)}
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
    // Freed by `wayland_stage_selection` or `wayland_cleanup`.
    mime := strings.clone_from_cstring(mime_type_)
    // Nothing forbids a compositor advertising the same mime twice so dedup.
    for existing in wl_state.advertised_mimes {
        if existing == mime {
            delete(mime)
            return
        }
    }
    append(&wl_state.advertised_mimes, mime)
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
    case wl_state.clipboard_state.source.handle:
        log.debugf(logstr, protostr, "clipboard")
        wayland_send_source(&wl_state.clipboard_state, string(mime_type_), cast(linux.Fd)fd_)
    case wl_state.primary_state.source.handle:
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
    case wl_state.clipboard_state.source.handle:
        log.debugf(logstr, protostr, "clipboard")
        wayland_cleanup_source(&wl_state.clipboard_state.source)
    case wl_state.primary_state.source.handle:
        log.debugf(logstr, protostr, "primary")
        wayland_cleanup_source(&wl_state.primary_state.source)
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
    if selection.offer.handle != nil {
        data_control_offer_v1_destroy_wrapper(selection.offer.handle)
    }
    selection.offer.handle = id_

    // Move the accumulated names onto this selection. Ownership transfers rather than being cloned.
    wayland_clear_offer_mimes(&selection.offer)
    selection.offer.mimes = make([]string, len(wl_state.advertised_mimes))
    for mime, i in wl_state.advertised_mimes {
        selection.offer.mimes[i] = mime
    }
    clear(&wl_state.advertised_mimes)
    selection.offer.staged = true
}

reprs_are_equal :: proc(a: []lib.Data_Repr, b: []lib.Data_Repr) -> bool {
    if len(a) != len(b) {return false}
    for repr, i in a {
        if len(repr.mimes) != len(b[i].mimes) {return false}
        for mime, j in repr.mimes {
            if mime != b[i].mimes[j] {return false}
        }
        if !slice.equal(repr.data, b[i].data) {return false}
    }
    return true
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

    offer := selection.offer.handle
    if offer == nil {return false}

    reprs: []lib.Data_Repr
    // Check if this selection event was triggered by clipbender setting the clipboard/primary, this means we still
    // have ownership of the clipboard at this point. In these scenarios, the sequence of events is:
    // 1. Set clipboard/primary with register e.g. `clipbender set selection a`
    // 2. Daemon sets the clipboard selection to register `a` (clipbender takes ownership of clipboard)
    // 3. We set the cached clipboard selection source to this one
    // 4. Compositor echoes a selection event and we arrive back here
    //
    // If we didn't have this check, we would try to read the data offer and timeout because we would also have to be
    // the one sending it (in `wayland_read_offer_data()` the pipe read would time out waiting for us to write).
    self_source := false
    if selection.source.handle != nil {
        // Reuse the reprs from our own cache to give to the register
        reprs = selection.source.reprs
        self_source = true
    } else {
        reprs = wayland_read_offer_reprs(wl_state, offer, selection.offer.mimes)
        if len(reprs) == 0 {
            log.errorf("No usable representations from debounced %v offer", type)
            return false
        }
    }

    // Update only timestamp of cached live selection if duplicate, otherwise replace it.
    live_selection := get_live_selection(store, type)
    if live_selection != nil && reprs_are_equal(live_selection.reprs, reprs) {
        bump_live_selection(store, type)
    } else {
        // The live selection owns its copy: it and the recency head are independent entries with independent lifetimes.
        cloned_reprs := lib.clone_data_reprs(reprs)
        set_live_selection(store, type, cloned_reprs)
    }

    // Deduplicate: don't push if identical to the most recent entry
    head_reg := get_recency_reg(store, type, 0)
    if head_reg != nil && reprs_are_equal(head_reg.reprs, reprs) {
        log.debugf("Got duplicate %v copy, suppressing register push", type)
        if !self_source {
            lib.free_data_reprs(reprs)
        }
        return false
    }

    // Clone if the reprs belong to our own cached source, which keeps ownership of them.
    self_source_str := ""
    if self_source {
        reprs = lib.clone_data_reprs(reprs)
        self_source_str = " (self-source)"
    }
    // Ownership of reprs transferred
    push_recency_reg(store, type, reprs)
    log.infof("Pushed to %v recency register%s", type, self_source_str)
    return true
}

// Read every advertised mime and coalesce the ones that produced identical bytes into a single repr. Costs a pipe round
// trip for every mime advertised. Mime order is preserved, so the first repr holds whatever the app advertised first
// (its own preference signal).
wayland_read_offer_reprs :: proc(
    wl_state: ^Wayland_State,
    offer: Data_Control_Offer,
    mimes: []string,
) -> []lib.Data_Repr {
    reprs := make([dynamic]lib.Data_Repr, 0, len(mimes))

    for mime in mimes {
        // The one boundary where an application's arbitrary string becomes ours, make sure it's under the limit.
        if len(mime) > lib.MAX_MIME_LEN {
            log.warnf("Offered mime is %d bytes, over the %d limit; skipping it", len(mime), lib.MAX_MIME_LEN)
            continue
        }

        // Returns copied data
        data := wayland_read_offer_data(offer, wl_state.display, mime)
        if data == nil {
            log.warnf("Couldn't read `%s` from offer, skipping that representation", mime)
            continue
        }

        // Fold into an existing repr when the bytes match one already read. Manually realloc since coalescing is
        // probably not _super_ common.
        duplicate := false
        for &repr in reprs {
            if slice.equal(repr.data, data) {
                names := make([]string, len(repr.mimes) + 1)
                copy(names, repr.mimes)
                names[len(repr.mimes)] = strings.clone(mime)
                delete(repr.mimes)
                repr.mimes = names
                delete(data)
                duplicate = true
                log.debugf("Found duplicate data for mime `%s`", mime)
                break
            }
        }
        if duplicate {continue}     // Don't append to reprs list if duplicate

        // This is a new repr, so it'll start with a new mime list of length 1 which includes the new unique mime.
        new_mime_slice := make([]string, 1)
        new_mime_slice[0] = strings.clone(mime)
        append(&reprs, lib.Data_Repr{data = data, mimes = new_mime_slice})
    }

    return reprs[:]
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

    return read_pipe_blob(read_fd, mime)
}

READ_TIMEOUT_MS :: 2000 // 2s

// Drain `read_fd` to EOF and return the bytes, or nil on timeout, read error, empty payload, or a source that exceeds
// `MAX_READ_SIZE`. Closes `read_fd`.
read_pipe_blob :: proc(read_fd: linux.Fd, mime: string) -> []u8 {
    // Ensure fd is closed.
    defer linux.close(read_fd)

    // Wait for source app to write data, with timeout to avoid blocking forever on hung apps. Polled before every read.
    poll_fds := [1]linux.Poll_Fd{{fd = read_fd, events = {.IN}}}

    // Read all data from pipe until EOF, or until the source exceeds what we are willing to hold. Discard rather than
    // truncate because a half-read blob is not a representation of anything.
    result: [dynamic]byte
    for {
        // Poll the FD
        poll_ret, poll_err := linux.poll(poll_fds[:], READ_TIMEOUT_MS)
        if poll_err != .NONE || poll_ret <= 0 {
            log.errorf("Timed out waiting for source app to write mime `%s`: errno %v", mime, poll_err)
            delete(result)
            return nil
        }

        // Read straight into the tail rather than staging through a scratch buffer, then trim to what actually arrived.
        old := len(result)
        resize(&result, old + lib.PIPE_READ_SIZE)
        num_bytes, err := linux.read(read_fd, result[old:])
        if err != .NONE {     // boooo :(
            log.errorf("Failed reading mime `%s` from source app: errno %v", mime, err)
            delete(result)
            return nil
        } else if num_bytes == 0 {     // EOF success!
            resize(&result, old) // discard the unfilled tail
            break
        }
        resize(&result, old + num_bytes)

        if len(result) > lib.MAX_READ_SIZE {
            log.errorf(
                "Source app wrote more than %d bytes for mime `%s`, discarding this representation",
                lib.MAX_READ_SIZE,
                mime,
            )
            delete(result)
            return nil
        }
    }

    if len(result) == 0 {
        delete(result)
        return nil
    }

    return result[:]
}

// ============================== Selection Writing (Paste) ==============================

wayland_set_selection :: proc(wl_state: ^Wayland_State, reprs: []lib.Data_Repr, type: lib.Selection_Type) {
    selection: ^Selection_State
    switch type {
    case .CLIPBOARD:
        selection = &wl_state.clipboard_state
    case .PRIMARY:
        selection = &wl_state.primary_state
    }

    // Cleanup any previous source set
    wayland_cleanup_source(&selection.source)

    // Take ownership of the reprs we will serve
    selection.source.reprs = reprs

    // Create new data source to advertise
    selection.source.handle = data_control_manager_v1_create_data_source_wrapper(wl_state.data_control_manager)
    if selection.source.handle == nil {
        log.error("Failed to create data control source")
        return
    }

    // Advertise every name we can serve, in stored order, so a requesting app sees the same preference the original
    // application expressed.
    for repr in reprs {
        for mime in repr.mimes {
            data_control_source_v1_offer_wrapper(
                selection.source.handle,
                strings.clone_to_cstring(mime, context.temp_allocator),
            )
        }
    }

    // Attach listener for send/cancelled events
    data_control_source_v1_add_listener_wrapper(selection.source.handle, rawptr(wl_state))

    // Set selection on device
    switch type {
    case .CLIPBOARD:
        data_control_device_v1_set_selection_wrapper(wl_state.data_control_device, selection.source.handle)
    case .PRIMARY:
        data_control_device_v1_set_primary_selection_wrapper(wl_state.data_control_device, selection.source.handle)
    }

    // Flush display
    wl.display_flush(wl_state.display)
    log.debugf("Set %v selection with %d representation(s)", type, len(reprs))
}

wayland_send_source :: proc(selection: ^Selection_State, mime_type: string, fd: linux.Fd) {
    // Serve whichever representation claims the requested name. We advertised every name across every repr, so a miss
    // means the compositor asked for something we never offered.
    for repr in selection.source.reprs {
        for mime in repr.mimes {
            if mime == mime_type {
                linux.write(fd, repr.data)
                linux.close(fd)
                return
            }
        }
    }

    log.errorf("Requested mime `%s` was never offered, this is unexpected", mime_type)
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
