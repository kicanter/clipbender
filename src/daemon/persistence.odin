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
STATE_FILENAME :: "registers.iroh"
// Name of directory that holds the `<hash>` files for large blobs.
BLOBS_SUBDIR :: "blobs"
// Caller is responsible for freeing the returned string.
state_file_path :: proc(dir: string) -> string {
    return fmt.aprintf("%s/%s", dir, STATE_FILENAME)
}
// Caller is responsible for freeing the returned string.
blobs_dir_path :: proc(dir: string) -> string {
    return fmt.aprintf("%s/%s", dir, BLOBS_SUBDIR)
}

// We split the state path resolution logic up between ephemeral (tmpfs) and persistent state (non-tmpfs disk) because
// they illicit different expectations wrt saving state:
// * With ephemeral, the user doesn't even expect to persist state at all and it's purely for convenience and
//   user-experience that we write it to tmpfs such that they don't loser their state every single time the daemon
//   terminates, so it's fine to proceed without a valid path to write.
// * With persistent, the user expects state to persist, so we want to hard-error instead of letting them continue while
//   thinking their register state will be auto-saved.
//
// Resolve path starting from `$XDG_RUNTIME_DIR`, or `nil` when the runtime dir is unusable. The runtime dir is tmpfs,
// so state is cleared on reboot and on logout.
//
// Caller is responsible for freeing the returned string.
ephemeral_state_dir :: proc() -> Maybe(string) {
    path, ok := lib.env_dir_or_none(lib.RUNTIME_ENV_VAR, lib.CLIPBENDER_SUBDIR)
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
persistent_state_dir :: proc() -> (path: string, err: Maybe(string)) {
    // TODO (config): allow user to pass their own path
    state_home := os.get_env(STATE_ENV_VAR, context.allocator)
    defer delete(state_home)
    if len(state_home) > 0 && os.is_directory(state_home) {
        return lib.private_dir(state_home, lib.CLIPBENDER_SUBDIR), nil
    }

    home := os.get_env(HOME_ENV_VAR, context.allocator)
    defer delete(home)
    if len(home) > 0 && os.is_directory(home) {
        state_dir := fmt.tprintf("%s/%s", home, XDG_STATE_SUBDIR)
        return lib.private_dir(state_dir, lib.CLIPBENDER_SUBDIR), nil
    }


    return "", "neither $XDG_STATE_HOME nor $HOME resolves to a directory"
}

// Registers are persisted using the dedicated state format (all reprs and mimes per entry). See
// `libclipbender.marshal_state()` / `libclipbender.unmarshal_state()`.
//
// `dir` holds the index at `registers.iroh` and a file for each large blob under `blobs/`. Blob files must be written
// first so a crash may leave orphan files which can be reconciled during a save/load at a future point instead of a
// `registers.iroh` that cites <hash> files that were never written.
save_registers_state :: proc(dir: string, regs: [lib.MAX_REGS]^lib.Reg_Entry) -> (written: int, err: os.Error) {
    table := lib.build_blob_table(regs, context.temp_allocator)

    if err = write_state_blobs(dir, table[:]); err != os.General_Error.None {
        return 0, err
    }

    buf := make([]u8, lib.state_size(regs))
    defer delete(buf)

    written = lib.marshal_state(regs, buf)

    filename := state_file_path(dir)
    defer delete(filename)

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

// Write every file-backed blob in `table` to `<dir>/blobs/<hash>`.
write_state_blobs :: proc(dir: string, table: []^lib.Rc_Blob) -> os.Error {
    needs_dir := false
    for blob in table {
        if lib.blob_is_file_backed(blob) {
            needs_dir = true
            break
        }
    }
    if !needs_dir {return nil}

    blobs_dir := blobs_dir_path(dir)
    defer delete(blobs_dir)
    if err := os.make_directory_all(blobs_dir, lib.CLIPBENDER_DIR_PERMS); err != nil {return err}

    for blob in table {
        if !lib.blob_is_file_backed(blob) {continue}

        name_buf: lib.Blob_Name
        name := lib.blob_filename(name_buf[:], blob.hash)
        path := fmt.tprintf("%s/%s", blobs_dir, name)
        if os.exists(path) {continue}

        // Same temp + rename as the index, so a reader never sees a partially written blob under its final name.
        tmp_path := fmt.tprintf("%s.tmp", path)
        if err := os.write_entire_file(tmp_path, blob.data, lib.CLIPBENDER_FILE_PERMS); err != nil {
            os.remove(tmp_path)
            return err
        }
        if err := os.rename(tmp_path, path); err != nil {
            os.remove(tmp_path)
            return err
        }
    }
    return nil
}

// Fills `regs` in place with owned entries (caller frees via free_reg_entry). Uses the out-param
// shape to match unmarshal_state, which it wraps: the deserialize/own path fills a value array.
//
// A corrupt or truncated file is reported rather than partially applied: `unmarshal_state` frees whatever it decoded
// and zeroes `regs`, so the caller starts with empty history instead of a half-restored store. `parse_err` is separate
// from `err` because the two are not the same failure. A read error means the file is unreachable, a parse error
// means its contents are unusable, and only the latter implies the file should probably be replaced.
load_registers_state :: proc(
    dir: string,
    regs: ^[lib.MAX_REGS]lib.Reg_Entry,
) -> (
    err: os.Error,
    parse_err: Maybe(string),
) {
    filename := state_file_path(dir)
    defer delete(filename)

    data, read_err := os.read_entire_file(filename, context.temp_allocator)
    if read_err != os.General_Error.None {return read_err, nil}

    // File-backed blobs are read from here as the index names them.
    blobs_dir := blobs_dir_path(dir)
    defer delete(blobs_dir)

    count: u8
    count, parse_err = lib.unmarshal_state(data, regs, blobs_dir)
    if parse_err == nil {
        log.infof("Successfully read %d registers from %s", count, filename)
    }
    return nil, parse_err
}
