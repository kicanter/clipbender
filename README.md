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
- `selection` / `@selection` — the live system selections (valid as a `set` destination or source,
  and retrievable with `get ++selection` / `get ++@selection`)

A leading `@` always means "the primary-selection variant of this": `5` vs `@5`, `selection` vs
`@selection`, `++numbered` vs `++@numbered`.

### CLI

```sh
clipbender                       # open the popup
clipbenderd                      # start the daemon
clipbender shutdown              # stop the daemon

clipbender set a selection       # set register `a` from the live clipboard selection
clipbender set selection 1       # set the live clipboard selection from clipboard register 1
clipbender set a @selection      # set register `a` from the live primary selection
clipbender set A selection       # append the live clipboard selection to register `a`
clipbender set @selection @5     # set the live primary selection from primary register 5
<cmd> | clipbender set a         # set register `a` from stdin
clipbender set a < file          # set register `a` from stdin redirection

clipbender clear a               # clear named register `a`
```

#### Filtering `get`

Keywords take a double prefix (`++` to include, `--` to exclude); individual registers and ranges
take a single prefix (`+` / `-`). Order doesn't matter — exclusions are applied after all inclusions,
so `++all --@selection` and `--@selection ++all` are equivalent.

| Token                          | Selects                                |
| ------------------------------ | -------------------------------------- |
| `++all`                        | every register                         |
| `++numbered` / `++@numbered`   | clipboard / primary recency registers  |
| `++named`                      | named registers (`a`-`z`)              |
| `++selection` / `++@selection` | the live clipboard / primary selection |
| `+adz`, `+038`, `+@038`        | specific registers                     |
| `+0:5`, `+a:f`, `+@0:3`        | an inclusive range within one kind     |

```sh
clipbender get ++all                  # every register
clipbender get ++all --@selection     # everything except the live primary selection
clipbender get ++named -abc           # named registers except a, b, c
clipbender get ++selection            # just the live clipboard selection
clipbender get +@012 +012             # first three primary and clipboard numbered registers
clipbender get +a:f +@0:3             # named range a-f plus primary range 0-3
```

#### `get` output formats

`get` prints an aligned table by default. `fmt=json` emits structured JSON; `fmt=raw` emits only the register contents,
which is what makes `get` composable with other tools.

Multiple registers under `fmt=raw` are separated by a **NUL byte**. The output is recoverable with `read -d ''`, `xargs
-0`, `grep -z`, etc. A single register is emitted with no separator at all, byte-identical to its contents, so `> file`
and `| wl-copy` stay exact.

[!IMPORTANT] Binary contents *can* contain NUL, so a multi-register raw dump of binary blobs is a plain concatenation, similar
to `cat a b c`. Use `fmt=json` when entries must be separable regardless of what they hold.

```sh
clipbender get ++numbered fmt=json    # structured JSON
clipbender get +a fmt=raw | wl-copy   # pipe register `a` into wl-copy
clipbender get +a fmt=raw > file      # redirect register `a` to a file
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
editing, and multi-MIME clipboard entries are planned for v0.2.
