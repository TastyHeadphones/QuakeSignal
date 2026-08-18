use crate::alarm;
use crate::domain::{NormalizedEvent, NotifyReason};
use crate::filter;
use crate::settings::Settings;
use tauri::AppHandle;
use tauri_plugin_notification::NotificationExt;

struct Strings {
    title: &'static str,
    body_template: &'static str,
}

/// Notification copy for each (language, reason) pair. Deliberately reuses
/// the exact terms already established in the iOS app's Localizable.strings
/// (e.g. "緊急地震速報" / "地震预警" / "Earthquake Early Warning") so the
/// two platforms read as the same product, even though this text lives
/// separately here since OS notifications can't reach into the webview's
/// i18n at delivery time. `{hypocenter}`, `{mag}`, `{serial}` are replaced.
fn strings_for(lang: &str, reason: NotifyReason) -> Strings {
    let lang = normalize_lang(lang);
    match (lang, reason) {
        ("ja", NotifyReason::New) => Strings {
            title: "緊急地震速報",
            body_template: "{hypocenter} M{mag}",
        },
        ("ja", NotifyReason::Updated) => Strings {
            title: "緊急地震速報（続報）",
            body_template: "{hypocenter} M{mag}　第{serial}報",
        },
        ("ja", NotifyReason::Final) => Strings {
            title: "緊急地震速報（最終報）",
            body_template: "{hypocenter} M{mag}",
        },
        ("ja", NotifyReason::Cancelled) => Strings {
            title: "緊急地震速報 取消",
            body_template: "{hypocenter} の警報は取り消されました",
        },
        ("ja", NotifyReason::Report) => Strings {
            title: "地震情報",
            body_template: "{hypocenter} M{mag}",
        },
        ("ja", NotifyReason::Training) => Strings {
            title: "訓練・テスト配信",
            body_template: "これは訓練です。実際の地震ではありません",
        },

        ("zh", NotifyReason::New) => Strings {
            title: "地震预警",
            body_template: "{hypocenter} M{mag}",
        },
        ("zh", NotifyReason::Updated) => Strings {
            title: "地震预警（更新）",
            body_template: "{hypocenter} M{mag}　第{serial}报",
        },
        ("zh", NotifyReason::Final) => Strings {
            title: "地震预警（最终报）",
            body_template: "{hypocenter} M{mag}",
        },
        ("zh", NotifyReason::Cancelled) => Strings {
            title: "地震预警已取消",
            body_template: "{hypocenter} 的预警已取消",
        },
        ("zh", NotifyReason::Report) => Strings {
            title: "地震信息",
            body_template: "{hypocenter} M{mag}",
        },
        ("zh", NotifyReason::Training) => Strings {
            title: "演习/测试提醒",
            body_template: "这是一次演习，并非真实地震",
        },

        (_, NotifyReason::New) => Strings {
            title: "Earthquake Early Warning",
            body_template: "M{mag} near {hypocenter}",
        },
        (_, NotifyReason::Updated) => Strings {
            title: "Earthquake Early Warning (Updated)",
            body_template: "M{mag} near {hypocenter} — report #{serial}",
        },
        (_, NotifyReason::Final) => Strings {
            title: "Earthquake Early Warning (Final Report)",
            body_template: "M{mag} near {hypocenter}",
        },
        (_, NotifyReason::Cancelled) => Strings {
            title: "Earthquake Early Warning Cancelled",
            body_template: "The warning for {hypocenter} has been cancelled",
        },
        (_, NotifyReason::Report) => Strings {
            title: "Earthquake Report",
            body_template: "M{mag} near {hypocenter}",
        },
        (_, NotifyReason::Training) => Strings {
            title: "Training Alert (Not Real)",
            body_template: "This is a drill/test broadcast — no action needed",
        },
    }
}

fn normalize_lang(lang: &str) -> &'static str {
    if lang.starts_with("ja") {
        "ja"
    } else if lang.starts_with("zh") {
        "zh"
    } else {
        "en"
    }
}

fn resolve_language(settings: &Settings) -> String {
    if settings.language != "system" {
        return settings.language.clone();
    }
    sys_locale::get_locale().unwrap_or_else(|| "en".to_string())
}

fn render(template: &str, event: &NormalizedEvent) -> String {
    let mag = event
        .magnitude
        .map(|m| format!("{:.1}", m))
        .unwrap_or_else(|| "?".to_string());
    template
        .replace("{hypocenter}", &event.hypocenter)
        .replace("{mag}", &mag)
        .replace("{serial}", &event.serial.to_string())
}

/// Shows the OS notification and, for anything that represents an active
/// early warning (not a routine report/training), also pops the always-
/// on-top alert window. Mirrors the split in backend/src/push/payload.ts
/// between the always-sent push and the `isSevere` critical treatment,
/// adapted to what a desktop OS notification can actually express.
pub fn dispatch(
    app: &AppHandle,
    settings: &Settings,
    event: &NormalizedEvent,
    reason: NotifyReason,
) {
    let lang = resolve_language(settings);
    let s = strings_for(&lang, reason);
    let body = render(s.body_template, event);

    let mut builder = app.notification().builder().title(s.title).body(&body);
    let urgent = filter::is_urgent_warning_presentation(event, reason);
    if urgent && event.is_severe() {
        builder = builder.sound("default");
    }
    if let Err(e) = builder.show() {
        log::warn!("failed to show notification: {e}");
    }

    alarm::play_for_event(settings, event, reason);

    let should_pop_alert_window = urgent;
    if should_pop_alert_window {
        if let Err(e) = crate::alert_window::show_alert(app, event, reason, &lang) {
            log::warn!("failed to show alert window: {e}");
        }
    }
}
