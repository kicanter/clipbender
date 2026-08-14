package main

import "core:fmt"
import "core:os"

import lib "src:libclipbender"

HOME_ENV_VAR :: "HOME"
CLIPBENDER_STATE_DIR :: ".local/state/clipbender"
REGISTERS_FILENAME :: "registers"
// Caller is responsible for freeing returned string.
clipbender_state_path :: proc(persist_state: bool) -> string {
    if persist_state {
        return lib.env_path_with_fallback(HOME_ENV_VAR, CLIPBENDER_STATE_DIR, REGISTERS_FILENAME, lib.TMP_DIR)
    }

    dir := fmt.tprintf("%s/%s", lib.TMP_DIR, lib.CLIPBENDER_SUBDIR)
    os.make_directory_all(dir)
    return fmt.aprintf("%s/%s", dir, REGISTERS_FILENAME)
}

// Registers are persisted using the dedicated state format (full fidelity: all blobs and mimes per entry), distinct
// from the GET response format. See `libclipbender.marshal_state()` / `libclipbender.unmarshal_state()`.
save_registers_state :: proc(filename: string, regs: [lib.MAX_REGS]^lib.Reg_Entry) -> (written: int, err: os.Error) {
    buf: [lib.MAX_MSG_SIZE]u8
    written = lib.marshal_state(regs, buf[:])
    err = os.write_entire_file(filename, buf[:written])
    return written, err
}

// Fills `regs` in place with owned entries (caller frees via free_reg_entry). Uses the out-param
// shape to match unmarshal_state, which it wraps: the deserialize/own path fills a value array.
load_registers_state :: proc(filename: string, regs: ^[lib.MAX_REGS]lib.Reg_Entry) -> os.Error {
    data, err := os.read_entire_file(filename, context.temp_allocator)
    if err != os.General_Error.None {return err}
    _ = lib.unmarshal_state(data, regs)
    return err
}

