package main

import "base:runtime"
import "core:log"
import "core:sys/linux"

import ext_dc "wayland:ext-data-control"
import wayland "wayland:odin-wayland"

Wayland_State :: struct {
    display:                   ^wayland.display,
    registry:                  ^wayland.registry,
    seat:                      ^wayland.seat,
    seat_name:                 uint,
    data_control_manager:      ^ext_dc.data_control_manager_v1,
    data_control_manager_name: uint,
    data_control_device:       ^ext_dc.data_control_device_v1,
    clipboard_offer:           ^ext_dc.data_control_offer_v1,
    primary_offer:             ^ext_dc.data_control_offer_v1,
    disabled:                  bool,
}

wayland_init :: proc() -> Wayland_State {
    wl_state: Wayland_State

    // Get display
    wl_state.display = wayland.display_connect(nil) // nil means connect to default $WAYLAND_DISPLAY or wayland-0 as fallback
    if wl_state.display == nil {
        log.error("Failed to connect to default Wayland display")
        return {}
    }

    // Get registry
    wl_state.registry = wayland.display_get_registry(wl_state.display)
    wayland.registry_add_listener(wl_state.registry, &registry_listener, &wl_state)

    // Roundtrip to receive registry events (binds seat and data_control_manager)
    wayland.display_roundtrip(wl_state.display)
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
    wayland.display_roundtrip(wl_state.display)

    return wl_state
}

// Destroy in reverse order of creation, children before parents
wayland_cleanup :: proc(wl_state: ^Wayland_State) {
    if wl_state.clipboard_offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.clipboard_offer)}
    if wl_state.primary_offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.primary_offer)}
    if wl_state.data_control_device != nil {ext_dc.data_control_device_v1_destroy(wl_state.data_control_device)}
    if wl_state.data_control_manager != nil {ext_dc.data_control_manager_v1_destroy(wl_state.data_control_manager)}
    if wl_state.seat != nil {wayland.seat_release(wl_state.seat)}
    wayland.registry_destroy(wl_state.registry)
    wayland.display_disconnect(wl_state.display)
}

wayland_get_fd :: proc(wl_state: ^Wayland_State) -> linux.Fd {
    return cast(linux.Fd)wayland.display_get_fd(wl_state.display)
}

wayland_dispatch :: proc(wl_state: ^Wayland_State) -> (ok: bool) {
    if wl_state.disabled {return false}
    wayland.display_dispatch(wl_state.display)
    return !wl_state.disabled
}

registry_listener := wayland.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint, interface_: cstring, version_: uint) {
        context = runtime.default_context()
        wl_state := cast(^Wayland_State)data

        // Use 1 as version in registry_bind calls to guarantee compatibility with as many compositors as possible
        switch interface_ {
        case "wl_seat":
            wl_state.seat = cast(^wayland.seat)wayland.registry_bind(registry, name_, &wayland.seat_interface, 1)
            wl_state.seat_name = name_
            log.debug("Successfully bound the Wayland seat")
        case "ext_data_control_manager_v1":
            wl_state.data_control_manager = cast(^ext_dc.data_control_manager_v1)wayland.registry_bind(
                registry,
                name_,
                &ext_dc.data_control_manager_v1_interface,
                1,
            )
            wl_state.data_control_manager_name = name_
            log.debug("Successfully bound the Wayland ext_data_control_manager")
        case:
            log.debugf("Uninterested in Wayland registry global callback for interface `%s`", interface_)
        }
    },
    global_remove = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint) {
        context = runtime.default_context()
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
        wl_state := cast(^Wayland_State)data
        log.debug("Received new data offer")
        // Attach offer listener to collect MIME types
        ext_dc.data_control_offer_v1_add_listener(id_, &offer_listener, wl_state)
        clear(&wl_state.pending_mime_types)
    },
    selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        context = runtime.default_context()
        wl_state := cast(^Wayland_State)data
        log.debug("Received new clipboard selection")

        // Cleanup existing data offer if exists
        if wl_state.clipboard_offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.clipboard_offer)}
        wl_state.clipboard_offer = id_
    },
    finished = proc "c" (data: rawptr, data_control_device_v1: ^ext_dc.data_control_device_v1) {
        context = runtime.default_context()
        wl_state := cast(^Wayland_State)data
        log.debug("Received `finished()` callback from data control device, disabling clipboard monitoring")
        wl_state.disabled = true
    },
    primary_selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
        context = runtime.default_context()
        wl_state := cast(^Wayland_State)data
        log.debug("Received new primary selection")

        if wl_state.primary_offer != nil {ext_dc.data_control_offer_v1_destroy(wl_state.primary_offer)}
        wl_state.primary_offer = id_
    },
}

