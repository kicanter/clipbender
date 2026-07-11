package main

import "core:fmt"
import "core:os"

import lib "src:libclipbender"

HOME_ENV_VAR :: "HOME"
CLIPBENDER_STATE_DIR :: ".local/state/clipbender"
REGISTERS_FILENAME :: "registers"
// Caller is responsible for freeing returned string.
clipbender_state_path :: proc() -> string {
    // HACK: make a config option or maybe a flag or something?
    persist_state := false
    if persist_state {
        return lib.env_path_with_fallback(HOME_ENV_VAR, CLIPBENDER_STATE_DIR, REGISTERS_FILENAME, lib.TMP_DIR)
    }

    dir := fmt.tprintf("%s/%s", lib.TMP_DIR, lib.CLIPBENDER_SUBDIR)
    os.make_directory_all(dir)
    return fmt.aprintf("%s/%s", dir, REGISTERS_FILENAME)
}

// Binary serialization contract for clipbender registers state is exactly the same as that of a GET command
// See `libclipbender.marshal_resp_registers()` and `libclipbender.unmarshal_resp_registers()` for binary serialization
// of the response message for retrieving register data.
// See `libclipbender.Reg` for binary serialization of a single `Reg`.

save_registers_state :: proc(filename: string, regs: []lib.Reg) -> (written: int, err: os.Error) {
    // Subtract one byte from the total because we don't write the Resp_Status byte to state file
    buf: [MAX_DATA_SIZE]u8
    written = lib.marshal_resp_registers(regs, buf[:]) - 1
    err = os.write_entire_file(filename, buf[1:1 + written])
    return written, err
}

load_registers_state :: proc(filename: string, regs: ^[46]lib.Reg) -> (count: u8, err: os.Error) {
    data: []u8
    data, err = os.read_entire_file(filename, context.temp_allocator)
    if err != os.General_Error.None {return 0, err}
    count = lib.unmarshal_resp_registers(data, regs)
    return count, err
}

