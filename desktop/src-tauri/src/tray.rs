use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let open_item = MenuItem::with_id(app, "open", "Open QuakeSignal", true, None::<&str>)?;
    // A local synthetic alert is useful in direct distribution, but it is a
    // diagnostic control that must not be present in the Mac App Store build.
    #[cfg(not(feature = "macos-app-store"))]
    let test_item = MenuItem::with_id(app, "test_alert", "Send Test Alert", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;

    #[cfg(not(feature = "macos-app-store"))]
    let menu = Menu::with_items(app, &[&open_item, &test_item, &separator, &quit_item])?;
    #[cfg(feature = "macos-app-store")]
    let menu = Menu::with_items(app, &[&open_item, &separator, &quit_item])?;

    let icon = app
        .default_window_icon()
        .expect("default window icon must be bundled")
        .clone();

    TrayIconBuilder::with_id("main-tray")
        .icon(icon)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip("QuakeSignal — monitoring")
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_main_window(app),
            #[cfg(not(feature = "macos-app-store"))]
            "test_alert" => {
                let state = app.state::<crate::AppState>();
                crate::commands::send_test_alert(app.clone(), state);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main_window(tray.app_handle());
            }
        })
        .build(app)?;

    Ok(())
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
        let _ = window.unminimize();
    }
}
