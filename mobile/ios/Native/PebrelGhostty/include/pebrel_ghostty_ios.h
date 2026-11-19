#ifndef PEBREL_GHOSTTY_IOS_H
#define PEBREL_GHOSTTY_IOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PEBREL_EXPORT
#define PEBREL_EXPORT __attribute__((visibility("default")))
#endif

/* Platform-independent key codes mapped onto libghostty-vt GhosttyKey. */
typedef enum {
    PEBREL_KEY_UNIDENTIFIED = 0,
    PEBREL_KEY_A = 1, /* 1..26 -> A..Z */
    PEBREL_KEY_Z = 26,
    PEBREL_KEY_DIGIT_0 = 30, /* 30..39 -> 0..9 */
    PEBREL_KEY_DIGIT_9 = 39,
    PEBREL_KEY_F1 = 40, /* 40..51 -> F1..F12 */
    PEBREL_KEY_F12 = 51,
    PEBREL_KEY_ARROW_UP = 60,
    PEBREL_KEY_ARROW_DOWN = 61,
    PEBREL_KEY_ARROW_LEFT = 62,
    PEBREL_KEY_ARROW_RIGHT = 63,
    PEBREL_KEY_TAB = 64,
    PEBREL_KEY_SPACE = 65,
    PEBREL_KEY_ENTER = 66,
    PEBREL_KEY_BACKSPACE = 67,
    PEBREL_KEY_PAGE_UP = 68,
    PEBREL_KEY_PAGE_DOWN = 69,
    PEBREL_KEY_ESCAPE = 70,
    PEBREL_KEY_DELETE = 71,
    PEBREL_KEY_HOME = 72,
    PEBREL_KEY_END = 73,
    PEBREL_KEY_INSERT = 74
} PebrelKeyCode;

typedef struct {
    int32_t columns;
    int32_t rows;
    int32_t cursor_x;
    int32_t cursor_y;
    int32_t cursor_visible;
    uint32_t background;
    uint32_t cursor_color;
    int32_t cursor_style;
    int32_t scroll_total;
    int32_t scroll_offset;
    int32_t alternate_screen;
} PebrelTerminalMeta;

typedef struct {
    int32_t row_index;
    uint16_t *utf16_ptr;
    size_t utf16_len;
    int32_t *cells_ptr; /* columns * 6 ints: [start, len, width, fg, bg, flags] */
    size_t cells_len;
} PebrelDirtyRow;

typedef struct {
    PebrelTerminalMeta meta;
    PebrelDirtyRow *dirty_rows;
    size_t dirty_row_count;
} PebrelRenderSnapshot;

typedef struct {
    uint8_t *ptr;
    size_t len;
} PebrelTermBytes;

PEBREL_EXPORT int64_t pebrel_term_create(int32_t cols, int32_t rows, int32_t scrollback, const char **out_error);
PEBREL_EXPORT void pebrel_term_destroy(int64_t handle);

PEBREL_EXPORT bool pebrel_term_feed(
    int64_t handle,
    const uint8_t *input,
    size_t count,
    PebrelTermBytes *out_replies,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_title(
    int64_t handle,
    bool *out_changed,
    PebrelTermBytes *out_title,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_synchronized_output(
    int64_t handle,
    bool *out_enabled,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_end_synchronized_output(int64_t handle, const char **out_error);

PEBREL_EXPORT bool pebrel_term_resize(
    int64_t handle,
    int32_t cols,
    int32_t rows,
    int32_t cell_width,
    int32_t cell_height,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_render(
    int64_t handle,
    PebrelRenderSnapshot *out_snapshot,
    const char **out_error
);

PEBREL_EXPORT void pebrel_term_scroll(int64_t handle, int32_t delta);
PEBREL_EXPORT void pebrel_term_scroll_to(int64_t handle, int32_t offset);

PEBREL_EXPORT int32_t pebrel_term_application_scroll_mode(int64_t handle, const char **out_error);

PEBREL_EXPORT bool pebrel_term_wheel(
    int64_t handle,
    int32_t lines,
    int32_t column,
    int32_t row,
    bool application_only,
    PebrelTermBytes *out_bytes,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_colors(
    int64_t handle,
    const uint32_t *values_19,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_key(
    int64_t handle,
    int32_t code,
    int32_t mods,
    int32_t action,
    const uint8_t *utf8_text,
    size_t utf8_len,
    uint32_t unshifted_codepoint,
    PebrelTermBytes *out_bytes,
    const char **out_error
);

PEBREL_EXPORT bool pebrel_term_bracketed_paste(int64_t handle);

PEBREL_EXPORT void pebrel_term_free_bytes(PebrelTermBytes *bytes);
PEBREL_EXPORT void pebrel_term_free_snapshot(PebrelRenderSnapshot *snapshot);

#ifdef __cplusplus
}
#endif

#endif /* PEBREL_GHOSTTY_IOS_H */
