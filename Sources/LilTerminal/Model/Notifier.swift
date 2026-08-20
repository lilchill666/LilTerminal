import Foundation
import UserNotifications
import AppKit

/// Posts user notifications, degrading quietly when they are not available.
///
/// An unsigned, ad-hoc-signed app cannot always register for
/// `UNUserNotificationCenter`; rather than fail silently, the fallback bounces
/// the Dock icon so the signal still arrives.
enum Notifier {
    private static var authorized = false
    private static var requested = false

    static func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorized = granted
            }
    }

    static func post(title: String, body: String) {
        guard authorized else {
            // Dock bounce: unmissable but not modal, and it needs no permission.
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
