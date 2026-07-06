# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Stripe SDK
-keep class com.stripe.android.** { *; }
-keep class com.stripe.android.pushProvisioning.** { *; }
-dontwarn com.stripe.android.pushProvisioning.**

# Flutter Stripe Plugin
-keep class com.reactnativestripesdk.** { *; }
-dontwarn com.reactnativestripesdk.**

# Google Pay
-keep class com.google.android.gms.wallet.** { *; }
-dontwarn com.google.android.gms.wallet.**

# Preserve all annotations
-keepattributes *Annotation*

# Preserve line numbers for debugging
-keepattributes SourceFile,LineNumberTable

# Flutter method channels
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.engine.** { *; }

# Firebase Cloud Messaging
-keep class com.google.firebase.messaging.** { *; }
-keep class io.flutter.plugins.firebase.messaging.** { *; }
-dontwarn io.flutter.plugins.firebase.messaging.**

# Keep all Vant Chat classes (FCM service, foreground service, activities)
-keep class com.vant.chat.** { *; }

# Keep classes used for full-screen intent / notification actions
-keep class com.vant.chat.MainActivity$* { *; }

# Keep Flutter engine classes needed for background message forwarding
-keep class io.flutter.embedding.engine.FlutterEngine { *; }
-keep class io.flutter.embedding.engine.dart.DartExecutor { *; }
-keep class io.flutter.embedding.engine.dart.DartExecutor$DartCallback { *; }
-keep class io.flutter.embedding.engine.loader.FlutterLoader { *; }
-keep class io.flutter.view.FlutterCallbackInformation { *; }
-keep class io.flutter.plugin.common.MethodChannel { *; }
-keep class io.flutter.plugin.common.MethodChannel$MethodCallHandler { *; }
-keep class io.flutter.plugin.common.BinaryMessenger { *; }

# Keep service constructors (required for Android to instantiate services)
-keepclassmembers class * extends android.app.Service {
    public <init>();
}

# Keep Activity constructors
-keepclassmembers class * extends android.app.Activity {
    public <init>();
}

# Prevent R8 from stripping FirebaseMessagingService methods
-keepclassmembers class com.google.firebase.messaging.FirebaseMessagingService {
    public void onMessageReceived(com.google.firebase.messaging.RemoteMessage);
    public void onNewToken(java.lang.String);
    public void onDeletedMessages();
    public void onMessageSent(java.lang.String);
    public void onSendError(java.lang.String, java.lang.Exception);
}

# Android Telecom (ConnectionService for VoIP incoming calls)
-keep class android.telecom.** { *; }
-keep class androidx.core.telecom.** { *; }

# flutter_background_service
-keep class id.flutter.flutter_background_service.** { *; }
-dontwarn id.flutter.flutter_background_service.**

# Play Core split install (referenced by Flutter's PlayStoreDeferredComponentManager)
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile
