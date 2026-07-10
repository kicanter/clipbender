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

save_registers :: proc() {

}

load_registers :: proc() {

}

