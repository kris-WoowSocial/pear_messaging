// Full FCM service — works on both Android and iOS via firebase_messaging.
// The previous 'dart.library.android' condition was invalid and always resolved
// to the iOS stub, which had Firebase Messaging disabled.
export 'fcm_service.dart';
