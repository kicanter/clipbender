# clipbender

Linux clipboard manager modeled after Neovim's register design, exposing system-wide clipboard history via various named registers.

Targeting `ext-data-control-v1` protocol first (falling back to `wlr-data-control-unstable-v1`) which most compositors support, will extend to other backends (X11/XWayland which would support GNOME, except for certain edge cases with Wayland-native apps). For Mutter specifically, I might make a small GJS extension to add support for GNOME desktops.

## Dependencies

- A Wayland compositor implementing `ext-data-control-v1` or `wlr-data-control-unstable-v1`
  (Hyprland, Sway, KWin, COSMIC, niri, river, Mir, Labwc, ...). GNOME/Mutter is not
  yet supported (planned via an X11/XWayland backend).
  - Named registers still work without a valid Wayland backend, but sort of the whole point of this program is live
  clipboard monitoring.
- The compositor must implement `wlr-layer-shell` to support the popup GUI.

### Build deps

- [Odin](https://odin-lang.org/) duh
- `libwayland-client` for the Clipbender daemon
- `libxkbcommon` for the Clipbender client

### Runtime deps

none :) (no shared libraries at least, you still need a valid compositor mentioned above)

## Building

```sh
make            # build both binaries into build/
make release    # optimized + stripped build
make test       # run the unit tests
```

The two binaries produced are:

- `clipbenderd` — the headless daemon that monitors the clipboard and owns register state.
- `clipbender` — the CLI client and popup GUI.

## Installing

```sh
sudo make install                 # installs to /usr/local by default
make install PREFIX=~/.local      # user-local install (no root)
```

`make install` installs both binaries, the systemd **user** service, and bash/zsh/fish
shell completions. nushell users should `source` `packaging/completions/clipbender.nu`
from their `config.nu`. `make uninstall` removes everything it installed.

### Running as a systemd user service

```sh
systemctl --user daemon-reload
systemctl --user enable --now clipbenderd.service
```

The unit is bound to `graphical-session.target`, so it starts with your Wayland session.
Alternatively just run `clipbenderd` directly (e.g. from your compositor's autostart).

## Usage

Start the daemon (`clipbenderd`), then use the `clipbender` client. Running bare
`clipbender` opens the keyboard-driven popup.

### Register model

- `0`-`9` — clipboard numbered registers (most-recent-first, read-only source)
- `@0`-`@9` — primary-selection numbered registers (read-only source)
- `a`-`z` — named registers (user-managed)
- `A`-`Z` — append to the corresponding lowercase named register
- `clipboard` / `primary` — the live system selections (valid as set destination or source)

### CLI

```sh
clipbender                       # open the popup
clipbenderd                      # start the daemon
clipbender shutdown              # stop the daemon

clipbender set a clipboard       # set register `a` from the system clipboard
clipbender set clipboard 1       # set the system clipboard from clipboard register 1
clipbender set a primary         # set register `a` from the primary selection
clipbender set A clipboard       # append the system clipboard to register `a`
clipbender set primary @5        # set the primary selection from primary register 5
<cmd> | clipbender set a          # set register `a` from stdin

clipbender clear a               # clear named register `a`

clipbender get ++all             # print all registers
clipbender get ++named -abc      # print named registers except a, b, c
clipbender get +@012 +012        # first three primary and clipboard numbered registers
clipbender get +0:5 +@0:3 fmt=json   # ranges, as structured JSON
```

### Popup keymap

The popup always copies **to the clipboard** (never the primary selection).

| Keystroke        | Action                                          |
| ---------------- | ----------------------------------------------- |
| `{digit}`        | clipboard recency → clipboard, dismiss          |
| `@{digit}`       | primary recency → clipboard, dismiss            |
| `{alpha}`        | named register → clipboard, dismiss             |
| `<C-{alpha}>`    | clipboard → overwrite named register, dismiss   |
| `<S-{alpha}>`    | clipboard → append named register, dismiss      |
| `Escape`         | cancel / dismiss                                |

## Status

Phase 1 targets wlroots-based compositors, or more specifically, compositors implementing the `ext_data_control_v1` or
`wlr_data_control_unstable_v1` protocols. GNOME/X11 support, a polished cairo/pangocairo-rendered popup, inline register
editing, and multi-MIME clipboard entries are planned for v0.2. See `PLAN.md` for the full roadmap.
