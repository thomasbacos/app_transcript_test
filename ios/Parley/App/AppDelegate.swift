import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UploadManager.shared.activate()
        // A recording timer left on the Lock Screen by a previous run (crash, app killed) goes away now,
        // including when iOS launches the app in the background for a Live Activity button.
        if !AppModel.shared.recorder.isActive { LiveActivityManager.shared.endAll() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await APIClient.shared.setPushToken(hex)
            await AppModel.shared.subscriptions.refreshAccount(force: true)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        UploadManager.shared.backgroundEventsCompletion = completionHandler
        UploadManager.shared.activate()
    }

    // Banner even when the app is open, and refresh right away.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in await AppModel.shared.processing.refreshInFlight() }
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let jobID = response.notification.request.content.userInfo["job_id"] as? String
        Task { @MainActor in
            if let jobID { AppModel.shared.openJob(jobID) }
        }
        completionHandler()
    }
}
