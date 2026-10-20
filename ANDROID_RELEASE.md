# Android Release Notes — 1.8.9+200

Build: `app-prod-release.aab` (built from tag `release-android-1.8.9+200`, commit `1349f0d`)
Package: `com.vant.chat` · versionName `1.8.9` · versionCode `200`
minSdk 24 · targetSdk 36 · R8 minification enabled · release signing config

## Permissions (merged prod manifest)

Runtime/dangerous permissions are requested at first use, not at install.

| Permission | Why | Play Console declaration |
|---|---|---|
| `USE_FULL_SCREEN_INTENT` | Incoming-call full-screen UI over the lock screen (calling-app use case). | **Flagged** — Android 14+ restricts this to calling/alarm apps; Play review may require justification as a calling app. |
| `DISABLE_KEYGUARD` | Deprecated; legacy keyguard dismissal for call UI (harmless, ignored on modern APIs). | No |
| `USE_BIOMETRIC` / `USE_FINGERPRINT` | Optional biometric unlock/app lock. | No |
| `INTERNET` | Socket.IO signaling, FCM, API calls. | No |
| `WAKE_LOCK` | Keep CPU alive while ringing and during calls; proximity screen-off during calls. | No |
| `RECEIVE_BOOT_COMPLETED` | `BootReceiver` re-arms notification channels after device restart. | No |
| `VIBRATE` | Incoming-call vibration. | No |
| `POST_NOTIFICATIONS` | Android 13+ runtime permission for all notifications (calls, messages). | No (runtime) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Ask exempt-from-Doze so FCM + socket stay reliable for incoming calls. | **Flagged** — Play policy requires acceptable-use justification (calling app, core function). |
| `RECORD_AUDIO` | Voice/video call microphone. | No (runtime) — but see FGS declaration below |
| `CAMERA` | Video calls. | No (runtime) — but see FGS declaration below |
| `MODIFY_AUDIO_SETTINGS` | Audio routing during calls (speaker/earpiece/BT). | No |
| `READ_MEDIA_IMAGES` | Photo picking/sharing in chat (Android 13+). | **Flagged** — Play requires the "Photo and Video Permissions" declaration for apps requesting READ_MEDIA_IMAGES. |
| `READ_EXTERNAL_STORAGE` (maxSdk 32) | Photo picking on Android ≤12. | No |
| `WRITE_EXTERNAL_STORAGE` | Legacy saves on old Android; ignored on modern scoped-storage devices. | No — consider adding `maxSdkVersion` later |
| `FOREGROUND_SERVICE` | Base permission for all foreground services. | No |
| `FOREGROUND_SERVICE_MICROPHONE` | Active voice/video call mic while app is backgrounded. | **Flagged** — FGS-type declaration required in Play Console (functionality: voice/video calling). |
| `FOREGROUND_SERVICE_CAMERA` | Video call camera while app is backgrounded. | **Flagged** — FGS-type declaration (video calling). |
| `FOREGROUND_SERVICE_PHONE_CALL` | Ongoing-call foreground service. | **Flagged** — FGS-type declaration (voice calling). |
| `FOREGROUND_SERVICE_SHORT_SERVICE` | Ringing-only service (≤ ~3 min) before answer. | **Flagged** — FGS-type declaration (incoming call presentation). |
| `MANAGE_OWN_CALLS` | Self-managed Telecom ConnectionService (WhatsApp-style calling UX). | **Flagged** — reviewed under calling-related permissions; justifies app category. |
| `ACCESS_NETWORK_STATE` | Connectivity checks (socket/WebRTC). | No |
| `ACCESS_NOTIFICATION_POLICY` | Plugin-injected; notification-policy state checks. | No |
| `BLUETOOTH_CONNECT` | Bluetooth headset routing during calls (flutter_webrtc plugin). | No (runtime) |
| `android.hardware.sensor.proximity` | Proximity wake lock — screen off at ear during calls. | No |
| `com.google.android.c2dm.permission.RECEIVE` | FCM delivery. | No |
| `com.google.android.gms.permission.AD_ID` + `ACCESS_ADSERVICES_*` | Pulled in by Firebase/Play Services (analytics/install referrer). | **Flagged** — Play requires the Advertising ID declaration (answer: used for analytics, not ads). |
| `BIND_GET_INSTALL_REFERRER_SERVICE` | Install-referrer attribution (Firebase/Play). | No |
| `com.vant.chat.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Auto-generated signature-level guard for dynamic receivers (targetSdk 34+). | No |
| `com.vant.chat.PERMISSION_CALL` | App-defined signature permission guarding `VantConnectionService`. | No |
| Launcher badge perms (`com.sec.*`, `com.htc.*`, `com.sony*`, `com.anddoes.*`, `com.majeur.*`, `com.huawei.*`, `com.hihonor.*`, `com.vivo.*`) | Unread-count badge on OEM launchers; silently ignored where unsupported. | No |

### Play Console declarations checklist
1. **Foreground service types** — declare `microphone`, `camera`, `phoneCall`, `shortService` with description "incoming/active voice & video calls".
2. **Battery optimization exemption** — justify: calling app, real-time delivery is core function.
3. **Photo and Video permissions** — `READ_MEDIA_IMAGES` for chat media sharing.
4. **Advertising ID** — declare usage (analytics only, if applicable).
5. **Calling app category** — `MANAGE_OWN_CALLS` + `USE_FULL_SCREEN_INTENT` are covered under the calling-app core-functionality justification.

## Firebase Remote Config

Service: `FeatureFlagService` (`lib/core/services/feature_flag_service.dart`)

| Key | Type | Default | Effect |
|---|---|---|---|
| `ff_verification_ui` | bool | `false` | Phase-1 contact verification screen |
| `ff_encrypted_signaling` | bool | `false` | E2E SDP/ICE call-signaling encryption (Ed25519/X25519/HKDF/AES-GCM) |
| `ff_video_calling` | bool | `false` | Video call offers/answers |

Behavior:
- Fetch timeout 10 s; `minimumFetchInterval` = **1 h in release**, 0 in debug.
- All flags default **off**; a fetch failure never enables anything.
- Last-applied values are hydrated from `SharedPreferences` (`ff_cache_*`) before the network fetch so cold-start call flows see real flags immediately.
- During a ringing/pending call the socket registration **skips** the Remote Config wait (`callUrgency`), then the crypto gate waits on `initialFetchCompleted` so an encrypted call is never rejected merely because RC is still fetching.
- Real-time config updates re-apply flags and re-announce socket capabilities.

## Diagnostics
All `⏱️/⚡/🎛️` timing instrumentation routes through `callDiag()` (`lib/core/services/call_diag.dart`), which compiles to a no-op in release builds. Functional `debugPrint` logs (call lifecycle, errors) remain.
