#+build linux
package wlr_data_control
@(private)
wlr_data_control_unstable_v1_types := []^interface {
	nil,
	nil,
	&data_control_source_v1_interface,
	&data_control_device_v1_interface,
	&wl.seat_interface,
	&data_control_source_v1_interface,
	&data_control_source_v1_interface,
	&data_control_offer_v1_interface,
	&data_control_offer_v1_interface,
	&data_control_offer_v1_interface,
}
/* This interface is a manager that allows creating per-seat data device
      controls. */
data_control_manager_v1 :: struct {}
data_control_manager_v1_set_user_data :: proc "contextless" (data_control_manager_v1_: ^data_control_manager_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)data_control_manager_v1_, user_data)
}

data_control_manager_v1_get_user_data :: proc "contextless" (data_control_manager_v1_: ^data_control_manager_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)data_control_manager_v1_)
}

/* Create a new data source. */
DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE :: 0
data_control_manager_v1_create_data_source :: proc "contextless" (data_control_manager_v1_: ^data_control_manager_v1) -> ^data_control_source_v1 {
	ret := proxy_marshal_flags(cast(^proxy)data_control_manager_v1_, DATA_CONTROL_MANAGER_V1_CREATE_DATA_SOURCE, &data_control_source_v1_interface, proxy_get_version(cast(^proxy)data_control_manager_v1_), 0, nil)
	return cast(^data_control_source_v1)ret
}

/* Create a data device that can be used to manage a seat's selection. */
DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE :: 1
data_control_manager_v1_get_data_device :: proc "contextless" (data_control_manager_v1_: ^data_control_manager_v1, seat_: ^wl.seat) -> ^data_control_device_v1 {
	ret := proxy_marshal_flags(cast(^proxy)data_control_manager_v1_, DATA_CONTROL_MANAGER_V1_GET_DATA_DEVICE, &data_control_device_v1_interface, proxy_get_version(cast(^proxy)data_control_manager_v1_), 0, nil, seat_)
	return cast(^data_control_device_v1)ret
}

/* All objects created by the manager will still remain valid, until their
        appropriate destroy request has been called. */
DATA_CONTROL_MANAGER_V1_DESTROY :: 2
data_control_manager_v1_destroy :: proc "contextless" (data_control_manager_v1_: ^data_control_manager_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_manager_v1_, DATA_CONTROL_MANAGER_V1_DESTROY, nil, proxy_get_version(cast(^proxy)data_control_manager_v1_), 1)
}

@(private)
data_control_manager_v1_requests := []message {
	{"create_data_source", "n", raw_data(wlr_data_control_unstable_v1_types)[2:]},
	{"get_data_device", "no", raw_data(wlr_data_control_unstable_v1_types)[3:]},
	{"destroy", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
}

data_control_manager_v1_interface : interface

/* This interface allows a client to manage a seat's selection.

      When the seat is destroyed, this object becomes inert. */
data_control_device_v1 :: struct {}
data_control_device_v1_set_user_data :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)data_control_device_v1_, user_data)
}

data_control_device_v1_get_user_data :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)data_control_device_v1_)
}

/* This request asks the compositor to set the selection to the data from
        the source on behalf of the client.

        The given source may not be used in any further set_selection or
        set_primary_selection requests. Attempting to use a previously used
        source is a protocol error.

        To unset the selection, set the source to NULL. */
DATA_CONTROL_DEVICE_V1_SET_SELECTION :: 0
data_control_device_v1_set_selection :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1, source_: ^data_control_source_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_device_v1_, DATA_CONTROL_DEVICE_V1_SET_SELECTION, nil, proxy_get_version(cast(^proxy)data_control_device_v1_), 0, source_)
}

/* Destroys the data device object. */
DATA_CONTROL_DEVICE_V1_DESTROY :: 1
data_control_device_v1_destroy :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_device_v1_, DATA_CONTROL_DEVICE_V1_DESTROY, nil, proxy_get_version(cast(^proxy)data_control_device_v1_), 1)
}

/* This request asks the compositor to set the primary selection to the
        data from the source on behalf of the client.

        The given source may not be used in any further set_selection or
        set_primary_selection requests. Attempting to use a previously used
        source is a protocol error.

        To unset the primary selection, set the source to NULL.

        The compositor will ignore this request if it does not support primary
        selection. */
DATA_CONTROL_DEVICE_V1_SET_PRIMARY_SELECTION :: 2
data_control_device_v1_set_primary_selection :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1, source_: ^data_control_source_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_device_v1_, DATA_CONTROL_DEVICE_V1_SET_PRIMARY_SELECTION, nil, proxy_get_version(cast(^proxy)data_control_device_v1_), 0, source_)
}

data_control_device_v1_listener :: struct {
/* The data_offer event introduces a new wlr_data_control_offer object,
        which will subsequently be used in either the
        wlr_data_control_device.selection event (for the regular clipboard
        selections) or the wlr_data_control_device.primary_selection event (for
        the primary clipboard selections). Immediately following the
        wlr_data_control_device.data_offer event, the new data_offer object
        will send out wlr_data_control_offer.offer events to describe the MIME
        types it offers. */
	data_offer : proc "c" (data: rawptr, data_control_device_v1: ^data_control_device_v1, id_: ^data_control_offer_v1),

/* The selection event is sent out to notify the client of a new
        wlr_data_control_offer for the selection for this device. The
        wlr_data_control_device.data_offer and the wlr_data_control_offer.offer
        events are sent out immediately before this event to introduce the data
        offer object. The selection event is sent to a client when a new
        selection is set. The wlr_data_control_offer is valid until a new
        wlr_data_control_offer or NULL is received. The client must destroy the
        previous selection wlr_data_control_offer, if any, upon receiving this
        event.

        The first selection event is sent upon binding the
        wlr_data_control_device object. */
	selection : proc "c" (data: rawptr, data_control_device_v1: ^data_control_device_v1, id_: ^data_control_offer_v1),

/* This data control object is no longer valid and should be destroyed by
        the client. */
	finished : proc "c" (data: rawptr, data_control_device_v1: ^data_control_device_v1),

/* The primary_selection event is sent out to notify the client of a new
        wlr_data_control_offer for the primary selection for this device. The
        wlr_data_control_device.data_offer and the wlr_data_control_offer.offer
        events are sent out immediately before this event to introduce the data
        offer object. The primary_selection event is sent to a client when a
        new primary selection is set. The wlr_data_control_offer is valid until
        a new wlr_data_control_offer or NULL is received. The client must
        destroy the previous primary selection wlr_data_control_offer, if any,
        upon receiving this event.

        If the compositor supports primary selection, the first
        primary_selection event is sent upon binding the
        wlr_data_control_device object. */
	primary_selection : proc "c" (data: rawptr, data_control_device_v1: ^data_control_device_v1, id_: ^data_control_offer_v1),

}
data_control_device_v1_add_listener :: proc "contextless" (data_control_device_v1_: ^data_control_device_v1, listener: ^data_control_device_v1_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)data_control_device_v1_, cast(^generic_c_call)listener,data)
}
/*  */
data_control_device_v1_error :: enum {
	used_source = 1,
}
@(private)
data_control_device_v1_requests := []message {
	{"set_selection", "?o", raw_data(wlr_data_control_unstable_v1_types)[5:]},
	{"destroy", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
	{"set_primary_selection", "2?o", raw_data(wlr_data_control_unstable_v1_types)[6:]},
}

@(private)
data_control_device_v1_events := []message {
	{"data_offer", "n", raw_data(wlr_data_control_unstable_v1_types)[7:]},
	{"selection", "?o", raw_data(wlr_data_control_unstable_v1_types)[8:]},
	{"finished", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
	{"primary_selection", "2?o", raw_data(wlr_data_control_unstable_v1_types)[9:]},
}

data_control_device_v1_interface : interface

/* The wlr_data_control_source object is the source side of a
      wlr_data_control_offer. It is created by the source client in a data
      transfer and provides a way to describe the offered data and a way to
      respond to requests to transfer the data. */
data_control_source_v1 :: struct {}
data_control_source_v1_set_user_data :: proc "contextless" (data_control_source_v1_: ^data_control_source_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)data_control_source_v1_, user_data)
}

data_control_source_v1_get_user_data :: proc "contextless" (data_control_source_v1_: ^data_control_source_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)data_control_source_v1_)
}

/* This request adds a MIME type to the set of MIME types advertised to
        targets. Can be called several times to offer multiple types.

        Calling this after wlr_data_control_device.set_selection is a protocol
        error. */
DATA_CONTROL_SOURCE_V1_OFFER :: 0
data_control_source_v1_offer :: proc "contextless" (data_control_source_v1_: ^data_control_source_v1, mime_type_: cstring) {
	proxy_marshal_flags(cast(^proxy)data_control_source_v1_, DATA_CONTROL_SOURCE_V1_OFFER, nil, proxy_get_version(cast(^proxy)data_control_source_v1_), 0, mime_type_)
}

/* Destroys the data source object. */
DATA_CONTROL_SOURCE_V1_DESTROY :: 1
data_control_source_v1_destroy :: proc "contextless" (data_control_source_v1_: ^data_control_source_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_source_v1_, DATA_CONTROL_SOURCE_V1_DESTROY, nil, proxy_get_version(cast(^proxy)data_control_source_v1_), 1)
}

data_control_source_v1_listener :: struct {
/* Request for data from the client. Send the data as the specified MIME
        type over the passed file descriptor, then close it. */
	send : proc "c" (data: rawptr, data_control_source_v1: ^data_control_source_v1, mime_type_: cstring, fd_: int),

/* This data source is no longer valid. The data source has been replaced
        by another data source.

        The client should clean up and destroy this data source. */
	cancelled : proc "c" (data: rawptr, data_control_source_v1: ^data_control_source_v1),

}
data_control_source_v1_add_listener :: proc "contextless" (data_control_source_v1_: ^data_control_source_v1, listener: ^data_control_source_v1_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)data_control_source_v1_, cast(^generic_c_call)listener,data)
}
/*  */
data_control_source_v1_error :: enum {
	invalid_offer = 1,
}
@(private)
data_control_source_v1_requests := []message {
	{"offer", "s", raw_data(wlr_data_control_unstable_v1_types)[0:]},
	{"destroy", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
}

@(private)
data_control_source_v1_events := []message {
	{"send", "sh", raw_data(wlr_data_control_unstable_v1_types)[0:]},
	{"cancelled", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
}

data_control_source_v1_interface : interface

/* A wlr_data_control_offer represents a piece of data offered for transfer
      by another client (the source client). The offer describes the different
      MIME types that the data can be converted to and provides the mechanism
      for transferring the data directly from the source client. */
data_control_offer_v1 :: struct {}
data_control_offer_v1_set_user_data :: proc "contextless" (data_control_offer_v1_: ^data_control_offer_v1, user_data: rawptr) {
   proxy_set_user_data(cast(^proxy)data_control_offer_v1_, user_data)
}

data_control_offer_v1_get_user_data :: proc "contextless" (data_control_offer_v1_: ^data_control_offer_v1) -> rawptr {
   return proxy_get_user_data(cast(^proxy)data_control_offer_v1_)
}

/* To transfer the offered data, the client issues this request and
        indicates the MIME type it wants to receive. The transfer happens
        through the passed file descriptor (typically created with the pipe
        system call). The source client writes the data in the MIME type
        representation requested and then closes the file descriptor.

        The receiving client reads from the read end of the pipe until EOF and
        then closes its end, at which point the transfer is complete.

        This request may happen multiple times for different MIME types. */
DATA_CONTROL_OFFER_V1_RECEIVE :: 0
data_control_offer_v1_receive :: proc "contextless" (data_control_offer_v1_: ^data_control_offer_v1, mime_type_: cstring, fd_: int) {
	proxy_marshal_flags(cast(^proxy)data_control_offer_v1_, DATA_CONTROL_OFFER_V1_RECEIVE, nil, proxy_get_version(cast(^proxy)data_control_offer_v1_), 0, mime_type_, fd_)
}

/* Destroys the data offer object. */
DATA_CONTROL_OFFER_V1_DESTROY :: 1
data_control_offer_v1_destroy :: proc "contextless" (data_control_offer_v1_: ^data_control_offer_v1) {
	proxy_marshal_flags(cast(^proxy)data_control_offer_v1_, DATA_CONTROL_OFFER_V1_DESTROY, nil, proxy_get_version(cast(^proxy)data_control_offer_v1_), 1)
}

data_control_offer_v1_listener :: struct {
/* Sent immediately after creating the wlr_data_control_offer object.
        One event per offered MIME type. */
	offer : proc "c" (data: rawptr, data_control_offer_v1: ^data_control_offer_v1, mime_type_: cstring),

}
data_control_offer_v1_add_listener :: proc "contextless" (data_control_offer_v1_: ^data_control_offer_v1, listener: ^data_control_offer_v1_listener, data: rawptr) {
	proxy_add_listener(cast(^proxy)data_control_offer_v1_, cast(^generic_c_call)listener,data)
}
@(private)
data_control_offer_v1_requests := []message {
	{"receive", "sh", raw_data(wlr_data_control_unstable_v1_types)[0:]},
	{"destroy", "", raw_data(wlr_data_control_unstable_v1_types)[0:]},
}

@(private)
data_control_offer_v1_events := []message {
	{"offer", "s", raw_data(wlr_data_control_unstable_v1_types)[0:]},
}

data_control_offer_v1_interface : interface

@(private)
@(init)
init_interfaces_wlr_data_control_unstable_v1 :: proc "contextless" () {
	data_control_manager_v1_interface.name = "zwlr_data_control_manager_v1"
	data_control_manager_v1_interface.version = 2
	data_control_manager_v1_interface.method_count = 3
	data_control_manager_v1_interface.event_count = 0
	data_control_manager_v1_interface.methods = raw_data(data_control_manager_v1_requests)
	data_control_device_v1_interface.name = "zwlr_data_control_device_v1"
	data_control_device_v1_interface.version = 2
	data_control_device_v1_interface.method_count = 3
	data_control_device_v1_interface.event_count = 4
	data_control_device_v1_interface.methods = raw_data(data_control_device_v1_requests)
	data_control_device_v1_interface.events = raw_data(data_control_device_v1_events)
	data_control_source_v1_interface.name = "zwlr_data_control_source_v1"
	data_control_source_v1_interface.version = 1
	data_control_source_v1_interface.method_count = 2
	data_control_source_v1_interface.event_count = 2
	data_control_source_v1_interface.methods = raw_data(data_control_source_v1_requests)
	data_control_source_v1_interface.events = raw_data(data_control_source_v1_events)
	data_control_offer_v1_interface.name = "zwlr_data_control_offer_v1"
	data_control_offer_v1_interface.version = 1
	data_control_offer_v1_interface.method_count = 2
	data_control_offer_v1_interface.event_count = 1
	data_control_offer_v1_interface.methods = raw_data(data_control_offer_v1_requests)
	data_control_offer_v1_interface.events = raw_data(data_control_offer_v1_events)
}

// Functions from libwayland-client
import wl "../odin-wayland"
fixed_t :: wl.fixed_t
proxy :: wl.proxy
message :: wl.message
interface :: wl.interface
array :: wl.array
generic_c_call :: wl.generic_c_call
proxy_add_listener :: wl.proxy_add_listener
proxy_get_listener :: wl.proxy_get_listener
proxy_get_user_data :: wl.proxy_get_user_data
proxy_set_user_data :: wl.proxy_set_user_data
proxy_get_version :: wl.proxy_get_version
proxy_marshal :: wl.proxy_marshal
proxy_marshal_flags :: wl.proxy_marshal_flags
proxy_marshal_constructor :: wl.proxy_marshal_constructor
proxy_destroy :: wl.proxy_destroy
