package main

import "../lib"

main :: proc() {
    socket_path := lib.clipbender_socket_path()

    // Check for an existing stale socket first
    check_stale_socket(socket_path)

    // Run socket event loop
    uds_serve(socket_path)
}
