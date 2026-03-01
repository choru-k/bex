use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::WebviewWindowBuilder,
    Manager, WindowEvent,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenAICodexProxyPayload {
    access_token: String,
    account_id: String,
    model: String,
    system_prompt: String,
    input_text: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenAICodexProxyResponse {
    status: u16,
    status_text: String,
    body: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenAICodexWaitForCallbackPayload {
    state: String,
    timeout_ms: Option<u64>,
}

const OPENAI_CODEX_OAUTH_SUCCESS_HTML: &str = r#"<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>Authentication successful</title>
</head>
<body>
  <p>Authentication successful. You can return to Bex.</p>
</body>
</html>"#;

const OPENAI_CODEX_OAUTH_ERROR_HTML: &str = r#"<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>Authentication error</title>
</head>
<body>
  <p>Authentication failed. Return to Bex and try again.</p>
</body>
</html>"#;

fn extract_request_path(request: &str) -> Option<&str> {
    request.lines().next()?.split_whitespace().nth(1)
}

fn query_param_raw(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        let mut pieces = pair.splitn(2, '=');
        let Some(current_key) = pieces.next() else {
            continue;
        };
        if current_key != key {
            continue;
        }
        return Some(pieces.next().unwrap_or("").to_string());
    }

    None
}

fn write_http_response(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        body.as_bytes().len(),
        body,
    );

    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn wait_for_openai_codex_callback(state: &str, timeout_ms: u64) -> Result<String, String> {
    let listener = TcpListener::bind("127.0.0.1:1455")
        .map_err(|err| format!("Could not bind OAuth callback port 1455: {err}"))?;
    listener
        .set_nonblocking(true)
        .map_err(|err| format!("Could not configure OAuth callback server: {err}"))?;

    let started = Instant::now();
    let timeout = Duration::from_millis(timeout_ms.max(1_000));

    loop {
        if started.elapsed() >= timeout {
            return Err("Timed out waiting for ChatGPT login callback.".to_string());
        }

        match listener.accept() {
            Ok((mut stream, _addr)) => {
                let mut buffer = [0_u8; 8192];
                let read = stream.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..read]);
                let path = extract_request_path(&request).unwrap_or("/");

                if !path.starts_with("/auth/callback") {
                    write_http_response(&mut stream, "404 Not Found", OPENAI_CODEX_OAUTH_ERROR_HTML);
                    continue;
                }

                let query = path.splitn(2, '?').nth(1).unwrap_or_default();
                let request_state = query_param_raw(query, "state").unwrap_or_default();
                let code = query_param_raw(query, "code").unwrap_or_default();

                if request_state != state || code.is_empty() {
                    write_http_response(&mut stream, "400 Bad Request", OPENAI_CODEX_OAUTH_ERROR_HTML);
                    continue;
                }

                write_http_response(&mut stream, "200 OK", OPENAI_CODEX_OAUTH_SUCCESS_HTML);
                return Ok(format!("http://localhost:1455{}", path));
            }
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(err) => {
                return Err(format!("OAuth callback server error: {err}"));
            }
        }
    }
}

#[tauri::command]
async fn openai_codex_wait_for_callback(
    payload: OpenAICodexWaitForCallbackPayload,
) -> Result<String, String> {
    let timeout_ms = payload.timeout_ms.unwrap_or(180_000);
    let state = payload.state;

    tauri::async_runtime::spawn_blocking(move || {
        wait_for_openai_codex_callback(state.as_str(), timeout_ms)
    })
    .await
    .map_err(|err| format!("Failed to wait for OAuth callback: {err}"))?
}

#[tauri::command]
async fn openai_codex_proxy_request(
    payload: OpenAICodexProxyPayload,
) -> Result<OpenAICodexProxyResponse, String> {
    let client = reqwest::Client::new();

    let response = client
        .post("https://chatgpt.com/backend-api/codex/responses")
        .header("Authorization", format!("Bearer {}", payload.access_token))
        .header("chatgpt-account-id", payload.account_id)
        .header("OpenAI-Beta", "responses=experimental")
        .header("originator", "bex")
        .header("accept", "application/json")
        .header("content-type", "application/json")
        .json(&serde_json::json!({
            "model": payload.model,
            "store": false,
            "stream": false,
            "instructions": payload.system_prompt,
            "input": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": payload.input_text,
                        }
                    ]
                }
            ],
            "text": {
                "verbosity": "medium",
            }
        }))
        .send()
        .await
        .map_err(|err| format!("Failed to reach OpenAI Codex: {err}"))?;

    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|err| format!("Failed to read OpenAI Codex response: {err}"))?;

    Ok(OpenAICodexProxyResponse {
        status: status.as_u16(),
        status_text: status.canonical_reason().unwrap_or("unknown").to_string(),
        body,
    })
}

fn show_or_create_popup(app: &tauri::AppHandle) {
    if let Some(popup) = app.get_webview_window("popup") {
        let _ = popup.set_title("");
        let _ = popup.set_title_bar_style(tauri::TitleBarStyle::Overlay);
        let _ = popup.show();
        let _ = popup.unminimize();
        let _ = popup.set_focus();
    } else {
        let _ = WebviewWindowBuilder::new(app, "popup", tauri::WebviewUrl::App("/popup".into()))
            .title("")
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
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
        .invoke_handler(tauri::generate_handler![
            openai_codex_wait_for_callback,
            openai_codex_proxy_request
        ])
        .setup(|app| {
            setup_tray(app.handle())?;

            if let Some(main) = app.get_webview_window("main") {
                let _ = main.set_title("");
                let _ = main.set_title_bar_style(tauri::TitleBarStyle::Overlay);
            }

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
