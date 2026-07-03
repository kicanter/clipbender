# clipbender
Linux clipboard manager modeled after Neovim's register design, exposing system-wide clipboard history via various named registers.

Targeting `ext-data-control-v1` protocol first (falling back to `wlr-data-control-unstable-v1`) which most compositors support, will extend to other backends (X11/XWayland which would support GNOME, except for certain edge cases with Wayland-native apps). For Mutter specifically, I might make a small GJS extension to add support for GNOME desktops.
