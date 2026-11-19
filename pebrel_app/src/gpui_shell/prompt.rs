//! Linux-native fallback renderer for `Window::prompt`.
//!
//! `gpui_linux` returns `None` from `PlatformWindow::prompt` on both X11 and
//! Wayland, leaving GPUI to draw `FallbackPromptRenderer` unless the app
//! registers a `PromptBuilder`. The built-in fallback does not occlude events
//! behind it, clips long CJK text inside a fixed white card, ignores Escape and
//! keyboard navigation, and omits `window.refresh()` when `previous_focus` is
//! absent or already restored by leaked clicks.
//!
//! Registering this themed modal view on Linux keeps `Window::prompt` working
//! identically across all callers without overriding macOS/Windows native
//! dialogs or `TestPlatform::prompt`.

use gpui::{
    App, AppContext as _, Context, EventEmitter, FocusHandle, Focusable, InteractiveElement as _,
    IntoElement, KeyDownEvent, MouseButton, MouseDownEvent, ParentElement as _, PromptButton,
    PromptHandle, PromptLevel, PromptResponse, Render, RenderablePromptHandle, SharedString,
    Styled as _, Window, div, prelude::FluentBuilder as _, px, relative,
};

use super::prelude::*;

const PROMPT_CARD_MAX_WIDTH: f32 = 480.0;

#[cfg(target_os = "linux")]
pub(crate) fn init(cx: &mut App) {
    cx.set_prompt_builder(build_prompt);
}

pub(crate) fn build_prompt(
    level: PromptLevel,
    message: &str,
    detail: Option<&str>,
    actions: &[PromptButton],
    handle: PromptHandle,
    window: &mut Window,
    cx: &mut App,
) -> RenderablePromptHandle {
    let actions = actions.to_vec();
    let selected = default_selected_index(&actions);
    let view = cx.new(|cx| WindowPromptView {
        level,
        message: message.to_owned().into(),
        detail: detail.filter(|text| !text.is_empty()).map(|text| text.to_owned().into()),
        actions,
        selected,
        keyboard_focus_visible: false,
        responded: false,
        focus: cx.focus_handle(),
    });
    let renderable = handle.with_view(view, window, cx);
    // Ensure a fresh frame is queued even if focus was already on a non-focusable state.
    window.refresh();
    renderable
}

fn cancel_index(actions: &[PromptButton]) -> Option<usize> {
    actions.iter().position(PromptButton::is_cancel)
}

fn default_selected_index(actions: &[PromptButton]) -> usize {
    if let Some(ix) = actions.iter().position(|action| matches!(action, PromptButton::Ok(_))) {
        return ix;
    }
    if let Some(ix) = actions.iter().rposition(|action| !action.is_cancel()) {
        return ix;
    }
    0
}

fn button_variant(
    level: PromptLevel,
    actions: &[PromptButton],
    action: &PromptButton,
) -> ButtonVariant {
    match action {
        PromptButton::Cancel(_) => ButtonVariant::Secondary,
        PromptButton::Ok(_) => {
            if matches!(level, PromptLevel::Warning | PromptLevel::Critical) && actions.len() <= 2 {
                ButtonVariant::Danger
            } else {
                ButtonVariant::Primary
            }
        },
        PromptButton::Other(_) => {
            if matches!(level, PromptLevel::Warning | PromptLevel::Critical)
                && actions.iter().any(|item| matches!(item, PromptButton::Ok(_)))
            {
                ButtonVariant::Danger
            } else {
                ButtonVariant::Secondary
            }
        },
    }
}

struct WindowPromptView {
    level: PromptLevel,
    message: SharedString,
    detail: Option<SharedString>,
    actions: Vec<PromptButton>,
    selected: usize,
    keyboard_focus_visible: bool,
    responded: bool,
    focus: FocusHandle,
}

impl WindowPromptView {
    fn respond(&mut self, ix: usize, window: &mut Window, cx: &mut Context<'_, Self>) {
        if self.responded || ix >= self.actions.len() {
            return;
        }
        self.responded = true;
        cx.emit(PromptResponse(ix));
        // `PromptHandle::with_view` clears `window.prompt` in an effect observer
        // without calling `window.refresh()` when `previous_focus` is None or
        // already focused. Queue a redraw explicitly so the backdrop never lingers.
        window.refresh();
        cx.stop_propagation();
    }

    fn move_selection(&mut self, delta: isize, window: &mut Window, cx: &mut Context<'_, Self>) {
        let len = self.actions.len();
        if len == 0 {
            return;
        }
        let next = (self.selected as isize + delta).rem_euclid(len as isize) as usize;
        self.selected = next;
        self.keyboard_focus_visible = true;
        cx.notify();
        window.prevent_default();
        cx.stop_propagation();
    }

    fn on_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<'_, Self>,
    ) {
        if self.actions.is_empty() {
            return;
        }
        let key = event.keystroke.key.as_str();
        let mods = &event.keystroke.modifiers;
        let no_ctrl_alt = !mods.control && !mods.alt && !mods.platform && !mods.function;

        if no_ctrl_alt {
            match key {
                "escape" if !mods.shift => {
                    if let Some(cancel) = cancel_index(&self.actions) {
                        self.respond(cancel, window, cx);
                        window.prevent_default();
                        return;
                    }
                },
                "enter" | "space" if !mods.shift => {
                    self.respond(self.selected, window, cx);
                    window.prevent_default();
                    return;
                },
                "tab" => {
                    self.move_selection(if mods.shift { -1 } else { 1 }, window, cx);
                    return;
                },
                "left" | "up" if !mods.shift => {
                    self.move_selection(-1, window, cx);
                    return;
                },
                "right" | "down" if !mods.shift => {
                    self.move_selection(1, window, cx);
                    return;
                },
                _ => {},
            }
        }

        // Keep keystrokes isolated while a modal prompt is open.
        window.prevent_default();
        cx.stop_propagation();
    }
}

impl EventEmitter<PromptResponse> for WindowPromptView {}

impl Focusable for WindowPromptView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for WindowPromptView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<'_, Self>) -> impl IntoElement {
        let theme = cx.theme();
        let card_width =
            PROMPT_CARD_MAX_WIDTH.min((f32::from(window.viewport_size().width) - 32.0).max(240.0));
        let ring_color = theme.ring;
        let show_focus_ring = self.keyboard_focus_visible;
        let selected = self.selected;

        let buttons = self.actions.iter().enumerate().map(|(ix, action)| {
            let variant = button_variant(self.level, &self.actions, action);
            let focused_choice = show_focus_ring && selected == ix;
            let mut button = Button::new(("window-prompt-action", ix))
                .debug_selector(move || format!("window-prompt-action-{ix}"))
                .label(action.label().clone())
                .with_variant(variant)
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.respond(ix, window, cx);
                }));
            if self.actions.len() == 2 {
                button = button.w_full();
            }
            div()
                .when(self.actions.len() == 2, |slot| slot.flex_1().min_w(px(120.0)))
                .rounded(theme.radius)
                .border_2()
                .border_color(if focused_choice { ring_color } else { gpui::transparent_black() })
                .child(button)
        });

        let card = v_flex()
            .id("window-prompt-card")
            .debug_selector(|| "window-prompt-card".to_owned())
            .occlude()
            .cursor_default()
            .w(px(card_width))
            .max_w_full()
            .bg(theme.tokens.background)
            .text_color(theme.foreground)
            .border_1()
            .border_color(theme.border)
            .rounded(theme.radius_lg)
            .shadow_xl()
            .px(px(26.0))
            .pt(px(26.0))
            .pb(px(20.0))
            .gap_3()
            .on_any_mouse_down(|_, _, cx| {
                cx.stop_propagation();
            })
            .child(
                div()
                    .w_full()
                    .min_w_0()
                    .text_lg()
                    .font_semibold()
                    .line_height(relative(1.3))
                    .text_color(theme.foreground)
                    .child(self.message.clone()),
            )
            .when_some(self.detail.clone(), |card, detail| {
                card.child(
                    div()
                        .w_full()
                        .min_w_0()
                        .text_sm()
                        .line_height(relative(1.5))
                        .text_color(theme.muted_foreground)
                        .child(detail),
                )
            })
            .child(
                h_flex()
                    .w_full()
                    .flex_wrap()
                    .gap_2()
                    .pt_2()
                    .when(self.actions.len() != 2, |row| row.justify_end())
                    .children(buttons),
            );

        div()
            .id("window-prompt-overlay")
            .debug_selector(|| "window-prompt-overlay".to_owned())
            .size_full()
            .occlude()
            .bg(theme.overlay)
            .flex()
            .items_center()
            .justify_center()
            .px_4()
            .py_4()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::on_key_down))
            .on_any_mouse_down(cx.listener(|this, event: &MouseDownEvent, window, cx| {
                cx.stop_propagation();
                if event.button == MouseButton::Left
                    && let Some(cancel) = cancel_index(&this.actions)
                {
                    this.respond(cancel, window, cx);
                }
            }))
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(card)
    }
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn button_roles_and_variants_match_prompt_semantics() {
        let close_buttons = [PromptButton::cancel("取消"), PromptButton::ok("保存已知状态并关闭")];
        assert_eq!(cancel_index(&close_buttons), Some(0));
        assert_eq!(default_selected_index(&close_buttons), 1);
        assert_eq!(
            button_variant(PromptLevel::Warning, &close_buttons, &close_buttons[0]),
            ButtonVariant::Secondary
        );
        assert_eq!(
            button_variant(PromptLevel::Warning, &close_buttons, &close_buttons[1]),
            ButtonVariant::Danger
        );
        assert_eq!(
            button_variant(PromptLevel::Info, &close_buttons, &close_buttons[1]),
            ButtonVariant::Primary
        );

        let editor_buttons =
            [PromptButton::ok("保存"), PromptButton::new("放弃"), PromptButton::cancel("取消")];
        assert_eq!(cancel_index(&editor_buttons), Some(2));
        assert_eq!(default_selected_index(&editor_buttons), 0);
        assert_eq!(
            button_variant(PromptLevel::Warning, &editor_buttons, &editor_buttons[0]),
            ButtonVariant::Primary
        );
        assert_eq!(
            button_variant(PromptLevel::Warning, &editor_buttons, &editor_buttons[1]),
            ButtonVariant::Danger
        );
        assert_eq!(
            button_variant(PromptLevel::Warning, &editor_buttons, &editor_buttons[2]),
            ButtonVariant::Secondary
        );
    }
}

#[cfg(all(test, feature = "gpui-test-support"))]
mod tests {
    use std::{cell::Cell, rc::Rc};

    use gpui::{Modifiers, TestAppContext, point, size};
    use gpui_component::Root;

    use super::*;

    struct BackgroundHost {
        background_clicks: Rc<Cell<usize>>,
        background_keys: Rc<Cell<usize>>,
        focus: FocusHandle,
    }

    impl Render for BackgroundHost {
        fn render(&mut self, window: &mut Window, cx: &mut Context<'_, Self>) -> impl IntoElement {
            let clicks = self.background_clicks.clone();
            let keys = self.background_keys.clone();
            div()
                .id("background-host")
                .size_full()
                .track_focus(&self.focus)
                .on_mouse_down(MouseButton::Left, move |_, _, _| {
                    clicks.set(clicks.get() + 1);
                })
                .on_key_down(move |_, _, _| {
                    keys.set(keys.get() + 1);
                })
                .children(Root::render_dialog_layer(window, cx))
        }
    }

    fn open_host(
        cx: &mut TestAppContext,
    ) -> (Rc<Cell<usize>>, Rc<Cell<usize>>, &mut gpui::VisualTestContext) {
        cx.update(|cx| {
            gpui_component::init(cx);
            cx.set_prompt_builder(build_prompt);
        });
        let clicks = Rc::new(Cell::new(0));
        let keys = Rc::new(Cell::new(0));
        let host_clicks = clicks.clone();
        let host_keys = keys.clone();
        let (_, window) = cx.add_window_view(move |window, cx| {
            let view = cx.new(|cx| BackgroundHost {
                background_clicks: host_clicks,
                background_keys: host_keys,
                focus: cx.focus_handle(),
            });
            Root::new(view, window, cx)
        });
        window.simulate_resize(size(px(960.0), px(640.0)));
        (clicks, keys, window)
    }

    #[gpui::test]
    async fn prompt_buttons_work_even_when_unfocused_and_block_background_clicks(
        cx: &mut TestAppContext,
    ) {
        let (clicks, _, window) = open_host(cx);

        let rx = window.update(|window, cx| {
            let rx = window.prompt(
                PromptLevel::Warning,
                "仍有 AI 会话未能识别，继续关闭？",
                Some(
                    "关闭前会保存窗口布局和已知的对话 ID，并停止正在运行的命令。尚未取得 ID 的对话，重新打开后可能需要手动选择。",
                ),
                &[PromptButton::cancel("取消"), PromptButton::ok("保存已知状态并关闭")],
                cx,
            );
            assert!(window.has_active_prompt());
            let _ = window.draw(cx);
            rx
        });
        let cancel = window.debug_bounds("window-prompt-action-0").expect("cancel bounds");
        let confirm = window.debug_bounds("window-prompt-action-1").expect("confirm bounds");
        assert!(cancel.size.width > px(20.0) && cancel.size.height > px(16.0));
        assert!(confirm.size.width > px(20.0) && confirm.size.height > px(16.0));
        window.simulate_click(cancel.center(), Modifiers::default());
        assert_eq!(rx.await, Ok(0));
        assert!(!window.update(|window, _| window.has_active_prompt()));
        assert_eq!(clicks.get(), 0, "prompt click must not leak into background views");

        // Blur before clicking confirm to verify clicks do not depend on window focus.
        let rx = window.update(|window, cx| {
            window.blur();
            let rx = window.prompt(
                PromptLevel::Warning,
                "仍有 AI 会话未能识别，继续关闭？",
                Some("关闭前会保存窗口布局和已知的对话 ID。"),
                &[PromptButton::cancel("取消"), PromptButton::ok("保存已知状态并关闭")],
                cx,
            );
            window.blur();
            let _ = window.draw(cx);
            rx
        });
        let confirm = window.debug_bounds("window-prompt-action-1").expect("confirm bounds");
        window.simulate_click(confirm.center(), Modifiers::default());
        assert_eq!(rx.await, Ok(1));
        assert!(!window.update(|window, _| window.has_active_prompt()));
        assert_eq!(clicks.get(), 0);
    }

    #[gpui::test]
    async fn prompt_card_blocks_dismissal_and_backdrop_cancels(cx: &mut TestAppContext) {
        let (clicks, _, window) = open_host(cx);
        let rx = window.update(|window, cx| {
            let rx = window.prompt(
                PromptLevel::Warning,
                "仍有 AI 会话未能识别，继续关闭？",
                Some("详情文案"),
                &[PromptButton::cancel("取消"), PromptButton::ok("保存已知状态并关闭")],
                cx,
            );
            let _ = window.draw(cx);
            rx
        });
        let card = window.debug_bounds("window-prompt-card").expect("card bounds");
        window.simulate_click(
            point(card.origin.x + px(8.0), card.origin.y + px(8.0)),
            Modifiers::default(),
        );
        assert!(window.update(|window, _| window.has_active_prompt()));
        assert_eq!(clicks.get(), 0);

        // Clicking outside the card cancels cleanly without leaking to the terminal underneath.
        window.simulate_click(point(px(8.0), px(8.0)), Modifiers::default());
        assert_eq!(rx.await, Ok(0));
        assert!(!window.update(|window, _| window.has_active_prompt()));
        assert_eq!(clicks.get(), 0);
    }

    #[gpui::test]
    async fn prompt_supports_escape_tab_enter_and_isolates_other_keys(cx: &mut TestAppContext) {
        let (_, keys, window) = open_host(cx);

        let rx = window.update(|window, cx| {
            let rx = window.prompt(
                PromptLevel::Warning,
                "保存未保存的更改？",
                Some("demo.rs"),
                &[
                    PromptButton::ok("保存"),
                    PromptButton::new("放弃"),
                    PromptButton::cancel("取消"),
                ],
                cx,
            );
            let _ = window.draw(cx);
            rx
        });
        window.simulate_keystrokes("a");
        assert!(window.update(|window, _| window.has_active_prompt()));
        assert_eq!(keys.get(), 0, "typing while prompt is open must not leak");

        window.simulate_keystrokes("escape");
        assert_eq!(rx.await, Ok(2));
        assert!(!window.update(|window, _| window.has_active_prompt()));
        assert_eq!(keys.get(), 0);

        let rx = window.update(|window, cx| {
            let rx = window.prompt(
                PromptLevel::Warning,
                "保存未保存的更改？",
                Some("demo.rs"),
                &[
                    PromptButton::ok("保存"),
                    PromptButton::new("放弃"),
                    PromptButton::cancel("取消"),
                ],
                cx,
            );
            let _ = window.draw(cx);
            rx
        });
        window.simulate_keystrokes("tab enter");
        assert_eq!(rx.await, Ok(1));
        assert!(!window.update(|window, _| window.has_active_prompt()));
    }

    #[gpui::test]
    fn prompt_card_clamps_inside_narrow_viewport(cx: &mut TestAppContext) {
        let (_, _, window) = open_host(cx);
        window.simulate_resize(size(px(300.0), px(400.0)));
        window.update(|window, cx| {
            let _rx = window.prompt(
                PromptLevel::Warning,
                "仍有 AI 会话未能识别，继续关闭？",
                Some(
                    "关闭前会保存窗口布局和已知的对话 ID，并停止正在运行的命令。尚未取得 ID 的对话，重新打开后可能需要手动选择。",
                ),
                &[PromptButton::cancel("取消"), PromptButton::ok("保存已知状态并关闭")],
                cx,
            );
            let _ = window.draw(cx);
        });
        let card = window.debug_bounds("window-prompt-card").expect("card bounds");
        let cancel = window.debug_bounds("window-prompt-action-0").expect("cancel bounds");
        let confirm = window.debug_bounds("window-prompt-action-1").expect("confirm bounds");
        assert!(card.origin.x >= px(0.0) && card.right() <= px(300.0), "{card:?}");
        assert!(cancel.right() <= card.right(), "{cancel:?} vs {card:?}");
        assert!(confirm.right() <= card.right(), "{confirm:?} vs {card:?}");
    }
}
