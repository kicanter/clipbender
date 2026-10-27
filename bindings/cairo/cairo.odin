package cairo

foreign import cairo "system:cairo"

/**
 * cairo_t:
 *
 * A #cairo_t contains the current state of the rendering device, including
 * coordinates of yet to be drawn shapes.
 */
Context :: struct {}

/**
 * cairo_surface_t:
 *
 * A #cairo_surface_t represents an image, either as the destination of a
 * drawing operation or as source when drawing onto another surface.
 */
Surface :: struct {}

/**
 * cairo_format_t:
 *
 * Used to identify the memory format of image data.
 *
 * `ARGB32` is 32-bit with alpha in the upper 8 bits, then red, green, blue. The 32-bit quantities are
 * stored native-endian, and **pre-multiplied** alpha is used -- which is also what Wayland's `argb8888` means, so a
 * `wl_shm` buffer can back a surface of this format with no conversion.
 */
Format :: enum i32 {
    INVALID   = -1,
    ARGB32    = 0,
    RGB24     = 1,
    A8        = 2,
    A1        = 3,
    RGB16_565 = 4,
    RGB30     = 5,
    RGB96F    = 6,
    RGBA128F  = 7,
}

/**
 * cairo_status_t:
 *
 * Used to indicate errors that can occur when using cairo. A cairo context or surface carries its error state rather
 * than returning it per call, so `cairo_status` / `cairo_surface_status` is how a failure surfaces.
 *
 * Partial: only the statuses the renderer can plausibly hit are named. Cairo may return a value outside this set, so
 * compare against `.SUCCESS` rather than switching exhaustively.
 */
Status :: enum i32 {
    SUCCESS               = 0,
    NO_MEMORY             = 1,
    INVALID_RESTORE       = 2,
    INVALID_POP_GROUP     = 3,
    NO_CURRENT_POINT      = 4,
    INVALID_MATRIX        = 5,
    INVALID_STATUS        = 6,
    NULL_POINTER          = 7,
    INVALID_STRING        = 8,
    INVALID_PATH_DATA     = 9,
    READ_ERROR            = 10,
    WRITE_ERROR           = 11,
    SURFACE_FINISHED      = 12,
    SURFACE_TYPE_MISMATCH = 13,
    PATTERN_TYPE_MISMATCH = 14,
    INVALID_CONTENT       = 15,
    INVALID_FORMAT        = 16,
    INVALID_VISUAL        = 17,
    FILE_NOT_FOUND        = 18,
    INVALID_DASH          = 19,
}

/**
 * cairo_operator_t:
 *
 * The compositing operator for all drawing operations. Partial: the renderer needs `OVER` (the default, for drawing
 * onto the panel) and `SOURCE` (to write translucent pixels *replacing* what is under them, rather than blending with
 * stale frame contents).
 */
Operator :: enum i32 {
    CLEAR  = 0,
    SOURCE = 1,
    OVER   = 2,
}

foreign cairo {
    /**
     * cairo_image_surface_create_for_data:
     *
     * Creates an image surface for the provided pixel data. The output buffer must be kept around until the
     * surface is destroyed. The initial contents of @data will be used as the initial image contents; you must
     * explicitly clear the buffer, using, for example, cairo_rectangle() and cairo_fill() if you want it cleared.
     *
     * This is how the popup draws: @data is the already-mapped `wl_shm` memory, so cairo composites straight into
     * the buffer the compositor reads.
     */
    cairo_image_surface_create_for_data :: proc "c" (data: [^]u8, format: Format, width, height, stride: i32) -> ^Surface ---

    /**
     * cairo_image_surface_create:
     *
     * Creates an image surface of the specified format and dimensions. Cairo owns the memory. Used by the PNG spike,
     * where there is no shm buffer to borrow.
     */
    cairo_image_surface_create :: proc "c" (format: Format, width, height: i32) -> ^Surface ---

    /**
     * cairo_format_stride_for_width:
     *
     * Provides a stride value that will respect all alignment requirements of the accelerated image-rendering code
     * within cairo. Returns a negative value on error.
     *
     * Worth calling even when the stride seems obvious: it is the cheap way to assert this binding's `Format` values
     * match the installed cairo, since a wrong `ARGB32` would otherwise fail silently as garbage pixels.
     */
    cairo_format_stride_for_width :: proc "c" (format: Format, width: i32) -> i32 ---

    /** cairo_create: Creates a new context with all graphics state parameters set to default values. */
    cairo_create :: proc "c" (target: ^Surface) -> ^Context ---

    /** cairo_destroy: Decreases the reference count on @cr by one, freeing it when the count reaches zero. */
    cairo_destroy :: proc "c" (cr: ^Context) ---

    /** cairo_surface_destroy: Decreases the reference count on @surface by one, freeing it at zero. */
    cairo_surface_destroy :: proc "c" (surface: ^Surface) ---

    /**
     * cairo_surface_flush:
     *
     * Performs any pending drawing and restores any temporary modifications cairo has made. Must be called before
     * reading the backing memory from outside cairo -- i.e. before handing the `wl_shm` buffer to the compositor.
     */
    cairo_surface_flush :: proc "c" (surface: ^Surface) ---

    /** cairo_status: Checks whether an error has previously occurred for this context. */
    cairo_status :: proc "c" (cr: ^Context) -> Status ---

    /** cairo_surface_status: Checks whether an error has previously occurred for this surface. */
    cairo_surface_status :: proc "c" (surface: ^Surface) -> Status ---

    /** cairo_status_to_string: Provides a human-readable description of a #cairo_status_t. */
    cairo_status_to_string :: proc "c" (status: Status) -> cstring ---

    /** cairo_set_source_rgba: Sets the source pattern to a translucent colour. Components range from 0.0 to 1.0. */
    cairo_set_source_rgba :: proc "c" (cr: ^Context, red, green, blue, alpha: f64) ---

    /** cairo_set_operator: Sets the compositing operator for all drawing operations via @cr. */
    cairo_set_operator :: proc "c" (cr: ^Context, op: Operator) ---

    /** cairo_set_line_width: Sets the current line width within the cairo context. */
    cairo_set_line_width :: proc "c" (cr: ^Context, width: f64) ---

    /**
     * cairo_move_to:
     *
     * Begins a new sub-path and sets the current point. Needed to position text: `pango_cairo_show_layout` draws at
     * the context's current point rather than taking coordinates.
     */
    cairo_move_to :: proc "c" (cr: ^Context, x, y: f64) ---

    /** cairo_rectangle: Adds a closed sub-path rectangle to the current path. */
    cairo_rectangle :: proc "c" (cr: ^Context, x, y, width, height: f64) ---

    /**
     * cairo_arc:
     *
     * Adds a circular arc of the given @radius to the current path, in the direction of increasing angles. Angles
     * are in radians. Four of these plus `cairo_new_sub_path` is how the rounded panel is built.
     */
    cairo_arc :: proc "c" (cr: ^Context, xc, yc, radius, angle1, angle2: f64) ---

    /**
     * cairo_new_sub_path:
     *
     * Begins a new sub-path. Note that the existing path is not affected. After this call there will be no current
     * point. Needed before the first `cairo_arc` of a rounded rectangle, or cairo draws a line from wherever the
     * current point happens to be to the start of the arc.
     */
    cairo_new_sub_path :: proc "c" (cr: ^Context) ---

    /** cairo_close_path: Adds a line segment to the path from the current point to the beginning of the sub-path. */
    cairo_close_path :: proc "c" (cr: ^Context) ---

    /** cairo_fill: A drawing operator that fills the current path, then clears it. */
    cairo_fill :: proc "c" (cr: ^Context) ---

    /** cairo_fill_preserve: Like cairo_fill(), but preserves the path -- so the same shape can then be stroked. */
    cairo_fill_preserve :: proc "c" (cr: ^Context) ---

    /** cairo_stroke: A drawing operator that strokes the current path, then clears it. */
    cairo_stroke :: proc "c" (cr: ^Context) ---

    /** cairo_paint: A drawing operator that paints the current source everywhere within the current clip region. */
    cairo_paint :: proc "c" (cr: ^Context) ---

    /** cairo_save: Makes a copy of the current state and saves it on an internal stack. */
    cairo_save :: proc "c" (cr: ^Context) ---

    /** cairo_restore: Restores to the state saved by a preceding call to cairo_save(). */
    cairo_restore :: proc "c" (cr: ^Context) ---

    /** cairo_translate: Modifies the current transformation by translating the user-space origin. */
    cairo_translate :: proc "c" (cr: ^Context, tx, ty: f64) ---

    /**
     * cairo_surface_write_to_png:
     *
     * Writes the contents of @surface to a new file @filename as a PNG image.
     *
     * Only used by the binding spike, which proves cairo, pango and the font stack work with no compositor in the
     * picture. Keeping it costs one declaration and makes that check repeatable.
     */
    cairo_surface_write_to_png :: proc "c" (surface: ^Surface, filename: cstring) -> Status ---
}
