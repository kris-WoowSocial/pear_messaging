package com.vant.chat

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
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
        val connection = VantConnection(applicationContext).apply {
            setCallerDisplayName(calleeName, TelecomManager.PRESENTATION_ALLOWED)
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            setInitializing()
            setDialing()
            setConnectionExtra("caller_name", calleeName)
            setConnectionExtra("caller_id", calleeId)
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
