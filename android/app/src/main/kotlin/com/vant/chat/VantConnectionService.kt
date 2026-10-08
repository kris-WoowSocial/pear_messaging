package com.vant.chat

import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log

/**
 * Self-managed ConnectionService for VoIP calls.
 *
 * This is how WhatsApp, Telegram, Signal etc. show full-screen incoming call UI
 * over the lock screen on Android 14+. By registering with Android's Telecom framework,
 * the system guarantees:
 * - Full-screen intent is always honored (even on Samsung OneUI)
 * - The call appears in the system call log
 * - Audio focus is managed correctly
 * - The call integrates with Bluetooth, Android Auto, etc.
 */
class VantConnectionService : ConnectionService() {

    companion object {
        const val TAG = "VantConnSvc"
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        Log.d(TAG, "onCreateIncomingConnection called")

        val extras = request?.extras
        val callerName = extras?.getString("caller_name") ?: "Unknown"
        val callerId = extras?.getString("caller_id") ?: ""
        val callId = extras?.getString("call_id") ?: ""
        val roomId = extras?.getString("room_id") ?: ""
        val avatarUrl = extras?.getString("avatar_url") ?: ""
        val isVideo = extras?.getBoolean("is_video", false) ?: false

        val connection = VantConnection(applicationContext).apply {
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setInitializing()
            setRinging()
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            // Hold support is declared on the Connection (not the PhoneAccount —
            // PhoneAccount capabilities use different bit values and mixing them
            // makes registerPhoneAccount throw SecurityException).
            var capabilities = Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            if (isVideo) {
                capabilities = capabilities or
                    Connection.CAPABILITY_SUPPORTS_VT_LOCAL_BIDIRECTIONAL or
                    Connection.CAPABILITY_SUPPORTS_VT_REMOTE_BIDIRECTIONAL
            }
            connectionCapabilities = capabilities
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setAudioModeIsVoip(true)
            }
            if (isVideo) {
                setVideoState(VideoProfile.STATE_BIDIRECTIONAL)
            }
            setConnectionExtra("caller_name", callerName)
            setConnectionExtra("caller_id", callerId)
            setConnectionExtra("call_id", callId)
            setConnectionExtra("room_id", roomId)
            setConnectionExtra("avatar_url", avatarUrl)
            setConnectionExtra("is_video", isVideo)
        }

        // Store the active connection so VantCallManager can reference it
        VantCallManager.activeConnection = connection

        Log.d(TAG, "Incoming connection created for $callerName")
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.e(TAG, "onCreateIncomingConnectionFailed — Telecom rejected the call")
        // Fallback: show notification-only approach
        VantCallManager.onTelecomFailed()
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        Log.d(TAG, "onCreateOutgoingConnection called")
        val extras = request?.extras
        val calleeName = extras?.getString("caller_name") ?: "Unknown"
        val calleeId = extras?.getString("caller_id") ?: ""
        val isVideo = extras?.getBoolean("is_video", false) ?: false
        val connection = VantConnection(applicationContext).apply {
            setCallerDisplayName(calleeName, TelecomManager.PRESENTATION_ALLOWED)
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            var capabilities = Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            if (isVideo) {
                capabilities = capabilities or
                    Connection.CAPABILITY_SUPPORTS_VT_LOCAL_BIDIRECTIONAL or
                    Connection.CAPABILITY_SUPPORTS_VT_REMOTE_BIDIRECTIONAL
            }
            connectionCapabilities = capabilities
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setAudioModeIsVoip(true)
            }
            if (isVideo) {
                setVideoState(VideoProfile.STATE_BIDIRECTIONAL)
            }
            setInitializing()
            setDialing()
            setConnectionExtra("caller_name", calleeName)
            setConnectionExtra("caller_id", calleeId)
            setConnectionExtra("is_video", isVideo)
        }
        VantCallManager.activeConnection = connection
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        Log.e(TAG, "onCreateOutgoingConnectionFailed")
    }
}
