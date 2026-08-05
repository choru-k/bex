import Foundation
import UserNotifications

/// Pure decision logic for Study Mode's daily reminder notification: what text to show
/// and when the repeating trigger should fire. Deliberately has no `UserNotifications`
/// import and never calls `Date()` — only plain `Foundation` value types
/// (`Date`/`Calendar`/`DateComponents`) supplied by the caller — so this whole enum is
/// unit-testable exactly like `LearningBadge`/`StudyScheduler`, with no
/// `UNUserNotificationCenter` involved at all. `StudyNotificationScheduler` below is the
/// thin impure edge that turns this plan into real system calls.
enum StudyNotificationPlan: Equatable, Sendable {
  /// Local hour (24-hour, in the trigger's own time zone) the daily reminder fires.
  /// 9am: late enough that it isn't also acting as an alarm clock, early enough to
  /// land before the day's work fills up. Exposed as a constant rather than buried in
  /// `triggerComponents()` so a future settings UI has one obvious place to read it.
  static let fireHour = 9

  /// Stable identifier for the single pending Study reminder request. Reused by
  /// `StudyNotificationScheduler.reschedule` to remove the previous request before
  /// adding a new one, so answering cards never leaves two competing reminders queued.
  static let identifier = "bex.study.daily"

  /// Category identifier stamped on the notification's content so the tap handler
  /// (`AppDelegate`'s `UNUserNotificationCenterDelegate` conformance) can recognize a
  /// response as "open Study" without string-matching the title/body text.
  static let categoryIdentifier = "bex.study.due"

  struct Content: Equatable, Sendable {
    let title: String
    let body: String
  }

  /// The notification content for `dueCount` cards, or `nil` when nothing is due.
  /// `nil` is the caller's signal to schedule nothing at all (see
  /// `StudyNotificationScheduler.reschedule(dueCount:)`) — sending "0 cards due" would
  /// be a lie, so the zero case has no `Content` to construct in the first place.
  static func content(forDueCount dueCount: Int) -> Content? {
    guard dueCount > 0 else { return nil }
    let body = dueCount == 1 ? "1 card due for review" : "\(dueCount) cards due for review"
    return Content(title: "Bex Study", body: body)
  }

  /// `DateComponents` for a repeating daily trigger at `fireHour:00`. Only hour/minute
  /// are set (no day/month/year), which is exactly what
  /// `UNCalendarNotificationTrigger(dateMatching:repeats: true)` expects to fire once a
  /// day at that wall-clock time — the system computes "next occurrence" itself, so no
  /// `Date()` is needed here.
  static func triggerComponents() -> DateComponents {
    var components = DateComponents()
    components.hour = fireHour
    components.minute = 0
    return components
  }

  /// The next concrete `Date` a repeating `fireHour:00` trigger would fire, given
  /// `now`: today at `fireHour` if that hasn't passed yet, else tomorrow at `fireHour`.
  /// Pure and deterministic — `calendar` and `now` are both inputs, never read from
  /// ambient state. This exists purely so the scheduling math is unit-testable; the
  /// real `UNCalendarNotificationTrigger` recomputes the same thing itself at delivery
  /// time from `triggerComponents()` and is never asked to trust this value.
  static func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date {
    guard let todayAtFireHour = calendar.date(bySettingHour: fireHour, minute: 0, second: 0, of: now)
    else {
      return now
    }
    if todayAtFireHour > now {
      return todayAtFireHour
    }
    return calendar.date(byAdding: .day, value: 1, to: todayAtFireHour) ?? todayAtFireHour
  }
}

/// The impure edge that turns `StudyNotificationPlan` decisions into real
/// `UNUserNotificationCenter` calls. Everything decision-shaped (content text, trigger
/// timing, "should anything be scheduled at all") lives in `StudyNotificationPlan`
/// above; this class does nothing but ask the system to authorize, add, and remove
/// requests — matching the pure/impure split the repo requires (see
/// `LearningBadge.swift`'s doc comment).
@MainActor
final class StudyNotificationScheduler {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  /// Requests `.alert` + `.sound` authorization only while macOS still reports
  /// `.notDetermined` — i.e. the owner has neither granted nor denied yet.
  ///
  /// The authorization state deliberately lives in the system, not in
  /// `PreferencesStore`: a local "we already asked" flag has to be written *before*
  /// awaiting the prompt (there is no other safe moment), so quitting Bex or a throw
  /// while the prompt sits unanswered would permanently latch "asked" and the owner
  /// would never be prompted again — silently killing the daily reminder, which is the
  /// entire reason Study Mode pushes instead of waiting to be opened. Reading
  /// `authorizationStatus` has no such window: macOS itself only leaves
  /// `.notDetermined` once a real answer is given, so an interrupted prompt is simply
  /// asked again next launch.
  ///
  /// A denial needs no handling here — the badge and the Study window are unaffected,
  /// and `reschedule(dueCount:)` stays harmless (the request is queued and the system
  /// drops it at delivery time).
  //
  // ponytail: no in-app "notifications are off, here's how to re-enable" affordance.
  // Ceiling: if the reminder turns out to be the thing that makes Study stick, surface
  // `.denied` in the Study window with a link to System Settings → Notifications.
  func requestAuthorizationIfNeeded() async {
    guard await center.notificationSettings().authorizationStatus == .notDetermined else {
      return
    }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  /// Removes any previously scheduled Study reminder and, when `dueCount > 0`, queues a
  /// fresh one for the next occurrence of `StudyNotificationPlan.fireHour:00`. Always
  /// removes first (by the stable `StudyNotificationPlan.identifier`) so a card getting
  /// answered down to zero due — or the count simply changing — never leaves a stale
  /// request with yesterday's count sitting in the notification center alongside a new
  /// one. When `dueCount == 0` nothing is re-added: never claim cards are due when none
  /// are (see `StudyNotificationPlan.content(forDueCount:)`).
  func reschedule(dueCount: Int) async {
    center.removePendingNotificationRequests(withIdentifiers: [StudyNotificationPlan.identifier])
    guard let content = StudyNotificationPlan.content(forDueCount: dueCount) else { return }

    let notificationContent = UNMutableNotificationContent()
    notificationContent.title = content.title
    notificationContent.body = content.body
    notificationContent.sound = .default
    notificationContent.categoryIdentifier = StudyNotificationPlan.categoryIdentifier

    let trigger = UNCalendarNotificationTrigger(
      dateMatching: StudyNotificationPlan.triggerComponents(),
      repeats: true
    )
    let request = UNNotificationRequest(
      identifier: StudyNotificationPlan.identifier,
      content: notificationContent,
      trigger: trigger
    )
    // Fire-and-forget, same posture as `LearningLogStore.append`/`StudyStateStore.persist`:
    // a denied permission or a transient system error must never surface as a crash or
    // a blocking failure in this best-effort convenience feature.
    try? await center.add(request)
  }
}
