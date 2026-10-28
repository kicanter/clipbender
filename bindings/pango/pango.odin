package pango

foreign import pango "system:pango-1.0"
foreign import gobject "system:gobject-2.0" // `Layout` is a GObject and released with `g_object_unref`.

/**
 * PangoLayout:
 *
 * A `PangoLayout` represents an entire paragraph of text. It owns the shaping, bidirectional reordering, font
 * fallback, line breaking and ellipsization that the popup would otherwise have to implement.
 */
Layout :: struct {}

/**
 * PangoFontDescription:
 *
 * A `PangoFontDescription` describes a font in an implementation-independent manner -- a family name and size
 * resolved through fontconfig, rather than a path to a specific file.
 */
Font_Description :: struct {}

/**
 * PangoFontMap:
 *
 * A `PangoFontMap` represents the set of fonts available for a particular rendering system. pango keeps a
 * process-wide default one and owns it, so releasing it is `pango_cairo_font_map_set_default(nil)` rather than an
 * unref of our own.
 */
Font_Map :: struct {}

/**
 * PangoContext:
 *
 * Stores global information used to control rendering. Obtained from a cairo context via
 * `pango_cairo_create_context`; not needed when `pango_cairo_create_layout` is used instead.
 */
Pango_Context :: struct {}

/**
 * PANGO_SCALE:
 *
 * Pango measures in units of 1/`PANGO_SCALE` of a device unit, so a width or size in pixels must be multiplied by
 * this before being handed to pango, and results divided by it on the way back. Getting this wrong silently yields a
 * layout 1024 times too narrow.
 */
SCALE :: 1024

/**
 * PangoEllipsizeMode:
 *
 * What to omit when text exceeds the available width. `END` is what the register previews want: cut at a grapheme
 * boundary with an ellipsis, never mid-codepoint.
 */
Ellipsize_Mode :: enum i32 {
    NONE   = 0,
    START  = 1,
    MIDDLE = 2,
    END    = 3,
}

/**
 * PangoWrapMode:
 *
 * How to break lines that exceed the width. `WORD` uses the Unicode line breaking algorithm (UAX #14).
 */
Wrap_Mode :: enum i32 {
    WORD      = 0,
    CHAR      = 1,
    WORD_CHAR = 2,
}

/** PangoAlignment: how partial lines are positioned within the layout's width. */
Alignment :: enum i32 {
    LEFT   = 0,
    CENTER = 1,
    RIGHT  = 2,
}

foreign pango {
    /**
     * pango_layout_set_text:
     *
     * Sets the text of the layout. @length is in bytes, or -1 for a nul-terminated string. Odin strings are not
     * nul-terminated, so pass `raw_data(s)` with `len(s)` rather than relying on -1.
     */
    pango_layout_set_text :: proc "c" (layout: ^Layout, text: [^]u8, length: i32) ---

    /** pango_layout_set_font_description: Sets the default font description for the layout. */
    pango_layout_set_font_description :: proc "c" (layout: ^Layout, desc: ^Font_Description) ---

    /**
     * pango_layout_set_width:
     *
     * Sets the width to which the lines should be wrapped or ellipsized, in pango units -- multiply pixels by
     * `SCALE`. -1 means no wrapping or ellipsization.
     */
    pango_layout_set_width :: proc "c" (layout: ^Layout, width: i32) ---

    /** pango_layout_set_ellipsize: Sets what to do when text exceeds the layout's width. */
    pango_layout_set_ellipsize :: proc "c" (layout: ^Layout, ellipsize: Ellipsize_Mode) ---

    /** pango_layout_set_wrap: Sets the wrap mode, used when a width is set and ellipsization is off. */
    pango_layout_set_wrap :: proc "c" (layout: ^Layout, wrap: Wrap_Mode) ---

    /** pango_layout_set_alignment: Sets the alignment of partial lines within the layout's width. */
    pango_layout_set_alignment :: proc "c" (layout: ^Layout, alignment: Alignment) ---

    /**
     * pango_layout_get_pixel_size:
     *
     * The logical width and height of the layout, already divided by `SCALE`. This is how the renderer learns the
     * rendered bounds it needs for row heights and for the click-off hit test.
     */
    pango_layout_get_pixel_size :: proc "c" (layout: ^Layout, width, height: ^i32) ---

    /**
     * pango_font_description_from_string:
     *
     * Creates a font description from a string like "DejaVu Sans Mono 11" -- a family name resolved through
     * fontconfig, which is what replaces the hardcoded `FONT_PATHS` hunt.
     */
    pango_font_description_from_string :: proc "c" (str: cstring) -> ^Font_Description ---

    /** pango_font_description_free: Frees a font description. */
    pango_font_description_free :: proc "c" (desc: ^Font_Description) ---
}

foreign gobject {
    /** g_object_unref: Decreases the reference count of a GObject, freeing it at zero. Releases a `Layout`. */
    g_object_unref :: proc "c" (object: rawptr) ---
}
