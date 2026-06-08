package main

import "core:log"

import "../lib"

main :: proc() {
    context.logger = log.create_console_logger()
    defer log.destroy_console_logger(context.logger)

    socket_path := lib.clipbender_socket_path()
    defer delete(socket_path)

    // Check for an existing stale socket first
    check_stale_socket(socket_path)

    // Run socket event loop
    uds_serve(socket_path)
}

