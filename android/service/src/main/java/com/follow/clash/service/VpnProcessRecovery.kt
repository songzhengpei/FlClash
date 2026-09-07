package com.follow.clash.service

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.follow.clash.common.GlobalState
import com.follow.clash.common.Phase4Mark

internal fun shouldDispatchVpnProcessRecovery(checkpointHintValid: Boolean): Boolean =
    checkpointHintValid

internal fun shouldStopOrphanStartedService(
    checkpointValid: Boolean,
    taskRemovalStopRequested: Boolean,
    recoveryOrSystemRestart: Boolean,
    sessionKeepsService: Boolean,
): Boolean {
    if (taskRemovalStopRequested) return true
    if (sessionKeepsService) return false
    return !checkpointValid && recoveryOrSystemRestart
}

internal fun shouldContinueVpnRecovery(
    generation: Long,
    currentGeneration: Long,
    taskRemovalStopRequested: Boolean,
    checkpointValid: Boolean,
    forceNonSticky: Boolean,
): Boolean = generation == currentGeneration &&
    !taskRemovalStopRequested &&
    checkpointValid &&
    !forceNonSticky

object VpnProcessRecovery {
    fun request(context: Context, reason: String): Boolean {
        val app = context.applicationContext
        // Read-only hint. A stale empty cache only skips this fast path;
        // the remote watchdog stays armed. Never cancel or write here.
        if (!shouldDispatchVpnProcessRecovery(VpnRecoveryStore(app).peekValid() != null)) {
            Phase4Mark.emit(
                "vpn_process_recovery_request",
                mapOf("reason" to reason, "dispatched" to false),
            )
            return false
        }
        val dispatched = startVpnService(app)
        Phase4Mark.emit(
            "vpn_process_recovery_request",
            mapOf("reason" to reason, "dispatched" to dispatched),
        )
        GlobalState.log("VPN process recovery requested reason=$reason dispatched=$dispatched")
        return dispatched
    }

    internal fun startVpnService(context: Context): Boolean = runCatching {
        ContextCompat.startForegroundService(
            context,
            Intent(context, VpnService::class.java).setAction(VpnRecoveryWatchdog.ACTION_RECOVER),
        )
    }.isSuccess
}
