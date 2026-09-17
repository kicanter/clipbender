package main

import "core:fmt"
import "core:log"
import "core:os"

import lib "src:libclipbender"

STATE_ENV_VAR :: "XDG_STATE_HOME"
HOME_ENV_VAR :: "HOME"
// Relative to `$HOME`, used only when `$XDG_STATE_HOME` is unset. The XDG spec defines `$XDG_STATE_HOME` with
// this as its default.
XDG_STATE_SUBDIR :: ".local/state"
REGISTERS_FILENAME :: "registers"

// We split the state path resolution logic up between ephemeral (tmpfs) and persistent state (non-tmpfs disk) because
// they illicit different expectations wrt saving state:
// * With ephemeral, the user doesn't even expect to persist state at all and it's purely for convenience and
//   user-experience that we write it to tmpfs such that they don't loser their state every single time the daemon
//   terminates, so it's fine to proceed without a valid path to write.
// * With persistent, the user expects state to persist, so we want to hard-error instead of letting them continue while
//   thinking their register state will be auto-saved.

// Resolve path starting from `$XDG_RUNTIME_DIR`, or `nil` when the runtime dir is unusable. The runtime dir is tmpfs,
// so state is cleared on reboot and on logout.
//
// Caller is responsible for freeing the returned string.
ephemeral_state_path :: proc() -> Maybe(string) {
    path, ok := lib.env_path_or_none(lib.RUNTIME_ENV_VAR, lib.CLIPBENDER_SUBDIR, REGISTERS_FILENAME)
    if !ok {
        log.warnf(
            "$%s does not resolve to a directory, running without a state file (registers will not survive a daemon restart)",
            lib.RUNTIME_ENV_VAR,
        )
        return nil
    }
    return path
}

// Resolve path starting from `$XDG_STATE_HOME`, else `$HOME/.local/state/`, with no `/tmp` fallback. The user asked for
// state that survives reboots, so hard-error if we can't resolve a valid path.
//
// Caller is responsible for freeing the returned string when `err` is nil.
persistent_state_path :: proc() -> (path: string, err: Maybe(string)) {
    // TODO (config): allow user to pass their own path
    state_home := os.get_env(STATE_ENV_VAR, context.allocator)
    defer delete(state_home)
    if len(state_home) > 0 && os.is_directory(state_home) {
        return lib.private_dir_path(state_home, lib.CLIPBENDER_SUBDIR, REGISTERS_FILENAME), nil
    }

    home := os.get_env(HOME_ENV_VAR, context.allocator)
    defer delete(home)
    if len(home) > 0 && os.is_directory(home) {
        state_dir := fmt.tprintf("%s/%s", home, XDG_STATE_SUBDIR)
        return lib.private_dir_path(state_dir, lib.CLIPBENDER_SUBDIR, REGISTERS_FILENAME), nil
    }


    return "", "neither $XDG_STATE_HOME nor $HOME resolves to a directory"
}

// Registers are persisted using the dedicated state format (full fidelity: all reprs and mimes per entry). See
// `libclipbender.marshal_state()` / `libclipbender.unmarshal_state()`.
save_registers_state :: proc(filename: string, regs: [lib.MAX_REGS]^lib.Reg_Entry) -> (written: int, err: os.Error) {
    buf := make([]u8, lib.state_size(regs))
    defer delete(buf)

    written = lib.marshal_state(regs, buf)

    // Write to a sibling temp file and rename over the target to ensure state save is an atomic operation. The mode is
    // set here rather than after the rename because `rename` preserves the source's mode.
    tmp_path := fmt.tprintf("%s.tmp", filename)
    err = os.write_entire_file(tmp_path, buf[:written], lib.CLIPBENDER_FILE_PERMS)
    if err != os.General_Error.None {
        os.remove(tmp_path)
        return written, err
    }

    err = os.rename(tmp_path, filename)
    if err != os.General_Error.None {os.remove(tmp_path)}

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
