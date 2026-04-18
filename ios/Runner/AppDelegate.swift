import Flutter
import UIKit
import Firebase
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure Firebase
    FirebaseApp.configure()
    
    // Set up notification delegate BEFORE Firebase configuration
    UNUserNotificationCenter.current().delegate = self
    
    // Set status bar style for iOS
    UIApplication.shared.statusBarStyle = .darkContent
    
    // Request notification permissions early
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      print("📱 iOS Notification permission granted: \(granted)")
      if let error = error {
        print("📱 iOS Notification permission error: \(error)")
      }
    }
    
    // Register for remote notifications
    application.registerForRemoteNotifications()
    
    GeneratedPluginRegistrant.register(with: self)
    
    // Set up App Group UserDefaults method channel
    let controller = window?.rootViewController as! FlutterViewController
    let appGroupChannel = FlutterMethodChannel(
      name: "com.vant.chatting/app_group",
      binaryMessenger: controller.binaryMessenger
    )
    appGroupChannel.setMethodCallHandler { (call, result) in
      let appGroupId = "group.com.vant.chatting"
      guard let defaults = UserDefaults(suiteName: appGroupId) else {
        result(FlutterError(code: "APP_GROUP_ERROR", message: "Cannot access App Group UserDefaults", details: nil))
        return
      }
      switch call.method {
      case "saveToAppGroup":
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String,
              let value = args["value"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing key or value", details: nil))
          return
        }
        defaults.set(value, forKey: key)
        defaults.synchronize()
        result(nil)
      case "removeFromAppGroup":
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing key", details: nil))
          return
        }
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Handle Branch.io and other custom URL scheme deep links
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }

  // Handle Branch.io universal links (AASA / app.link domains)
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }
  
  // Handle remote notification registration
  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    #if DEBUG
    Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)
    #else
    Messaging.messaging().setAPNSToken(deviceToken, type: .prod)
    #endif
  }
  
  // Handle remote notification reception
  override func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    print("📱 iOS Background: Received remote notification")
    print("📱 iOS Background: Original notification data: \(userInfo)")
    
    // Get sender ID to fetch saved username
    if let senderId = userInfo["senderDeviceId"] as? String {
      print("📱 iOS Background: Sender ID: \(senderId)")
      
      // Try to get saved username from UserDefaults
      if let savedUsername = UserDefaults.standard.string(forKey: "chat_name_\(senderId)") {
        print("📱 iOS Background: Found saved username: \(savedUsername)")
        
        // Create modified notification with correct username
        let content = UNMutableNotificationContent()
        
        // Copy existing notification data
        if let originalNotification = userInfo["aps"] as? [String: Any] {
          if let alert = originalNotification["alert"] as? [String: Any] {
            content.body = alert["body"] as? String ?? "New message"
          }
        }
        
        // Set correct title with username
        content.title = savedUsername
        content.sound = .default
        content.badge = 1
        
        // Copy user info for tap handling
        content.userInfo = userInfo
        
        // Schedule the corrected notification
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
          if let error = error {
            print("📱 iOS Background: Error showing corrected notification: \(error)")
          } else {
            print("📱 iOS Background: Corrected notification shown with title: \(savedUsername)")
          }
        }
      } else {
        print("📱 iOS Background: No saved username found for sender: \(senderId)")
      }
    }
    
    // Let Firebase handle the notification
    Messaging.messaging().appDidReceiveMessage(userInfo)
    
    completionHandler(UIBackgroundFetchResult.newData)
  }
  
  // Handle notification when app is in foreground
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let userInfo = notification.request.content.userInfo
    
    // Print debug info for foreground notifications
    if let messageId = userInfo["messageId"] as? String,
       let senderId = userInfo["senderDeviceId"] as? String {
      print("📱 iOS Foreground: Received notification for message \(messageId) from \(senderId)")
    }
    
    // Check if we need to update the notification title with saved username
    if let senderId = userInfo["senderDeviceId"] as? String {
      if let savedUsername = UserDefaults.standard.string(forKey: "chat_name_\(senderId)") {
        print("📱 iOS Foreground: Found saved username: \(savedUsername)")
        
        // Create a new notification request with updated title
        let updatedContent = UNMutableNotificationContent()
        updatedContent.title = savedUsername
        updatedContent.body = notification.request.content.body
        updatedContent.sound = notification.request.content.sound
        updatedContent.badge = notification.request.content.badge
        updatedContent.userInfo = userInfo
        
        // Replace the notification by canceling the old one and showing the new one
        let identifier = notification.request.identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        
        let newRequest = UNNotificationRequest(identifier: identifier + "_updated", content: updatedContent, trigger: nil)
        UNUserNotificationCenter.current().add(newRequest) { error in
          if let error = error {
            print("📱 iOS Foreground: Error showing updated notification: \(error)")
          } else {
            print("📱 iOS Foreground: Updated notification shown with title: \(savedUsername)")
          }
        }
      } else {
        print("📱 iOS Foreground: No saved username found for sender: \(senderId)")
      }
    }
    
    // Show the notification
    completionHandler([.banner, .sound, .badge])
  }
  
  // Handle notification tap
  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    let userInfo = response.notification.request.content.userInfo
    print("📱 iOS: Notification tapped with data: \(userInfo)")
    
    // Store notification data for Flutter to handle when app starts
    if let senderId = userInfo["senderDeviceId"] as? String {
      UserDefaults.standard.set(senderId, forKey: "pending_notification_sender")
      UserDefaults.standard.synchronize()
      print("📱 iOS: Stored pending notification sender: \(senderId)")
    }
    
    // Handle notification tap - this will be processed by Flutter
    completionHandler()
  }
}
