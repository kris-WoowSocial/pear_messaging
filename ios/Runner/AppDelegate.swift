import Flutter
import UIKit
import Firebase
import UserNotifications
import PushKit
import CallKit
import AVFoundation
import flutter_callkit_incoming
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {

  // Stable namespace for UUIDv5 (URL namespace from RFC 4122)
  private let uuidNamespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
  // PushKit registry for VoIP pushes (required for CallKit on locked iOS)
  var pushRegistry: PKPushRegistry?
  private var isAppForeground = false
  private var isInCall = false
  private var callStateChannel: FlutterMethodChannel?
  private var audioSessionObserversRegistered = false
  // Re-activation safety: only re-activate the audio session after an
  // interruption that actually began during a call, and never within the
  // teardown window after a call ends (isInCall syncs async from Dart, so a
  // late route-change/interruption-ended notification could otherwise
  // re-activate a dead call's session — red mic bar / bad next call).
  private var interruptedWhileInCall = false
  private var lastCallEndedAt: Date?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure Firebase
    FirebaseApp.configure()

    // Persist the real aps-environment entitlement from the embedded provisioning
    // profile so both native Swift and Flutter use a single source of truth.
    // SharedPreferences on iOS prefixes keys with "flutter.", so we store it
    // with the same prefix that Dart will resolve.
    UserDefaults.standard.set(realApsEnvironment(), forKey: "flutter.apns_environment")

    // Set up notification delegate BEFORE Firebase configuration
    UNUserNotificationCenter.current().delegate = self
    
    // Set status bar style for iOS
    UIApplication.shared.statusBarStyle = .darkContent
    
    // Request notification permissions early — but NOT on first launch.
    // On a fresh install the system prompt would stack with the Branch
    // pasteboard prompt and the in-app name sheet; FCMService asks later,
    // after the invite step completes. The flag is the SharedPreferences
    // key ("flutter."-prefixed) written by the Dart name-setup flow.
    if UserDefaults.standard.bool(forKey: "flutter.initial_name_setup_completed") {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        print("📱 iOS Notification permission granted: \(granted)")
        if let error = error {
          print("📱 iOS Notification permission error: \(error)")
        }
      }
    } else {
      print("📱 First launch — deferring notification permission to the invite step")
    }
    
    // Register for remote notifications
    application.registerForRemoteNotifications()
    
    GeneratedPluginRegistrant.register(with: self)

    // Front-camera frames must not be mirrored on the wire (remote saw text
    // backwards); the local self-view mirrors display-side instead.
    CaptureSessionMirrorGuard.install()

    // Register method channel so Flutter can tell native when a Vant call is active
    setupCallStateChannel()

    // Watch audio-session interruptions so external calls don't silently kill Vant audio
    setupAudioSessionObservers()

    // Register for VoIP pushes so CallKit can appear on locked screen
    setupPushKit()
    
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
    override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data) {
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
      
      // Try to get saved username from the App Group name cache
      if let savedUsername = savedContactName(for: senderId) {
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
      if let savedUsername = savedContactName(for: senderId) {
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

  // Generate a deterministic RFC 4122 UUID v5 from a string using the URL namespace.
  // This matches Dart's `Uuid().v5(UuidNamespace.url, callId)` so CallKit ids are
  // consistent between the native PushKit path and the Dart CallKitService path.
  private func uuidV5(from name: String) -> UUID? {
    guard let nameData = name.data(using: .utf8) else { return nil }

    var uuidBytes = uuidNamespace.uuid
    var namespaceData = Data()
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.0, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.1, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.2, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.3, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.4, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.5, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.6, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.7, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.8, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.9, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.10, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.11, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.12, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.13, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.14, count: 1))
    namespaceData.append(UnsafeBufferPointer(start: &uuidBytes.15, count: 1))

    var input = namespaceData
    input.append(nameData)

    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    input.withUnsafeBytes { buffer in
      _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &digest)
    }

    digest[6] = (digest[6] & 0x0F) | 0x50 // version 5
    digest[8] = (digest[8] & 0x3F) | 0x80 // variant 10

    return UUID(uuid: (
      digest[0], digest[1], digest[2], digest[3],
      digest[4], digest[5], digest[6], digest[7],
      digest[8], digest[9], digest[10], digest[11],
      digest[12], digest[13], digest[14], digest[15]
    ))
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    isAppForeground = true
    // Re-upload the VoIP token on every activation: covers device_id writes
    // that landed after the first PushKit callback, device_id regeneration,
    // and any earlier POST that failed on a cold network.
    if let token = latestVoipToken {
      registerVoipTokenWithBackend(token: token)
    }
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    isAppForeground = false
  }

  // MARK: - PushKit / VoIP Push (required for CallKit on locked iOS)

  private func setupPushKit() {
    pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
    pushRegistry?.delegate = self
    pushRegistry?.desiredPushTypes = [.voIP]
    print("📱 PushKit: VoIP push registry configured")
  }

  // MARK: - PKPushRegistryDelegate

  private var latestVoipToken: String?

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let tokenParts = pushCredentials.token.map { String(format: "%02.2hhx", $0) }
    let token = tokenParts.joined()
    latestVoipToken = token
    print("📱 PushKit: VoIP token received: \(token)")

    // Forward token to flutter_callkit_incoming so it can emit it to Dart
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)

    // Also register directly from native — this is the RELIABLE path.
    // Flutter's CallKitService may not be initialized yet when PushKit fires
    // (PushKit fires early in app launch, before Flutter is ready).
    // device_id is stored by Flutter's SharedPreferences in NSUserDefaults.standard
    // under the key "flutter.device_id" (SharedPreferences prefixes all keys with "flutter.").
    registerVoipTokenWithBackend(token: token)
  }

  /// Fallback APNs environment derived from the Swift build configuration.
  /// Used only when the real aps-environment entitlement cannot be read.
  private func fallbackApsEnvironmentForCurrentBuild() -> String {
    #if DEBUG
    return "sandbox"
    #else
    return "production"
    #endif
  }

  /// Reads the real `aps-environment` entitlement from the embedded
  /// provisioning profile. This is the single source of truth for whether the
  /// signed binary is sandbox or production, regardless of build flags.
  private func realApsEnvironment() -> String {
    guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
          let data = FileManager.default.contents(atPath: path),
          let raw = String(data: data, encoding: .isoLatin1) else {
      return fallbackApsEnvironmentForCurrentBuild()
    }

    guard let startRange = raw.range(of: "<?xml"),
          let endRange = raw.range(of: "</plist>", range: startRange.lowerBound..<raw.endIndex) else {
      return fallbackApsEnvironmentForCurrentBuild()
    }

    let plistXML = String(raw[startRange.lowerBound..<endRange.upperBound])
    guard let plistData = plistXML.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
          ) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let apsEnv = entitlements["aps-environment"] as? String else {
      return fallbackApsEnvironmentForCurrentBuild()
    }

    return apsEnv
  }

  /// Returns the APNs environment stored at launch from the real entitlement.
  /// Falls back to the build configuration if the stored value is missing.
  private func currentApsEnvironment() -> String {
    if let stored = UserDefaults.standard.string(forKey: "flutter.apns_environment"), !stored.isEmpty {
      return stored
    }
    return fallbackApsEnvironmentForCurrentBuild()
  }

  /// Register VoIP token with the backend server directly from native Swift.
  /// Uses URLSession so it works even before Flutter is fully initialized.
  /// Retries with backoff: covers both "device_id not written yet" (PushKit
  /// fires before Flutter's initializeCriticalServices) and transient POST
  /// failures on a cold network.
  private func registerVoipTokenWithBackend(token: String, attempt: Int = 0) {
    // Flutter SharedPreferences stores keys with "flutter." prefix in NSUserDefaults.standard
    guard let deviceId = UserDefaults.standard.string(forKey: "flutter.device_id"),
          !deviceId.isEmpty else {
      if attempt < 5 {
        print("📱 PushKit: device_id not in UserDefaults yet — retrying token upload (attempt \(attempt + 1))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
          self?.registerVoipTokenWithBackend(token: token, attempt: attempt + 1)
        }
      } else {
        print("📱 PushKit: device_id still missing after retries — Dart re-register path will cover")
      }
      return
    }

    guard let url = URL(string: "https://vant.chat/api/devices/voip-token") else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let info = Bundle.main.infoDictionary
    let body: [String: String] = [
      "deviceId": deviceId,
      "voipToken": token,
      "platform": "ios",
      "apnsEnvironment": currentApsEnvironment(),
      "appVersion": (info?["CFBundleShortVersionString"] as? String) ?? "",
      "appBuild": (info?["CFBundleVersion"] as? String) ?? ""
    ]

    guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
    request.httpBody = httpBody

    URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      if error == nil, statusCode == 200 {
        print("📱 PushKit: VoIP token registered — HTTP 200 for device \(deviceId)")
        return
      }
      print("📱 PushKit: VoIP token registration failed (status=\(statusCode), error=\(error?.localizedDescription ?? "none"), attempt=\(attempt))")
      if attempt < 3 {
        let delay = attempt == 0 ? 2.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          self?.registerVoipTokenWithBackend(token: token, attempt: attempt + 1)
        }
      }
    }.resume()
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    print("📱 PushKit: VoIP token invalidated")
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    print("📱 PushKit: Incoming VoIP push received: \(payload.dictionaryPayload)")
    guard type == .voIP else {
      completion()
      return
    }

    let pushType = payload.dictionaryPayload["type"] as? String ?? "incoming_call"

    // Caller cancelled — dismiss the CallKit UI if it's showing (works even when app is killed)
    if pushType == "call_cancelled" {
      let callId = payload.dictionaryPayload["callId"] as? String ?? ""
      print("📱 PushKit: call_cancelled received for callId=\(callId), reporting placeholder + ending CallKit call")
      // iOS requires EVERY VoIP push to produce a reportNewIncomingCall. The
      // real call's CallKit UUID may already exist (a ringing call), and a
      // second report with the same UUID can fail without satisfying the
      // push contract — so report a throwaway call under a FRESH UUID, then
      // end it immediately. The real call's record is ended separately.
      // completion() runs only after the report callback.
      let placeholderId = UUID().uuidString
      let placeholderData = flutter_callkit_incoming.Data(id: placeholderId, nameCaller: "", handle: "", type: 0)
      placeholderData.extra = ["callId": placeholderId] as NSDictionary
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(placeholderData, fromPushKit: true) { [weak self] in
        // End the real call's CallKit record (silenced: no decline/end
        // events reach the server or Dart for it).
        if !callId.isEmpty, let uuid = self?.uuidV5(from: callId) {
          self?.markCallKitEndSilenced(serverCallId: callId)
          let endData = flutter_callkit_incoming.Data(id: uuid.uuidString, nameCaller: "", handle: "", type: 0)
          SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(endData)
        }
        // End the throwaway report so nothing lingers in CallKit.
        self?.markCallKitEndSilenced(serverCallId: placeholderId)
        let endPlaceholder = flutter_callkit_incoming.Data(id: placeholderId, nameCaller: "", handle: "", type: 0)
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(endPlaceholder)
        completion()
      }
      return
    }

    // Extract call data from VoIP push payload (needed by BOTH the foreground
    // ghost-report path and the normal CallKit path below).
    let serverCallId = payload.dictionaryPayload["callId"] as? String ?? payload.dictionaryPayload["id"] as? String ?? ""
    let handle = payload.dictionaryPayload["callerId"] as? String ?? ""
    // Prefer the contact name the user saved locally — the push payload only
    // carries the caller's server-side username (e.g. @user_1234). The cache
    // lives in the App Group UserDefaults (mirrored from Dart's chat_name_*
    // SharedPreferences keys) so it is readable here, before Flutter starts.
    let pushName = payload.dictionaryPayload["callerName"] as? String ?? ""
    let nameCaller = savedContactName(for: handle)
      ?? (pushName.isEmpty ? nil : pushName)
      ?? "Vant Call"
    // isVideo arrives as a String "true"/"false" from the server data dict
    let isVideoStr = payload.dictionaryPayload["isVideo"] as? String ?? "false"
    let isVideo = (payload.dictionaryPayload["isVideo"] as? Bool) ?? (isVideoStr == "true")

    // CallKit requires a valid UUID for the call id. Convert the server callId to a
    // deterministic UUID v5 so it matches the id generated by Dart's CallKitService.
    let callKitId = serverCallId.isEmpty ? UUID().uuidString : (uuidV5(from: serverCallId)?.uuidString ?? UUID().uuidString)

    // Build CallKit data (shared by the foreground ghost report and the
    // normal lock-screen report below).
    let callData = flutter_callkit_incoming.Data(id: callKitId, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
    // Match the server's 45 s ring timeout so the CallKit ring and the
    // caller's "no answer" end happen together (plugin default is 30 s).
    callData.duration = 45000
    var extra = payload.dictionaryPayload
    extra["callId"] = serverCallId
    // Carry the resolved display name through so the post-accept path shows
    // the same name the lock screen did.
    extra["callerName"] = nameCaller
    callData.extra = extra as NSDictionary

    if isAppForeground {
      // Apple's VoIP contract: EVERY incoming_call push must be reported to
      // CallKit, even when the Flutter socket path already owns the call UI.
      // The old early-return was a violation that gets VoIP pushes throttled.
      // Report first (satisfies the contract), then ask Dart whether the
      // Flutter incoming screen is actually up for this callId. Only on an
      // explicit ack is the ghost CallKit record ended — the silence marker
      // makes the resulting end/decline events no-ops both natively
      // (respondToCall) and in Dart (_handleCallKitEvent). If no ack arrives
      // within ~1 s (engine still starting, socket event not yet landed,
      // another screen in the way), the CallKit UI STAYS so the user can
      // still answer — and no decline/end is ever sent to the caller.
      print("📱 PushKit: foreground — reported to CallKit, awaiting Flutter-screen ack (callId=\(serverCallId))")
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(callData, fromPushKit: true) {
        completion()
      }
      let decision = GhostEndDecision()
      let endData = flutter_callkit_incoming.Data(id: callKitId, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
      endData.extra = ["callId": serverCallId] as NSDictionary
      let decideGhostEnd: (Bool) -> Void = { [weak self] confirmed in
        guard !decision.decided else { return }
        decision.decided = true
        if confirmed {
          guard let controller = self?.window?.rootViewController as? FlutterViewController else { return }
          FlutterMethodChannel(
            name: "com.pear.messaging/call",
            binaryMessenger: controller.binaryMessenger
          ).invokeMethod("armGhostCallKitEnd", arguments: ["uuid": callKitId]) { armed in
            guard (armed as? Bool) == true else { return }
            self?.markCallKitEndSilenced(serverCallId: serverCallId)
            if let uuid = UUID(uuidString: callKitId) {
              self?.ghostEndUuids.insert(uuid)
            }
            SwiftFlutterCallkitIncomingPlugin.sharedInstance?.endCall(endData)
            print("📱 PushKit: Flutter screen acked — ghost CallKit record ended silently")
          }
        } else {
          print("📱 PushKit: no Flutter-screen ack — CallKit UI stays, user can answer")
        }
      }
      if let controller = window?.rootViewController as? FlutterViewController {
        FlutterMethodChannel(
          name: "com.pear.messaging/call",
          binaryMessenger: controller.binaryMessenger
        ).invokeMethod("confirmIncomingCallScreen", arguments: ["callId": serverCallId]) { result in
          decideGhostEnd((result as? Bool) == true)
        }
      }
      // ~1 s deadline: whichever fires first — the Dart ack or this timer —
      // settles the decision exactly once.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        decideGhostEnd(false)
      }
      return
    }

    print("📱 PushKit: Showing CallKit UI — callId=\(callKitId) caller=\(nameCaller) isVideo=\(isVideo)")

    // Build CallKit data and show native incoming call UI on the lock screen.
    // CRITICAL: iOS 13+ requires reportNewIncomingCall within this method's call stack.
    // fromPushKit: true satisfies that requirement.
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(callData, fromPushKit: true) {
      completion()
    }
  }

  // MARK: - Silenced CallKit ghost ends (foreground VoIP pushes)

  /// Server callIds whose next CallKit end/decline event must be swallowed.
  /// Mirrored into UserDefaults so the Dart CallKitService can consume the
  /// same marker when the plugin event reaches Flutter.
  private var silencedCallKitIds = Set<String>()

  /// One-shot latch for the foreground ghost-end handshake. All writers
  /// (the Dart ack reply and the ~1 s fallback timer) run on the main
  /// queue, so a plain bool is sufficient.
  private final class GhostEndDecision {
    var decided = false
  }

  private func markCallKitEndSilenced(serverCallId: String) {
    guard !serverCallId.isEmpty else { return }
    silencedCallKitIds.insert(serverCallId)
    let existing = UserDefaults.standard.string(forKey: "flutter.silenced_call_ids") ?? ""
    var ids = Set(existing.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    ids.insert(serverCallId)
    UserDefaults.standard.set(ids.joined(separator: ","), forKey: "flutter.silenced_call_ids")
    UserDefaults.standard.synchronize()
  }

  /// One-shot consume: true only for the ghost end of a foreground-reported
  /// push. A real decline/end of a DIFFERENT callId, or a second event for the
  /// same callId after the ghost end was consumed, is NOT silenced.
  private func consumeSilencedCallEnd(call: Call) -> Bool {
    guard let callId = call.data.extra["callId"] as? String,
          silencedCallKitIds.contains(callId) else {
      return false
    }
    silencedCallKitIds.remove(callId)
    return true
  }

  /// Saved contact name for a device ID, readable before Flutter starts.
  /// Dart mirrors `chat_name_<deviceId>` into this App Group store on every
  /// save/rename/delete; the App Group container uses default file
  /// protection, so before the first unlock after a reboot this returns nil
  /// and callers fall back to the push payload name.
  private func savedContactName(for deviceId: String) -> String? {
    guard !deviceId.isEmpty,
          let defaults = UserDefaults(suiteName: "group.com.vant.chatting"),
          let name = defaults.string(forKey: "chat_name_\(deviceId)"),
          !name.isEmpty else {
      return nil
    }
    return name
  }

  // MARK: - CallkitIncomingAppDelegate

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    print("📱 CallKit: didActivateAudioSession")
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    print("📱 CallKit: didDeactivateAudioSession")
  }

  func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
    print("📱 CallKit: onAccept")
    persistPendingAcceptedCall(call: call)
    notifyFlutterOfCallAccept(call: call)
    respondToCall(call: call, action: "accept")
    action.fulfill()
  }

  func onDecline(_ call: Call, _ action: CXEndCallAction) {
    print("📱 CallKit: onDecline")
    respondToCall(call: call, action: "reject")
    action.fulfill()
  }

  func onEnd(_ call: Call, _ action: CXEndCallAction) {
    print("📱 CallKit: onEnd")
    respondToCall(call: call, action: "end")
    action.fulfill()
  }

  func onTimeOut(_ call: Call) {
    print("📱 CallKit: onTimeOut")
  }

  private func notifyFlutterOfCallAccept(call: Call) {
    guard let callId = call.data.extra["callId"] as? String, !callId.isEmpty,
          let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    let extra = call.data.extra as? [String: Any] ?? [:]
    let isVideo = (extra["isVideo"] as? Bool) ?? ((extra["isVideo"] as? String) == "true")
    let arguments: [String: Any] = [
      "action": "answer",
      "callId": callId,
      "callerId": extra["callerId"] as? String ?? "",
      "callerName": extra["callerName"] as? String ?? "Incoming Call",
      "roomId": extra["roomId"] as? String ?? "",
      "avatarUrl": extra["avatarUrl"] as? String ?? "",
      "isVideo": isVideo,
    ]

    DispatchQueue.main.async {
      FlutterMethodChannel(
        name: "com.pear.messaging/call",
        binaryMessenger: controller.binaryMessenger
      ).invokeMethod("onCallAction", arguments: arguments)
    }
  }

  private func persistPendingAcceptedCall(call: Call) {
    guard let callId = call.data.extra["callId"] as? String, !callId.isEmpty else {
      return
    }

    let extra = call.data.extra as? [String: Any] ?? [:]
    let isVideo = (extra["isVideo"] as? Bool) ?? ((extra["isVideo"] as? String) == "true")
    UserDefaults.standard.set(callId, forKey: "flutter.pendingAcceptedCallId")
    UserDefaults.standard.set(isVideo, forKey: "flutter.pendingAcceptedCallIsVideo")
    UserDefaults.standard.set(true, forKey: "flutter.launchedForCall")
    UserDefaults.standard.synchronize()
  }

  private var ghostEndUuids = Set<UUID>()
  private var orphanEndUuids = Set<UUID>()
  private let orphanCallController = CXCallController()

  private func respondToCall(call: Call, action: String) {
    if ghostEndUuids.contains(call.uuid) {
      print("📱 CallKit: silenced ghost event — no server \(action)")
      return
    }
    if action != "accept", orphanEndUuids.remove(call.uuid) != nil {
      return
    }
    // Ghost ends from the foreground report-then-end path must never reach
    // the server — the caller keeps ringing; the Flutter screen owns the call.
    if consumeSilencedCallEnd(call: call) {
      print("📱 CallKit: silenced ghost end — no server \(action)")
      return
    }
    guard let callId = call.data.extra["callId"] as? String,
          !callId.isEmpty,
          let deviceId = UserDefaults.standard.string(forKey: "flutter.device_id"),
          !deviceId.isEmpty,
          let url = URL(string: "https://vant.chat/api/calls/\(callId)/respond") else {
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(deviceId, forHTTPHeaderField: "x-device-id")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action])

    URLSession.shared.dataTask(with: request) { _, response, error in
      if let error = error {
        print("📱 CallKit: server \(action) failed: \(error.localizedDescription)")
      } else if let httpResponse = response as? HTTPURLResponse {
        print("📱 CallKit: server \(action) HTTP \(httpResponse.statusCode)")
      }
    }.resume()
  }

  // MARK: - Call-state sync from Flutter

  private func setupCallStateChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    callStateChannel = FlutterMethodChannel(
      name: "com.pear.messaging/call",
      binaryMessenger: controller.binaryMessenger
    )

    callStateChannel?.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "endOrphanedCallKitCall":
        guard let args = call.arguments as? [String: Any],
              let rawUuid = args["uuid"] as? String,
              let uuid = UUID(uuidString: rawUuid), let owner = self else {
          result(FlutterError(code: "INVALID_UUID", message: "Missing call UUID", details: nil))
          return
        }
        owner.orphanEndUuids.insert(uuid)
        owner.orphanCallController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
          DispatchQueue.main.async {
            if let error = error {
              owner.orphanEndUuids.remove(uuid)
              result(FlutterError(code: "CALLKIT_END", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
        }
      case "setInCall":
        if let args = call.arguments as? [String: Any],
           let inCall = args["inCall"] as? Bool {
          self?.isInCall = inCall
          if !inCall {
            self?.lastCallEndedAt = Date()
            self?.interruptedWhileInCall = false
          }
          UserDefaults.standard.set(inCall, forKey: "vant_in_active_call")
          print("📱 Call state synced: inCall=\(inCall)")
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Audio session interruption / route-change recovery

  private func notifyFlutterCallLifecycle(_ action: String) {
    DispatchQueue.main.async { [weak self] in
      self?.callStateChannel?.invokeMethod(
        "onCallAction",
        arguments: ["action": action]
      )
    }
  }

  private func setupAudioSessionObservers() {
    guard !audioSessionObserversRegistered else { return }
    audioSessionObserversRegistered = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionInterruption),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioSessionRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  @objc private func handleAudioSessionInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

    switch type {
    case .began:
      print("🔊 Audio session interruption began (inCall=\(isInCall))")
      if isInCall {
        interruptedWhileInCall = true
        notifyFlutterCallLifecycle("call_held")
      }
    case .ended:
      guard isInCall else { return }
      notifyFlutterCallLifecycle("call_unheld")
      defer { interruptedWhileInCall = false }
      if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        if interruptedWhileInCall && options.contains(.shouldResume)
            && canReactivateAudioSession() {
          do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("🔊 Resumed audio session after interruption")
          } catch {
            print("⚠️ Failed to resume audio session: \(error)")
          }
        }
      }
    default:
      break
    }
  }

  /// True when re-activating the audio session is safe: a call is live and no
  /// teardown happened in the last 2s (Dart -> native setInCall is async, so
  /// isInCall can briefly lag the real call end).
  private func canReactivateAudioSession() -> Bool {
    guard isInCall else { return false }
    if let ended = lastCallEndedAt, Date().timeIntervalSince(ended) < 2 {
      return false
    }
    return true
  }

  @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
    guard isInCall,
          let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

    print("🔊 Audio route changed: \(reason.rawValue) (inCall=\(isInCall))")

    // After an external call hangs up, the system often routes audio back to
    // the built-in receiver. Re-activate the session so WebRTC can recover.
    // Skipped inside the post-teardown grace window (canReactivateAudioSession).
    if (reason == .categoryChange || reason == .override || reason == .wakeFromSleep)
        && canReactivateAudioSession() {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        print("⚠️ Failed to re-activate audio session after route change: \(error)")
      }
    }
  }
}
