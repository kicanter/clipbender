package main

import "core:sys/linux"

import ext_dc "wayland:ext-data-control"
import wayland "wayland:odin-wayland"

Wayland_State :: struct {
    display:              ^wayland.display,
    registry:             ^wayland.registry,
    seat:                 ^wayland.seat,
    data_control_manager: ^ext_dc.data_control_manager_v1,
    data_control_device:  ^ext_dc.data_control_device_v1,
    clipboard_offer:      ^ext_dc.data_control_offer_v1,
    primary_offer:        ^ext_dc.data_control_offer_v1,
}

wayland_init :: proc() -> (wl_state: Wayland_State, ok: bool) {
    return {}, {}
}

wayland_cleanup :: proc(wl_state: ^Wayland_State) {

}

wayland_get_fd :: proc(wl_state: ^Wayland_State) -> linux.Fd {
    return linux.Fd(-1) // TODO: return wl.display_get_fd(wl_state.display)
}

wayland_dispatch :: proc(wl_state: ^Wayland_State) {

}

registry_listener :: wayland.registry_listener {
    global = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint, interface_: cstring, version_: uint) {
    },
    global_remove = proc "c" (data: rawptr, registry: ^wayland.registry, name_: uint) {
    },
}

device_listener :: ext_dc.data_control_device_v1_listener {
    data_offer = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
    ) -> ^ext_dc.data_control_offer_v1 {
        return nil
    },
    selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
    },
    finished = proc "c" (data: rawptr, data_control_device_v1: ^ext_dc.data_control_device_v1) {
    },
    primary_selection = proc "c" (
        data: rawptr,
        data_control_device_v1: ^ext_dc.data_control_device_v1,
        id_: ^ext_dc.data_control_offer_v1,
    ) {
    },
}

