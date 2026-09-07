package com.follow.clash.service

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

internal fun nextWatchdogTriggerAt(now: Long, deadlineMillis: Long): Long = now + deadlineMillis

internal object VpnRecoveryWatchdog {
    const val HEARTBEAT_INTERVAL_MILLIS = 10_000L
    internal const val RECOVERY_DEADLINE_MILLIS = 15_000L
    private const val REQUEST_CODE_ELAPSED = 0x564E
    internal const val ACTION_RECOVER = "com.follow.clash.service.action.WATCHDOG_RECOVER_VPN"

    private fun pendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            REQUEST_CODE_ELAPSED,
            Intent(context, VpnRecoveryReceiver::class.java).setAction(ACTION_RECOVER),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    fun arm(context: Context): Boolean = runCatching {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val triggerAt = nextWatchdogTriggerAt(
            SystemClock.elapsedRealtime(),
            RECOVERY_DEADLINE_MILLIS,
        )
        val pendingIntent = pendingIntent(context)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()) {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent,
            )
        } else {
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent,
            )
        }
    }.isSuccess

    fun cancel(context: Context) {
        runCatching {
            context.getSystemService(AlarmManager::class.java).cancel(pendingIntent(context))
        }
    }
}

class VpnRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != VpnRecoveryWatchdog.ACTION_RECOVER) return
        VpnProcessRecovery.request(context, "watchdog")
    }
}
