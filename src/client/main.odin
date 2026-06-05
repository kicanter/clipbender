package main

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:time"

import "../lib"

run_gui :: proc(socket_fd: linux.Fd) {
    for {
        fmt.println("You ran the GUI")
        time.sleep(3 * time.Second)
    }
}

main :: proc() {
    socket_path := lib.clipbender_socket_path()

    socket_fd := uds_connect(socket_path)
    defer linux.close(socket_fd)

    args := os.args[1:]

    if len(args) == 0 {
        run_gui(socket_fd)
    } else {
        run_cli(socket_fd, args)
    }
}
