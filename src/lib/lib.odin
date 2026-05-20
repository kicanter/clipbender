package lib

import "core:os"
import "core:fmt"

clipbender_socket_path :: proc() -> string {
    // Get XDG_RUNTIME_DIR, fallback to /tmp
    socket_dir := os.get_env("XDG_RUNTIME_DIR", context.allocator)
    if len(socket_dir) == 0 || !os.is_directory(socket_dir) {
        socket_dir = "/tmp"
    }
    return fmt.tprintf("%s/clipbender.sock", socket_dir)
}
