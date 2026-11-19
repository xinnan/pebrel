#include "pebrel_ghostty_ios.h"

#include <ghostty/vt.h>

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace {

struct Terminal {
    GhosttyTerminal vt = nullptr;
    GhosttyRenderState render = nullptr;
    GhosttyRenderStateRowIterator rows = nullptr;
    GhosttyRenderStateRowCells cells = nullptr;
    GhosttyKeyEncoder encoder = nullptr;
    GhosttyKeyEvent event = nullptr;
    GhosttyMouseEncoder mouse_encoder = nullptr;
    GhosttyMouseEvent mouse_event = nullptr;
    uint32_t columns = 80;
    uint32_t height = 24;
    uint32_t cell_width = 1;
    uint32_t cell_height = 1;
    std::vector<uint8_t> replies;
    bool overflow = false;
    bool force = true;
    bool title_changed = false;
    uint64_t history_rows = 1000;

    GhosttyTerminalScrollbar bounded_scrollbar();
    void seek_history(uint64_t offset);
    ~Terminal();
};

Terminal::~Terminal() {
    ghostty_mouse_event_free(mouse_event);
    ghostty_mouse_encoder_free(mouse_encoder);
    ghostty_key_event_free(event);
    ghostty_key_encoder_free(encoder);
    ghostty_render_state_row_cells_free(cells);
    ghostty_render_state_row_iterator_free(rows);
    ghostty_render_state_free(render);
    ghostty_terminal_free(vt);
}

inline Terminal *as_terminal(int64_t handle) {
    return reinterpret_cast<Terminal *>(static_cast<intptr_t>(handle));
}

inline void clear_error(const char **out_error) {
    if (out_error) *out_error = nullptr;
}

inline void set_error(const char **out_error, const char *message) {
    if (out_error) *out_error = message;
}

inline bool checked(const char **out_error, GhosttyResult result) {
    if (result == GHOSTTY_SUCCESS) return true;
    set_error(out_error, "terminal_engine_failed");
    return false;
}

inline uint32_t argb(GhosttyColorRgb color) {
    return 0xff000000u | (static_cast<uint32_t>(color.r) << 16) |
           (static_cast<uint32_t>(color.g) << 8) | static_cast<uint32_t>(color.b);
}

inline GhosttyColorRgb rgb(uint32_t value) {
    return {
        static_cast<uint8_t>((value >> 16) & 0xffu),
        static_cast<uint8_t>((value >> 8) & 0xffu),
        static_cast<uint8_t>(value & 0xffu),
    };
}

void write_reply(GhosttyTerminal, void *userdata, const uint8_t *data, size_t length) {
    auto *state = static_cast<Terminal *>(userdata);
    if (length > 65536 - state->replies.size()) {
        state->overflow = true;
        return;
    }
    state->replies.insert(state->replies.end(), data, data + length);
}

void title_changed_cb(GhosttyTerminal, void *userdata) {
    static_cast<Terminal *>(userdata)->title_changed = true;
}

uint64_t history_start(const Terminal &state, const GhosttyTerminalScrollbar &bar) {
    const uint64_t available = bar.total > bar.len ? bar.total - bar.len : 0;
    return available > state.history_rows ? available - state.history_rows : 0;
}

void seek_native(Terminal &state, uint64_t offset) {
    GhosttyTerminalScrollViewport value{};
    value.tag = GHOSTTY_SCROLL_VIEWPORT_TOP;
    ghostty_terminal_scroll_viewport(state.vt, value);
    value.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    value.value.delta = static_cast<int64_t>(offset);
    ghostty_terminal_scroll_viewport(state.vt, value);
    state.force = true;
}

GhosttyTerminalScrollbar Terminal::bounded_scrollbar() {
    GhosttyTerminalScrollbar bar{};
    ghostty_terminal_get(vt, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    const auto first = history_start(*this, bar);
    if (bar.offset < first) {
        seek_native(*this, first);
        bar.offset = first;
    }
    bar.total -= first;
    bar.offset -= first;
    return bar;
}

void Terminal::seek_history(uint64_t offset) {
    GhosttyTerminalScrollbar bar{};
    ghostty_terminal_get(vt, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    const auto first = history_start(*this, bar);
    const auto maximum = bar.total > bar.len ? bar.total - bar.len : 0;
    seek_native(*this, std::min(first + offset, maximum));
}

bool copy_out_bytes(const uint8_t *data, size_t count, PebrelTermBytes *out, const char **out_error) {
    if (!out) {
        set_error(out_error, "invalid_input");
        return false;
    }
    out->ptr = nullptr;
    out->len = 0;
    if (count == 0) return true;
    auto *buffer = static_cast<uint8_t *>(std::malloc(count));
    if (!buffer) {
        set_error(out_error, "out_of_memory");
        return false;
    }
    std::memcpy(buffer, data, count);
    out->ptr = buffer;
    out->len = count;
    return true;
}

void append_utf16(std::vector<uint16_t> &target, uint32_t codepoint) {
    if (codepoint > 0x10ffffu || (codepoint >= 0xd800u && codepoint <= 0xdfffu)) {
        codepoint = 0xfffdu;
    }
    if (codepoint <= 0xffffu) {
        target.push_back(static_cast<uint16_t>(codepoint));
    } else {
        codepoint -= 0x10000u;
        target.push_back(static_cast<uint16_t>(0xd800u + (codepoint >> 10)));
        target.push_back(static_cast<uint16_t>(0xdc00u + (codepoint & 0x3ffu)));
    }
}

GhosttyKey map_key(int32_t code) {
    if (code >= PEBREL_KEY_A && code <= PEBREL_KEY_Z) {
        return static_cast<GhosttyKey>(GHOSTTY_KEY_A + (code - PEBREL_KEY_A));
    }
    if (code >= PEBREL_KEY_DIGIT_0 && code <= PEBREL_KEY_DIGIT_9) {
        return static_cast<GhosttyKey>(GHOSTTY_KEY_DIGIT_0 + (code - PEBREL_KEY_DIGIT_0));
    }
    if (code >= PEBREL_KEY_F1 && code <= PEBREL_KEY_F12) {
        return static_cast<GhosttyKey>(GHOSTTY_KEY_F1 + (code - PEBREL_KEY_F1));
    }
    switch (code) {
        case PEBREL_KEY_ARROW_UP: return GHOSTTY_KEY_ARROW_UP;
        case PEBREL_KEY_ARROW_DOWN: return GHOSTTY_KEY_ARROW_DOWN;
        case PEBREL_KEY_ARROW_LEFT: return GHOSTTY_KEY_ARROW_LEFT;
        case PEBREL_KEY_ARROW_RIGHT: return GHOSTTY_KEY_ARROW_RIGHT;
        case PEBREL_KEY_TAB: return GHOSTTY_KEY_TAB;
        case PEBREL_KEY_SPACE: return GHOSTTY_KEY_SPACE;
        case PEBREL_KEY_ENTER: return GHOSTTY_KEY_ENTER;
        case PEBREL_KEY_BACKSPACE: return GHOSTTY_KEY_BACKSPACE;
        case PEBREL_KEY_PAGE_UP: return GHOSTTY_KEY_PAGE_UP;
        case PEBREL_KEY_PAGE_DOWN: return GHOSTTY_KEY_PAGE_DOWN;
        case PEBREL_KEY_ESCAPE: return GHOSTTY_KEY_ESCAPE;
        case PEBREL_KEY_DELETE: return GHOSTTY_KEY_DELETE;
        case PEBREL_KEY_HOME: return GHOSTTY_KEY_HOME;
        case PEBREL_KEY_END: return GHOSTTY_KEY_END;
        case PEBREL_KEY_INSERT: return GHOSTTY_KEY_INSERT;
        default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

}  // namespace

extern "C" {

int64_t pebrel_term_create(int32_t cols, int32_t rows, int32_t scrollback, const char **out_error) {
    clear_error(out_error);
    if (cols < 2 || cols > 400 || rows < 2 || rows > 200 || scrollback < 0 || scrollback > 5000) {
        set_error(out_error, "invalid_input");
        return 0;
    }
    try {
        auto state = std::make_unique<Terminal>();
        state->columns = static_cast<uint32_t>(cols);
        state->height = static_cast<uint32_t>(rows);
        state->history_rows = static_cast<uint64_t>(scrollback);
        const size_t history_bytes = scrollback == 0
            ? 0
            : std::min(size_t{16 * 1024 * 1024},
                       static_cast<size_t>(scrollback) * (400 + 1) * sizeof(uint64_t) * 2 + 128 * 1024);
        if (!checked(out_error, ghostty_terminal_new(nullptr, &state->vt,
                {static_cast<uint16_t>(cols), static_cast<uint16_t>(rows), history_bytes})) ||
            !checked(out_error, ghostty_render_state_new(nullptr, &state->render)) ||
            !checked(out_error, ghostty_render_state_row_iterator_new(nullptr, &state->rows)) ||
            !checked(out_error, ghostty_render_state_row_cells_new(nullptr, &state->cells)) ||
            !checked(out_error, ghostty_key_encoder_new(nullptr, &state->encoder)) ||
            !checked(out_error, ghostty_key_event_new(nullptr, &state->event)) ||
            !checked(out_error, ghostty_mouse_encoder_new(nullptr, &state->mouse_encoder)) ||
            !checked(out_error, ghostty_mouse_event_new(nullptr, &state->mouse_event))) {
            return 0;
        }
        ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_USERDATA, state.get());
        ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(write_reply));
        ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, reinterpret_cast<const void *>(title_changed_cb));
        size_t no_images = 0;
        ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &no_images);
        return static_cast<int64_t>(reinterpret_cast<intptr_t>(state.release()));
    } catch (...) {
        set_error(out_error, "terminal_engine_failed");
        return 0;
    }
}

void pebrel_term_destroy(int64_t handle) {
    if (handle != 0) {
        delete as_terminal(handle);
    }
}

bool pebrel_term_feed(
    int64_t handle,
    const uint8_t *input,
    size_t count,
    PebrelTermBytes *out_replies,
    const char **out_error
) {
    clear_error(out_error);
    if (handle == 0 || (!input && count > 0) || count > 65536 || !out_replies) {
        set_error(out_error, "invalid_input");
        return false;
    }
    try {
        auto *state = as_terminal(handle);
        state->replies.clear();
        state->overflow = false;
        if (count > 0) {
            ghostty_terminal_vt_write(state->vt, input, count);
        }
        if (state->overflow) {
            set_error(out_error, "terminal_reply_overflow");
            return false;
        }
        return copy_out_bytes(state->replies.data(), state->replies.size(), out_replies, out_error);
    } catch (...) {
        set_error(out_error, "terminal_engine_failed");
        return false;
    }
}

bool pebrel_term_title(
    int64_t handle,
    bool *out_changed,
    PebrelTermBytes *out_title,
    const char **out_error
) {
    clear_error(out_error);
    if (handle == 0 || !out_changed || !out_title) {
        set_error(out_error, "invalid_input");
        return false;
    }
    *out_changed = false;
    out_title->ptr = nullptr;
    out_title->len = 0;
    auto *state = as_terminal(handle);
    if (!state->title_changed) return true;
    state->title_changed = false;
    *out_changed = true;
    GhosttyString title{};
    ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_TITLE, &title);
    const size_t len = std::min(title.len, size_t{512});
    return copy_out_bytes(title.ptr, len, out_title, out_error);
}

bool pebrel_term_synchronized_output(int64_t handle, bool *out_enabled, const char **out_error) {
    clear_error(out_error);
    if (handle == 0 || !out_enabled) {
        set_error(out_error, "invalid_input");
        return false;
    }
    bool enabled = false;
    if (!checked(out_error, ghostty_terminal_mode_get(as_terminal(handle)->vt, GHOSTTY_MODE_SYNC_OUTPUT, &enabled))) {
        return false;
    }
    *out_enabled = enabled;
    return true;
}

bool pebrel_term_end_synchronized_output(int64_t handle, const char **out_error) {
    clear_error(out_error);
    if (handle == 0) {
        set_error(out_error, "invalid_input");
        return false;
    }
    return checked(out_error, ghostty_terminal_mode_set(as_terminal(handle)->vt, GHOSTTY_MODE_SYNC_OUTPUT, false));
}

bool pebrel_term_resize(
    int64_t handle,
    int32_t cols,
    int32_t rows,
    int32_t cell_width,
    int32_t cell_height,
    const char **out_error
) {
    clear_error(out_error);
    if (handle == 0 || cols < 2 || cols > 400 || rows < 2 || rows > 200 ||
        cell_width < 1 || cell_width > 256 || cell_height < 1 || cell_height > 256) {
        set_error(out_error, "invalid_input");
        return false;
    }
    auto *state = as_terminal(handle);
    if (!checked(out_error, ghostty_terminal_resize(
            state->vt,
            static_cast<uint16_t>(cols),
            static_cast<uint16_t>(rows),
            static_cast<uint32_t>(cell_width),
            static_cast<uint32_t>(cell_height)))) {
        return false;
    }
    state->columns = static_cast<uint32_t>(cols);
    state->height = static_cast<uint32_t>(rows);
    state->cell_width = static_cast<uint32_t>(cell_width);
    state->cell_height = static_cast<uint32_t>(cell_height);
    state->force = true;
    return true;
}

bool pebrel_term_render(int64_t handle, PebrelRenderSnapshot *out_snapshot, const char **out_error) {
    clear_error(out_error);
    if (handle == 0 || !out_snapshot) {
        set_error(out_error, "invalid_input");
        return false;
    }
    std::memset(out_snapshot, 0, sizeof(*out_snapshot));
    try {
        auto *state = as_terminal(handle);
        const auto scrollbar = state->bounded_scrollbar();
        if (!checked(out_error, ghostty_render_state_update(state->render, state->vt))) {
            return false;
        }
        uint16_t columns = 0, rows = 0, cx = 0, cy = 0;
        bool visible = false, in_viewport = false;
        GhosttyRenderStateDirty dirty{};
        GhosttyRenderStateCursorVisualStyle cursor_style{};
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_COLS, &columns);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &in_viewport);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);
        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_style);

        GhosttyRenderStateColors colors{};
        colors.size = sizeof(colors);
        if (!checked(out_error, ghostty_render_state_colors_get(state->render, &colors))) {
            return false;
        }
        GhosttyTerminalScreen screen{};
        ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);

        out_snapshot->meta.columns = columns;
        out_snapshot->meta.rows = rows;
        out_snapshot->meta.cursor_x = cx;
        out_snapshot->meta.cursor_y = cy;
        out_snapshot->meta.cursor_visible = (visible && in_viewport) ? 1 : 0;
        out_snapshot->meta.background = argb(colors.background);
        out_snapshot->meta.cursor_color = argb(colors.cursor_has_value ? colors.cursor : colors.foreground);
        out_snapshot->meta.cursor_style = static_cast<int32_t>(cursor_style);
        out_snapshot->meta.scroll_total = static_cast<int32_t>(std::min(scrollbar.total, uint64_t{INT32_MAX}));
        out_snapshot->meta.scroll_offset = static_cast<int32_t>(std::min(scrollbar.offset, uint64_t{INT32_MAX}));
        out_snapshot->meta.alternate_screen = (screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE) ? 1 : 0;

        ghostty_render_state_get(state->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &state->rows);
        std::vector<uint32_t> codepoints;
        std::vector<uint16_t> text;
        std::vector<int32_t> cells(static_cast<size_t>(columns) * 6);
        std::vector<PebrelDirtyRow> dirty_rows;
        int32_t y = -1;

        while (ghostty_render_state_row_iterator_next(state->rows)) {
            ++y;
            bool row_dirty = false;
            ghostty_render_state_row_get(state->rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &row_dirty);
            if (!state->force && dirty != GHOSTTY_RENDER_STATE_DIRTY_FULL && !row_dirty) continue;

            text.clear();
            std::fill(cells.begin(), cells.end(), 0);
            ghostty_render_state_row_get(state->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &state->cells);
            uint32_t x = 0;
            while (ghostty_render_state_row_cells_next(state->cells) && x < columns) {
                GhosttyCell raw{};
                GhosttyCellWide width{};
                ghostty_render_state_row_cells_get(state->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &width);

                auto foreground = colors.foreground;
                auto background = colors.background;
                ghostty_render_state_row_cells_get(state->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground);
                ghostty_render_state_row_cells_get(state->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background);

                GhosttyStyle style{};
                style.size = sizeof(style);
                ghostty_render_state_row_cells_get(state->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
                if (style.inverse) std::swap(foreground, background);

                const int32_t cell_width = width == GHOSTTY_CELL_WIDE_WIDE ? 2
                    : (width == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0);
                const int32_t start = static_cast<int32_t>(text.size());
                uint32_t length = 0;
                ghostty_render_state_row_cells_get(state->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length);
                if (cell_width != 0) {
                    if (length > 0) {
                        codepoints.resize(length);
                        ghostty_render_state_row_cells_get(
                            state->cells,
                            GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                            codepoints.data());
                        for (uint32_t cp : codepoints) append_utf16(text, cp);
                    } else {
                        text.push_back(static_cast<uint16_t>(' '));
                    }
                }
                int32_t *cell = cells.data() + static_cast<size_t>(x) * 6;
                cell[0] = start;
                cell[1] = static_cast<int32_t>(text.size()) - start;
                cell[2] = cell_width;
                cell[3] = static_cast<int32_t>(argb(foreground));
                cell[4] = static_cast<int32_t>(argb(background));
                cell[5] = (style.bold ? 1 : 0) | (style.italic ? 2 : 0) | (style.underline ? 4 : 0) |
                          (style.strikethrough ? 8 : 0) | (style.faint ? 16 : 0) | (style.invisible ? 32 : 0);
                ++x;
            }

            PebrelDirtyRow row_out{};
            row_out.row_index = y;
            if (!text.empty()) {
                row_out.utf16_ptr = static_cast<uint16_t *>(std::malloc(text.size() * sizeof(uint16_t)));
                if (!row_out.utf16_ptr) {
                    for (auto &d : dirty_rows) {
                        std::free(d.utf16_ptr);
                        std::free(d.cells_ptr);
                    }
                    set_error(out_error, "out_of_memory");
                    return false;
                }
                std::memcpy(row_out.utf16_ptr, text.data(), text.size() * sizeof(uint16_t));
                row_out.utf16_len = text.size();
            }
            if (!cells.empty()) {
                row_out.cells_ptr = static_cast<int32_t *>(std::malloc(cells.size() * sizeof(int32_t)));
                if (!row_out.cells_ptr) {
                    std::free(row_out.utf16_ptr);
                    for (auto &d : dirty_rows) {
                        std::free(d.utf16_ptr);
                        std::free(d.cells_ptr);
                    }
                    set_error(out_error, "out_of_memory");
                    return false;
                }
                std::memcpy(row_out.cells_ptr, cells.data(), cells.size() * sizeof(int32_t));
                row_out.cells_len = cells.size();
            }
            dirty_rows.push_back(row_out);

            bool clean = false;
            ghostty_render_state_row_set(state->rows, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);
        }

        if (!dirty_rows.empty()) {
            out_snapshot->dirty_rows =
                static_cast<PebrelDirtyRow *>(std::malloc(dirty_rows.size() * sizeof(PebrelDirtyRow)));
            if (!out_snapshot->dirty_rows) {
                for (auto &d : dirty_rows) {
                    std::free(d.utf16_ptr);
                    std::free(d.cells_ptr);
                }
                set_error(out_error, "out_of_memory");
                return false;
            }
            std::memcpy(out_snapshot->dirty_rows, dirty_rows.data(), dirty_rows.size() * sizeof(PebrelDirtyRow));
            out_snapshot->dirty_row_count = dirty_rows.size();
        }

        state->force = false;
        const GhosttyRenderStateDirty clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        ghostty_render_state_set(state->render, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean);
        return true;
    } catch (...) {
        pebrel_term_free_snapshot(out_snapshot);
        set_error(out_error, "terminal_engine_failed");
        return false;
    }
}

void pebrel_term_scroll(int64_t handle, int32_t delta) {
    if (handle == 0) return;
    auto *state = as_terminal(handle);
    GhosttyTerminalScrollViewport value{};
    value.tag = delta == INT32_MAX ? GHOSTTY_SCROLL_VIEWPORT_BOTTOM : GHOSTTY_SCROLL_VIEWPORT_DELTA;
    value.value.delta = delta;
    ghostty_terminal_scroll_viewport(state->vt, value);
    state->bounded_scrollbar();
    state->force = true;
}

void pebrel_term_scroll_to(int64_t handle, int32_t offset) {
    if (handle == 0) return;
    as_terminal(handle)->seek_history(static_cast<uint64_t>(std::max(offset, 0)));
}

int32_t pebrel_term_application_scroll_mode(int64_t handle, const char **out_error) {
    clear_error(out_error);
    if (handle == 0) {
        set_error(out_error, "invalid_input");
        return 0;
    }
    auto *state = as_terminal(handle);
    GhosttyTerminalScreen screen{};
    if (!checked(out_error, ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen))) {
        return 0;
    }
    if (screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY) return 0;
    bool tracking = false;
    if (!checked(out_error, ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking))) {
        return 0;
    }
    return tracking ? 2 : 1;
}

bool pebrel_term_wheel(
    int64_t handle,
    int32_t lines,
    int32_t column,
    int32_t row,
    bool application_only,
    PebrelTermBytes *out_bytes,
    const char **out_error
) {
    clear_error(out_error);
    if (handle == 0 || !out_bytes) {
        set_error(out_error, "invalid_input");
        return false;
    }
    out_bytes->ptr = nullptr;
    out_bytes->len = 0;
    try {
        auto *state = as_terminal(handle);
        GhosttyTerminalScreen screen{};
        if (!checked(out_error, ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen))) {
            return false;
        }
        if (screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY) {
            if (!application_only) pebrel_term_scroll(handle, lines);
            return true;
        }
        lines = std::clamp(lines, -32, 32);
        if (lines == 0) return true;
        bool tracking = false;
        ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
        char encoded[128];
        size_t count = 0;
        if (tracking) {
            auto encoder = state->mouse_encoder;
            ghostty_mouse_encoder_setopt_from_terminal(encoder, state->vt);
            GhosttyMouseEncoderSize size{};
            size.size = sizeof(size);
            size.cell_width = state->cell_width;
            size.cell_height = state->cell_height;
            size.screen_width = state->columns * size.cell_width;
            size.screen_height = state->height * size.cell_height;
            ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
            ghostty_mouse_event_set_action(state->mouse_event, GHOSTTY_MOUSE_ACTION_PRESS);
            ghostty_mouse_event_set_button(
                state->mouse_event,
                lines < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE);
            ghostty_mouse_event_set_mods(state->mouse_event, 0);
            ghostty_mouse_event_set_position(state->mouse_event, {
                (std::clamp(column, 0, static_cast<int32_t>(state->columns) - 1) + 0.5f) * size.cell_width,
                (std::clamp(row, 0, static_cast<int32_t>(state->height) - 1) + 0.5f) * size.cell_height,
            });
            if (!checked(out_error, ghostty_mouse_encoder_encode(
                    encoder, state->mouse_event, encoded, sizeof(encoded), &count))) {
                return false;
            }
        } else {
            bool alternate_scroll = false;
            ghostty_terminal_mode_get(state->vt, GHOSTTY_MODE_ALT_SCROLL, &alternate_scroll);
            if (!alternate_scroll) return true;
            ghostty_key_encoder_setopt_from_terminal(state->encoder, state->vt);
            ghostty_key_event_set_key(state->event, lines < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN);
            ghostty_key_event_set_action(state->event, GHOSTTY_KEY_ACTION_PRESS);
            ghostty_key_event_set_mods(state->event, 0);
            ghostty_key_event_set_consumed_mods(state->event, 0);
            ghostty_key_event_set_utf8(state->event, "", 0);
            ghostty_key_event_set_unshifted_codepoint(state->event, 0);
            if (!checked(out_error, ghostty_key_encoder_encode(
                    state->encoder, state->event, encoded, sizeof(encoded), &count))) {
                return false;
            }
        }
        std::vector<uint8_t> output;
        output.reserve(count * static_cast<size_t>(std::abs(lines)));
        for (int i = 0; i < std::abs(lines); ++i) {
            output.insert(output.end(), encoded, encoded + count);
        }
        return copy_out_bytes(output.data(), output.size(), out_bytes, out_error);
    } catch (...) {
        set_error(out_error, "terminal_engine_failed");
        return false;
    }
}

bool pebrel_term_colors(int64_t handle, const uint32_t *values_19, const char **out_error) {
    clear_error(out_error);
    if (handle == 0 || !values_19) {
        set_error(out_error, "invalid_input");
        return false;
    }
    auto *state = as_terminal(handle);
    auto fg = rgb(values_19[0]);
    auto bg = rgb(values_19[1]);
    auto cursor = rgb(values_19[2]);
    GhosttyColorRgb palette[256];
    ghostty_terminal_get(state->vt, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette);
    for (int i = 0; i < 16; ++i) {
        palette[i] = rgb(values_19[i + 3]);
    }
    ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
    ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
    ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
    ghostty_terminal_set(state->vt, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette);
    state->force = true;
    return true;
}

bool pebrel_term_key(
    int64_t handle,
    int32_t code,
    int32_t mods,
    int32_t action,
    const uint8_t *utf8_text,
    size_t utf8_len,
    uint32_t unshifted_codepoint,
    PebrelTermBytes *out_bytes,
    const char **out_error
) {
    clear_error(out_error);
    if (handle == 0 || (!utf8_text && utf8_len > 0) || !out_bytes) {
        set_error(out_error, "invalid_input");
        return false;
    }
    out_bytes->ptr = nullptr;
    out_bytes->len = 0;
    auto *state = as_terminal(handle);
    ghostty_key_encoder_setopt_from_terminal(state->encoder, state->vt);
    ghostty_key_event_set_key(state->event, map_key(code));
    ghostty_key_event_set_action(state->event, static_cast<GhosttyKeyAction>(action));
    ghostty_key_event_set_mods(state->event, static_cast<GhosttyMods>(mods));
    ghostty_key_event_set_consumed_mods(state->event, 0);
    ghostty_key_event_set_utf8(
        state->event,
        utf8_text ? reinterpret_cast<const char *>(utf8_text) : "",
        utf8_len);
    ghostty_key_event_set_unshifted_codepoint(state->event, unshifted_codepoint);
    char output[1024];
    size_t count = 0;
    if (!checked(out_error, ghostty_key_encoder_encode(
            state->encoder, state->event, output, sizeof(output), &count))) {
        return false;
    }
    return copy_out_bytes(reinterpret_cast<const uint8_t *>(output), count, out_bytes, out_error);
}

bool pebrel_term_bracketed_paste(int64_t handle) {
    if (handle == 0) return false;
    bool enabled = false;
    ghostty_terminal_mode_get(as_terminal(handle)->vt, GHOSTTY_MODE_BRACKETED_PASTE, &enabled);
    return enabled;
}

void pebrel_term_free_bytes(PebrelTermBytes *bytes) {
    if (!bytes) return;
    if (bytes->ptr) {
        std::free(bytes->ptr);
        bytes->ptr = nullptr;
    }
    bytes->len = 0;
}

void pebrel_term_free_snapshot(PebrelRenderSnapshot *snapshot) {
    if (!snapshot) return;
    if (snapshot->dirty_rows) {
        for (size_t i = 0; i < snapshot->dirty_row_count; ++i) {
            std::free(snapshot->dirty_rows[i].utf16_ptr);
            std::free(snapshot->dirty_rows[i].cells_ptr);
        }
        std::free(snapshot->dirty_rows);
        snapshot->dirty_rows = nullptr;
    }
    snapshot->dirty_row_count = 0;
}

}  // extern "C"
