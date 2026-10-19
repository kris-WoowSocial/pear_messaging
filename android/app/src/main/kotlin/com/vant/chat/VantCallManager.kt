package com.vant.chat

import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.telecom.CallAudioState
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Singleton that manages the Telecom integration for incoming VoIP calls.
 *
 * Flow:
 * 1. FCM message arrives → VantFirebaseMessagingService calls reportIncomingCall()
 * 2. reportIncomingCall() registers PhoneAccount + calls addNewIncomingCall()
 * 3. Android Telecom binds to VantConnectionService → creates VantConnection
 * 4. VantConnection.onShowIncomingCallUi() is called → we show notification + activity
 * 5. Since the call is registered with Telecom, full-screen intent is GUARANTEED to work
 */
object VantCallManager {

    const val TAG = "VantCallMgr"
    const val PHONE_ACCOUNT_ID = "vant_voip_account"
    const val CHANNEL_ID = "vant_chat_calls"
    const val NOTIFICATION_ID = 9999

    var activeConnection: VantConnection? = null

    // Tracks whether onShowIncomingCallUi was called by the system
    private val callUiShown = AtomicBoolean(false)

    // Fallback data in case Telecom rejects the call or doesn't trigger UI
    private var pendingCallData: Map<String, String>? = null

    /**
     * Register the PhoneAccount with Android Telecom.
     * Must be called before addNewIncomingCall.
     */
    fun ensurePhoneAccountRegistered(context: Context) {
        try {
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = getPhoneAccountHandle(context)

            val account = PhoneAccount.builder(handle, "Vant Chat Calls")
                .setCapabilities(
                    PhoneAccount.CAPABILITY_SELF_MANAGED or
                        PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING
                )
                .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_SIP))
                .build()

            telecomManager.registerPhoneAccount(account)
            Log.d(TAG, "PhoneAccount registered")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register PhoneAccount: ${e.message}", e)
        }
    }

    /**
     * Report an incoming call to Android Telecom.
     * This triggers the system to bind to VantConnectionService and eventually
     * call onShowIncomingCallUi() which shows the full-screen call UI.
     */
    fun reportIncomingCall(
        context: Context,
        callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ): Boolean {
        try {
            ensurePhoneAccountRegistered(context)

            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            val handle = getPhoneAccountHandle(context)

            val extras = Bundle().apply {
                putString("caller_name", callerName)
                putString("caller_id", callerId)
                putString("call_id", callId)
                putString("room_id", roomId)
                putString("avatar_url", avatarUrl)
                putBoolean("is_video", isVideo)
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            }

            // Store for fallback
            pendingCallData = mapOf(
                "callerName" to callerName,
                "callerId" to callerId,
                "callId" to callId,
                "roomId" to roomId,
                "avatarUrl" to avatarUrl,
                "isVideo" to isVideo.toString()
            )

            // Clean up any stale connection from a previous call
            disconnectActiveCall()

            callUiShown.set(false)
            telecomManager.addNewIncomingCall(handle, extras)
            Log.d(TAG, "Reported incoming call to Telecom: $callerName ($callId)")

            // Samsung OneUI may not always call onShowIncomingCallUi reliably.
            // Fallback: if UI hasn't been shown within 800ms, show it directly.
            Handler(Looper.getMainLooper()).postDelayed({
                if (!callUiShown.get()) {
                    Log.w(TAG, "⚠️ Telecom didn't trigger onShowIncomingCallUi within 800ms, using fallback")
                    presentIncomingCall(context, callerName, callerId, callId, roomId, avatarUrl, isVideo)
                }
            }, 800)

            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException reporting call to Telecom: ${e.message}", e)
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Failed to report call to Telecom: ${e.message}", e)
            return false
        }
    }

    /**
     * Called from VantConnection.onShowIncomingCallUi() to signal that the system
     * triggered the call UI. Prevents the fallback timer from firing.
     */
    fun markCallUiShown() {
        callUiShown.set(true)
        Log.d(TAG, "Call UI shown by Telecom framework")
    }

    /**
     * Called when Telecom rejects our incoming call (onCreateIncomingConnectionFailed).
     * Fall back to direct notification + activity approach.
     */
    fun onTelecomFailed() {
        Log.w(TAG, "Telecom failed — using fallback notification approach")
        // Don't set callUiShown here — let the 800ms fallback timer handle it.
        // The timer will fire and show notification + activity directly.
    }

    /**
     * Disconnect the active Telecom connection (e.g. when call is cancelled by caller).
     */
    fun disconnectActiveCall() {
        try {
            activeConnection?.let {
                it.setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
                it.destroy()
                Log.d(TAG, "Active connection disconnected")
            }
            activeConnection = null
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting: ${e.message}", e)
        }
    }

    fun teardownCall(context: Context, callId: String = ""): Boolean {
        val connection = activeConnection
        val activeCallId = connection?.getConnectionExtra("call_id") ?: ""
        if (callId.isNotEmpty() && activeCallId.isNotEmpty() && callId != activeCallId) {
            Log.w(TAG, "Skipping teardown for stale call $callId; active call is $activeCallId")
            return false
        }

        try {
            activeConnection = null
            connection?.setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
            connection?.destroy()
        } catch (e: Exception) {
            Log.e(TAG, "Error ending Telecom connection: ${e.message}", e)
        }

        releaseCallResources(context, callId)
        return true
    }

    fun releaseCallResources(context: Context, callId: String = "") {
        try {
            context.stopService(Intent(context, CallForegroundService::class.java))
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping foreground service: ${e.message}", e)
        }
        cancelNotification(context)
        pendingCallData = null
        callUiShown.set(false)

        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            }
            audioManager.isSpeakerphoneOn = false
            audioManager.mode = AudioManager.MODE_NORMAL
        } catch (e: Exception) {
            Log.e(TAG, "Error restoring call audio state: ${e.message}", e)
        }

        context.sendBroadcast(Intent("com.vant.chat.CANCEL_CALL").apply {
            putExtra("call_id", callId)
        })
    }

    fun clearActiveConnection(connection: VantConnection) {
        if (activeConnection === connection) {
            activeConnection = null
        }
    }

    /**
     * Set the call audio route (speakerphone vs earpiece).
     *
     * When a self-managed Telecom Connection is active, the framework owns the
     * audio routing and may ignore AudioManager/AudioSwitch requests. We must
     * therefore route through Telecom's Connection.setAudioRoute(). A fallback
     * to AudioManager is provided when no connection exists or the API is
     * unavailable.
     */
    fun setAudioRoute(context: Context, speakerOn: Boolean) {
        activeConnection?.let { connection ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val route = if (speakerOn) {
                    CallAudioState.ROUTE_SPEAKER
                } else {
                    CallAudioState.ROUTE_EARPIECE
                }
                try {
                    connection.setAudioRoute(route)
                    Log.d(
                        TAG,
                        "setAudioRoute: ${if (speakerOn) "SPEAKER" else "EARPIECE"} via Telecom"
                    )
                    return
                } catch (e: Exception) {
                    Log.e(TAG, "Telecom setAudioRoute failed, falling back: ${e.message}", e)
                }
            }
        }
        setAudioRouteViaAudioManager(context, speakerOn)
    }

    private fun setAudioRouteViaAudioManager(context: Context, speakerOn: Boolean) {
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                val speakerDevice = devices.find { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                val earpieceDevice = devices.find { it.type == AudioDeviceInfo.TYPE_TELEPHONY }
                when {
                    speakerOn && speakerDevice != null -> audioManager.setCommunicationDevice(speakerDevice)
                    !speakerOn && earpieceDevice != null -> audioManager.setCommunicationDevice(earpieceDevice)
                    else -> audioManager.isSpeakerphoneOn = speakerOn
                }
            } else {
                audioManager.isSpeakerphoneOn = speakerOn
            }
            Log.d(
                TAG,
                "setAudioRoute: ${if (speakerOn) "SPEAKER" else "EARPIECE"} via AudioManager"
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error setting audio route via AudioManager: ${e.message}", e)
        }
    }

    fun getPhoneAccountHandle(context: Context): PhoneAccountHandle {
        return PhoneAccountHandle(
            ComponentName(context, VantConnectionService::class.java),
            PHONE_ACCOUNT_ID
        )
    }

    fun reportOutgoingCall(
        context: Context,
        calleeName: String,
        calleeId: String,
        isVideo: Boolean
    ): Boolean {
        return try {
            ensurePhoneAccountRegistered(context)
            disconnectActiveCall()

            val handle = getPhoneAccountHandle(context)
            val extras = Bundle().apply {
                putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                putString("caller_name", calleeName)
                putString("caller_id", calleeId)
                putBoolean("is_video", isVideo)
            }
            val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            telecomManager.placeCall(Uri.fromParts(PhoneAccount.SCHEME_SIP, calleeId, null), extras)
            Log.d(TAG, "Reported outgoing call to Telecom: $calleeId")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to report outgoing call: ${e.message}", e)
            false
        }
    }

    fun markActiveCall(callId: String) {
        try {
            if (callId.isNotEmpty()) {
                activeConnection?.setConnectionExtra("call_id", callId)
            }
            activeConnection?.setActive()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to mark active connection: ${e.message}", e)
        }
    }

    // ==================== UI ACTIONS (called from VantConnection) ====================

    fun startRinging(
        context: Context, callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        val intent = Intent(context, CallForegroundService::class.java).apply {
            action = CallForegroundService.ACTION_START_RINGING
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("avatar_url", avatarUrl)
            putExtra("is_video", isVideo)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stopRinging(context: Context) {
        try {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                action = CallForegroundService.ACTION_STOP_RINGING
            }
            context.startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping ringing: ${e.message}")
        }
    }

    fun showCallNotification(
        context: Context, callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        // Fallback notification shown only when IncomingCallActivity cannot be launched.
        // It is silent: the CallForegroundService already plays the ringtone.
        val fullScreenIntent = Intent(context, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("avatar_url", avatarUrl)
            putExtra("is_video", isVideo)
        }

        val fullScreenPendingIntent = PendingIntent.getActivity(
            context, 0, fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val answerIntent = Intent(context, MainActivity::class.java).apply {
            action = "com.vant.chat.ANSWER_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("room_id", roomId)
            putExtra("caller_name", callerName)
            putExtra("caller_id", callerId)
            putExtra("is_video", isVideo)
            putExtra("from_native", true)
            putExtra("answered_from_background", true)
        }
        val answerPendingIntent = PendingIntent.getActivity(
            context, 1, answerIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(context, MainActivity::class.java).apply {
            action = "com.vant.chat.DECLINE_CALL"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("call_id", callId)
            putExtra("caller_id", callerId)
        }
        val declinePendingIntent = PendingIntent.getActivity(
            context, 2, declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val caller = androidx.core.app.Person.Builder()
            .setName(callerName)
            .setIcon(
                androidx.core.graphics.drawable.IconCompat.createWithResource(
                    context,
                    R.drawable.ic_call_notification
                )
            )
            .build()

        val callStyle = NotificationCompat.CallStyle.forIncomingCall(
            caller,
            declinePendingIntent,
            answerPendingIntent
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(if (isVideo) "Incoming video call" else "Incoming call")
            .setContentText(callerName)
            .setSmallIcon(R.drawable.ic_call_notification)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(callStyle)
            .setContentIntent(fullScreenPendingIntent)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .setSilent(true)
            .build()

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Re-check at post time: if FSI was revoked since the call arrived, the
        // full-screen UI is suppressed right now and the heads-up/shade entry is
        // all the user will see.
        if (Build.VERSION.SDK_INT >= 34 && !notificationManager.canUseFullScreenIntent()) {
            Log.w(TAG, "DIAG posting call notification with fsi=DENIED — heads-up only")
        }
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    fun launchIncomingCallActivity(
        context: Context, callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ): Boolean {
        return try {
            val intent = Intent(context, IncomingCallActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS or
                        Intent.FLAG_ACTIVITY_CLEAR_TASK
                putExtra("caller_name", callerName)
                putExtra("caller_id", callerId)
                putExtra("call_id", callId)
                putExtra("room_id", roomId)
                putExtra("avatar_url", avatarUrl)
                putExtra("is_video", isVideo)
            }
            context.startActivity(intent)
            Log.d(TAG, "Launched IncomingCallActivity")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch IncomingCallActivity: ${e.message}", e)
            false
        }
    }

    /**
     * Shows the incoming call UI — same mechanism WhatsApp uses.
     *
     * The incoming-call alert is posted via NotificationManager.notify() with a
     * full-screen intent. This is the ONLY reliable path: direct startActivity()
     * from a background context is silently blocked (no exception), and
     * full-screen intents attached to foreground-service notifications do not
     * fire on several OEM builds (Transsion/XOS, some Xiaomi).
     *
     * We still try the direct activity launch as a fast path — when it works
     * (Telecom's launch exemption) the UI appears a beat earlier. The
     * notify()-posted alert fires the same activity via the OS whenever the
     * direct launch was blocked.
     *
     * Ringtone and vibration are handled by CallForegroundService.
     */
    fun presentIncomingCall(
        context: Context, callerName: String, callerId: String, callId: String,
        roomId: String, avatarUrl: String, isVideo: Boolean
    ) {
        startRinging(context, callerName, callerId, callId, roomId, avatarUrl, isVideo)
        // Always post the alert via notify(): this is what actually triggers the
        // system full-screen intent path. The direct launch below is best-effort.
        showCallNotification(context, callerName, callerId, callId, roomId, avatarUrl, isVideo)
        launchIncomingCallActivity(context, callerName, callerId, callId, roomId, avatarUrl, isVideo)
    }

    /**
     * Logcat-only diagnostics emitted when an incoming call arrives. Contains
     * no caller identity, tokens or phone numbers — just the device state that
     * decides whether the full-screen incoming-call UI can appear:
     * canUseFullScreenIntent, call-channel importance/sound, PhoneAccount
     * registration/enabled state, keyguard/screen state and Android version.
     */
    fun logIncomingCallDiagnostics(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val fsi = if (Build.VERSION.SDK_INT >= 34) nm.canUseFullScreenIntent() else true
            val channel = if (Build.VERSION.SDK_INT >= 26) {
                nm.getNotificationChannel(CHANNEL_ID)?.let {
                    "imp=${it.importance} sound=${it.sound != null} vib=${it.shouldVibrate()}"
                } ?: "missing"
            } else {
                "n/a"
            }
            val accountState = try {
                val tm = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                when (val account = tm.getPhoneAccount(getPhoneAccountHandle(context))) {
                    null -> "unregistered"
                    else -> if (account.isEnabled) "enabled" else "disabled"
                }
            } catch (e: Exception) {
                "error"
            }
            val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            Log.i(TAG, "DIAG incoming-call sdk=${Build.VERSION.SDK_INT} rel=${Build.VERSION.RELEASE} " +
                "fsi=$fsi channel[$CHANNEL_ID]=$channel phoneAccount=$accountState " +
                "locked=${km.isKeyguardLocked} interactive=${pm.isInteractive}")
            if (!fsi) {
                Log.w(TAG, "DIAG fsi=DENIED — full-screen call UI will be suppressed")
            }
        } catch (e: Exception) {
            Log.w(TAG, "DIAG failed: ${e.message}")
        }
    }

    fun cancelNotification(context: Context) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.e(TAG, "Error cancelling notification: ${e.message}")
        }
    }
}
