use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::WebviewWindowBuilder,
    Manager, WindowEvent,
};

fn show_or_create_popup(app: &tauri::AppHandle) {
    if let Some(popup) = app.get_webview_window("popup") {
        let _ = popup.show();
        let _ = popup.unminimize();
        let _ = popup.set_focus();
    } else {
        let _ = WebviewWindowBuilder::new(app, "popup", tauri::WebviewUrl::App("/popup".into()))
            .title("Bex — Quick Check")
            .inner_size(500.0, 400.0)
            .resizable(true)
            .always_on_top(true)
            .center()
            .build();
    }
}

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

fn setup_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let open_i = MenuItem::with_id(app, "open", "Open Bex", true, None::<&str>)?;
    let quick_i = MenuItem::with_id(app, "quick_check", "Quick Check", true, None::<&str>)?;
    let quit_i = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;

    let menu = Menu::with_items(app, &[&open_i, &quick_i, &quit_i])?;

    let _tray = TrayIconBuilder::new()
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_main_window(app),
            "quick_check" => show_or_create_popup(app),
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            setup_tray(app.handle())?;

            #[cfg(desktop)]
            {
                use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

                let handle = app.handle().clone();
                app.global_shortcut().on_shortcut("super+shift+g", move |_app, shortcut, event| {
                    if let ShortcutState::Pressed = event.state {
                        let _ = shortcut; // suppress unused warning
                        show_or_create_popup(&handle);
                    }
                })?;
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
                // popup windows close normally (destroyed, recreated on demand)
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
