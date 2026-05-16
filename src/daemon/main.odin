package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:sys/linux/uring"

ACCEPT :: 0
RECV :: 1

buf: [4096]u8

run_uds_server :: proc(socket_path: string) {
    socket_fd, sockerr := linux.socket(.UNIX, .SEQPACKET, {.CLOEXEC}, {})
    fmt.assertf(sockerr == nil, "Failed to create socket: err %d", sockerr)

    socket_addr: linux.Sock_Addr_Un
    socket_addr.sun_family = .UNIX
    copy(socket_addr.sun_path[:], transmute([]u8)socket_path)

    binderr := linux.bind(socket_fd, &socket_addr)
    fmt.assertf(binderr == nil, "Failed to bind fd to socket: %v", binderr)

    listenerr := linux.listen(socket_fd, 128)
    fmt.assertf(listenerr == nil, "Failed to listen to socket fd: %v", listenerr)

    // Set up io_uring
    ring: uring.Ring
    params := uring.DEFAULT_PARAMS
    err := uring.init(&ring, &params)
    fmt.assertf(err == nil, "uring.init: %v", err)
    defer uring.destroy(&ring)

    // Submit initial accept to jump start queue
    sqe, ok := uring.get_sqe(&ring)
    fmt.assertf(ok, "Submission queue for io_uring is full")
    uring.accept(&ring, ACCEPT, socket_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
    uring.submit(&ring)

    // Completion queue event loop
    cqes: [16]linux.IO_Uring_CQE
    for {
        n_copied, err := uring.copy_cqes(&ring, cqes[:], 1)
        if (err != nil) {
            log.errorf("Error copying CQEs from completion queue: %v", err)
        }

        for i in 0 ..< n_copied {
            cqe := cqes[i]

            switch cqe.user_data {
            case ACCEPT:
                // new client
                if cqe.res < 0 {
                    log.errorf("Client accept failed: %v", cqe.res)
                    continue
                }

                // Submit recv
                client_fd := cast(linux.Fd)cqe.res
                uring.recv(&ring, RECV, client_fd, buf[:], {})
                uring.accept(&ring, ACCEPT, socket_fd, cast(^linux.Sock_Addr_Un)nil, nil, {.CLOEXEC})
            case RECV:
                // Receive data
                bytes_read := int(cqe.res)
                if bytes_read > 0 {
                    fmt.printfln("Got: %s", string(buf[:bytes_read]))
                }
            }
        }
        uring.submit(&ring)
    }
}

main :: proc() {
    fmt.println("Hello clipbenderd daemon 😼")

    // Get XDG_RUNTIME_DIR, fallback to /tmp
    socket_dir := os.get_env("XDG_RUNTIME_DIR", context.allocator)
    if len(socket_dir) == 0 || !os.is_directory(socket_dir) {
        socket_dir = "/tmp"
    }
    socket_path := fmt.tprintf("%s/clipbender.sock", socket_dir)

    run_uds_server(socket_path)
}

