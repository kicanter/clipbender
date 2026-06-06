package main

import "core:fmt"
import "core:sys/linux"
import "core:time"

run_gui :: proc(socket_fd: linux.Fd) {
    for {
        fmt.println("You ran the GUI")
        time.sleep(3 * time.Second)
    }
}

