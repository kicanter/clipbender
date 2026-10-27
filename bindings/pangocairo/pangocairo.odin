package pangocairo

import cairo "bindings:cairo"
import pango "bindings:pango"

foreign import pangocairo "system:pangocairo-1.0"

foreign pangocairo {
    /**
     * pango_cairo_create_layout:
     *
     * Creates a layout configured for the given cairo context -- font options, resolution and transformation are
     * taken from @cr at creation time. Release with `pango.g_object_unref`.
     *
     * Created once per context rather than per frame: the popup's text changes, not its rendering target.
     */
    pango_cairo_create_layout :: proc "c" (cr: ^cairo.Context) -> ^pango.Layout ---

    /**
     * pango_cairo_update_layout:
     *
     * Updates a layout to match the current state of @cr. Needed after changing the context's transformation or font
     * options -- notably after the scale factor changes under `fractional-scale-v1`.
     */
    pango_cairo_update_layout :: proc "c" (cr: ^cairo.Context, layout: ^pango.Layout) ---

    /**
     * pango_cairo_show_layout:
     *
     * Draws @layout onto @cr at the context's current point, which `cairo_move_to` sets. This is the call that
     * replaces the hand-rolled glyph blitting.
     */
    pango_cairo_show_layout :: proc "c" (cr: ^cairo.Context, layout: ^pango.Layout) ---

    /**
     * pango_cairo_create_context:
     *
     * A `PangoContext` configured for @cr, for the case where layouts are created from the context rather than
     * directly from the cairo context. Not needed by `pango_cairo_create_layout`.
     */
    pango_cairo_create_context :: proc "c" (cr: ^cairo.Context) -> ^pango.Pango_Context ---
}
