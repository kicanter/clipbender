# Dependencies

## Build dependencies

| | why | notes |
|---|---|---|
| **Odin** `dev-2026-04` or newer | compiler | I haven't confirmed the oldest compatible version of Odin that will sucessfully build, but `dev-2026-04` was used throughout much of the development of `clipbender`. It uses `core:time/timezone`, `core:unicode/utf8`, and `core:sys/linux/uring` which are some of the newer packages in `dev-2026-04`, so if your version of Odin has those you're probably good.
| **cairo** (devel headers) | the GUI render pass | TODO |
| **pango** (devel headers) | all GUI text | TODO |
| **git** | pulling `odin-wayland` submodule | I guess it's worth noting that `build.sh` uses `git` to build `odin-wayland` from the submodule, so in case this is somehow appearing on some forge that isn't `git`-based, you need `git` |

## Runtime dependencies

| library | `clipbenderd` | `clipbender` | why |
|---|---|---|---|
| `libwayland-client.so.0` | yes | yes | clipboard monitoring, the popup's surface |
| `libxkbcommon.so.0` | — | yes | keycode -> keysym resolution for the popup keymap |
| `libm.so.6`, `libc.so.6` | yes | yes | |

### Not a library, but required:

- A Wayland compositor implementing `ext-data-control-v1` or `wlr-data-control-unstable-v1`. Without one the daemon starts, logs that no backend is active, and serves named registers only. Live selections (`.` / `@.`) won't work either. [Wayland Explorer](https://wayland.app/protocols/) can quickly show you if your compositor implements a protocol at the bottom of the respective protocol's page.
- **`wlr-layer-shell-unstable-v1`** for the GUI popup only.
