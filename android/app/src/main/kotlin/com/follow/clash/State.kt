package com.follow.clash

import android.net.VpnService
import com.follow.clash.common.GlobalState
import com.follow.clash.common.Phase4Mark
import com.follow.clash.models.SharedState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.SessionSnapshot
import com.follow.clash.service.models.SessionState
import com.google.gson.Gson
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class RunState {
    START, PENDING, STOP
}

internal fun runStateForSessionState(state: String): RunState = when (state) {
    SessionState.RUNNING -> RunState.START
    SessionState.STARTING, SessionState.STOPPING -> RunState.PENDING
    SessionState.PAUSED, SessionState.STOPPED -> RunState.STOP
    else -> RunState.STOP
}

internal enum class SessionCommand {
    START, STOP, SMART_RESUME, NONE
}

internal fun toggleCommandForSessionState(state: String): SessionCommand = when (state) {
    SessionState.RUNNING -> SessionCommand.STOP
    SessionState.PAUSED -> SessionCommand.SMART_RESUME
    SessionState.STOPPED -> SessionCommand.START
    else -> SessionCommand.NONE
}

internal fun startAcknowledged(state: String): Boolean =
    state == SessionState.RUNNING || state == SessionState.PAUSED

internal fun permissionIntentIsCurrent(expected: Long, pending: Long?, stopEpoch: Long): Boolean =
    expected == stopEpoch && pending == expected

internal fun canFullStopSession(state: String): Boolean =
    state == SessionState.RUNNING || state == SessionState.PAUSED

internal enum class StopRequestAction {
    CANCEL_PENDING_START,
    FULL_STOP,
    WAIT_FOR_TRANSITION,
}

internal fun stopRequestActionForSessionState(state: String): StopRequestAction = when (state) {
    SessionState.RUNNING, SessionState.PAUSED -> StopRequestAction.FULL_STOP
    SessionState.STARTING, SessionState.STOPPING -> StopRequestAction.WAIT_FOR_TRANSITION
    else -> StopRequestAction.CANCEL_PENDING_START
}

internal fun canAttemptExplicitStart(runState: RunState): Boolean =
    runState != RunState.PENDING

internal fun canAttemptExplicitStartAfterReconcile(
    localState: RunState,
    authoritativeState: String?,
): Boolean {
    if (localState != RunState.PENDING) return canAttemptExplicitStart(localState)
    val reconciledState = authoritativeState?.let(::runStateForSessionState) ?: return false
    return canAttemptExplicitStart(reconciledState)
}

internal fun isTerminalSessionState(state: String): Boolean =
    state != SessionState.STARTING && state != SessionState.STOPPING

object State {

    val runLock = Mutex()
    private val stopEpoch = AtomicLong(0)
    private var pendingStartEpoch: Long? = null

    var runTime: Long = 0

    var sessionSnapshot: SessionSnapshot = SessionSnapshot.stopped()

    var sharedState: SharedState = SharedState()

    val runStateFlow: MutableStateFlow<RunState> = MutableStateFlow(RunState.STOP)

    var flutterEngine: FlutterEngine? = null

    val appPlugin: AppPlugin?
        get() = flutterEngine?.plugin<AppPlugin>()

    val tilePlugin: TilePlugin?
        get() = flutterEngine?.plugin<TilePlugin>()

    suspend fun handleToggleAction() {
        handleSyncState()
        Phase4Mark.emit(
            "vpn_action_requested",
            mapOf("action" to "toggle", "source" to "temp_activity", "run_state" to runStateFlow.value),
        )
        var action: (suspend () -> Unit)?
        runLock.withLock {
            action = when (toggleCommandForSessionState(sessionSnapshot.state)) {
                SessionCommand.STOP -> ::handleStopServiceAction
                SessionCommand.SMART_RESUME -> ::handleSmartResumeAction
                SessionCommand.START -> ::handleStartServiceAction
                SessionCommand.NONE -> null
            }
        }
        action?.invoke()
    }

    suspend fun handleSmartStopAction() {
        Phase4Mark.emit(
            "vpn_action_requested",
            mapOf("action" to "smart_stop", "source" to "temp_activity", "run_state" to runStateFlow.value),
        )
        if (flutterEngine != null) {
            tilePlugin?.handleSmartStop()
            return
        }
        Service.bind()
        Service.smartStop()
        handleSyncState()
    }

    suspend fun handleSmartResumeAction() {
        Phase4Mark.emit(
            "vpn_action_requested",
            mapOf("action" to "smart_resume", "source" to "temp_activity", "run_state" to runStateFlow.value),
        )
        if (flutterEngine != null) {
            tilePlugin?.handleSmartResume()
            return
        }
        Service.bind()
        Service.smartResume()
        handleSyncState()
    }

    suspend fun handleSyncState(): SessionSnapshot? {
        return runLock.withLock {
            Service.bind()
            Service.getSessionSnapshot()
                .onSuccess(::applySnapshot)
                .onFailure { GlobalState.log("Session snapshot unavailable: ${it.message}") }
                .getOrNull()
        }
    }

    private suspend fun reconcilePendingBeforeExplicitStart(): Boolean {
        val localState = runStateFlow.value
        if (localState != RunState.PENDING) return canAttemptExplicitStart(localState)
        val snapshot = handleSyncState()
        return canAttemptExplicitStartAfterReconcile(localState, snapshot?.state)
    }

    suspend fun handleServiceLifecycleSignal() {
        repeat(6) {
            handleSyncState()
            if (isTerminalSessionState(sessionSnapshot.state)) {
                tilePlugin?.handleSync()
                return
            }
            delay(250L)
        }
        tilePlugin?.handleSync()
    }

    private fun applySnapshot(snapshot: SessionSnapshot) {
        sessionSnapshot = snapshot
        runTime = snapshot.takeIf { it.state == SessionState.RUNNING }?.startedAt ?: 0L
        val runState = runStateForSessionState(snapshot.state)
        Phase4Mark.emit(
            "vpn_snapshot",
            mapOf(
                "layer" to "android_app",
                "state" to snapshot.state,
                "session_id" to snapshot.sessionId,
                "started_at" to snapshot.startedAt,
                "smart_paused" to snapshot.smartPaused,
                "run_state" to runState,
                "run_time" to runTime,
            ),
        )
        runStateFlow.tryEmit(runState)
    }

    suspend fun handleStartServiceAction() {
        Service.bind()
        Service.clearTaskRemovalStop()
        Phase4Mark.emit(
            "vpn_action_requested",
            mapOf("action" to "start", "source" to "android_action", "run_state" to runStateFlow.value),
        )
        if (!reconcilePendingBeforeExplicitStart()) {
            return
        }
        tilePlugin?.handleStart()
        if (flutterEngine != null) {
            return
        }
        startServiceWithPref()
    }

    suspend fun handleStopServiceAction() {
        handleSyncState()
        Phase4Mark.emit(
            "vpn_action_requested",
            mapOf("action" to "stop", "source" to "android_action", "run_state" to runStateFlow.value),
        )
        tilePlugin?.handleStop()
        val stopped = stopServiceAndAwait()
        if (flutterEngine != null) {
            return
        }
        if (stopped) {
            GlobalState.application.showToast(sharedState.stopTip)
        }
    }

    suspend fun handleStartService(expectedEpoch: Long = stopEpoch.get()): Boolean {
        if (expectedEpoch != stopEpoch.get()) return false
        // Always re-check VPN preparation. Android grants VPN ownership to only
        // one package at a time, so a cached RUNNING state does not prove that
        // this package is still the prepared VPN application.
        if (!reconcilePendingBeforeExplicitStart()) return false
        runLock.withLock {
            if (expectedEpoch != stopEpoch.get() || pendingStartEpoch != null ||
                !canAttemptExplicitStart(runStateFlow.value)) {
                return false
            }
            pendingStartEpoch = expectedEpoch
            if (runStateFlow.value == RunState.STOP) {
                runStateFlow.tryEmit(RunState.PENDING)
            }
        }
        // Lock released — wait for permissions without blocking other operations
        try {
            val options = sharedState.vpnOptions
            if (options == null) {
                runLock.withLock {
                    if (permissionIntentIsCurrent(expectedEpoch, pendingStartEpoch, stopEpoch.get())) {
                        applySnapshot(sessionSnapshot)
                    }
                }
                return false
            }

            val appPlugin = flutterEngine?.plugin<AppPlugin>()
            if (appPlugin != null) {
                Phase4Mark.emit("vpn_permission_begin", mapOf("permission" to "notification"))
                val notificationReady = appPlugin.requestNotificationsPermissionAwait()
                Phase4Mark.emit(
                    "vpn_permission_result",
                    mapOf("permission" to "notification", "granted" to notificationReady),
                )
                if (!notificationReady) {
                    // 通知权限拒绝不阻断启动，继续
                }
                Phase4Mark.emit("vpn_permission_begin", mapOf("permission" to "vpn"))
                val vpnPrepared = appPlugin.prepareVpnAwait(options.enable)
                Phase4Mark.emit(
                    "vpn_permission_result",
                    mapOf("permission" to "vpn", "granted" to vpnPrepared),
                )
                if (!vpnPrepared) {
                    runLock.withLock {
                        if (pendingStartEpoch == expectedEpoch && stopEpoch.get() == expectedEpoch) {
                            applySnapshot(sessionSnapshot)
                        }
                    }
                    return false
                }
            } else {
                Phase4Mark.emit("vpn_permission_begin", mapOf("permission" to "vpn"))
                val intent = VpnService.prepare(GlobalState.application)
                Phase4Mark.emit(
                    "vpn_permission_result",
                    mapOf("permission" to "vpn", "granted" to (intent == null)),
                )
                if (intent != null) {
                    runLock.withLock {
                        if (pendingStartEpoch == expectedEpoch && stopEpoch.get() == expectedEpoch) {
                            applySnapshot(sessionSnapshot)
                        }
                    }
                    return false
                }
            }

            // Re-acquire lock and commit. START is also intentional here: the
            // remote layer must validate that its RUNNING session still has an
            // operational TUN before it may return success.
            return runLock.withLock {
                if (!permissionIntentIsCurrent(expectedEpoch, pendingStartEpoch, stopEpoch.get())) {
                    return@withLock false
                }
                startServiceLocked()
            }
        } catch (e: Exception) {
            runLock.withLock {
                if (permissionIntentIsCurrent(expectedEpoch, pendingStartEpoch, stopEpoch.get())) {
                    applySnapshot(sessionSnapshot)
                }
            }
            return false
        } finally {
            runLock.withLock {
                if (pendingStartEpoch == expectedEpoch) pendingStartEpoch = null
            }
        }
    }

    private fun startServiceWithPref() {
        GlobalState.launch {
            sharedState = GlobalState.application.sharedState
            setupAndStart()
        }
    }

    suspend fun syncState() {
        Service.updateNotificationParams(
            NotificationParams(
                title = sharedState.currentProfileName,
                stopText = sharedState.stopText,
                onlyStatisticsProxy = sharedState.onlyStatisticsProxy
            )
        )
    }

    private suspend fun setupAndStart() {
        val expectedEpoch = stopEpoch.get()
        Service.bind()
        syncState()
        val initParams = mutableMapOf<String, Any>()
        initParams["home-dir"] = GlobalState.application.filesDir.path
        initParams["version"] = android.os.Build.VERSION.SDK_INT
        val initParamsString = Gson().toJson(initParams)
        val setupParamsString = Gson().toJson(sharedState.setupParams)
        val setupResult = Service.quickSetup(
            initParamsString,
            setupParamsString,
        )
        if (!setupResult.success) {
            GlobalState.log("Setup failed: ${setupResult.errorCode} ${setupResult.message}")
            setupResult.message?.takeIf { it.isNotEmpty() }?.let {
                GlobalState.application.showToast(it)
            }
            runLock.withLock {
                if (expectedEpoch == stopEpoch.get()) {
                    Service.getSessionSnapshot().onSuccess(::applySnapshot)
                }
            }
            return
        }
        if (handleStartService(expectedEpoch)) {
            GlobalState.application.showToast(sharedState.startTip)
        }
    }

    private suspend fun startServiceSafely(): Boolean {
        return handleStartService()
    }

    private suspend fun startServiceLocked(): Boolean {
        try {
            val options = sharedState.vpnOptions
            if (options == null) {
                runTime = 0L
                runStateFlow.tryEmit(RunState.STOP)
                return false
            }

            val result = Service.startService(options, runTime)
            Phase4Mark.emit(
                "vpn_service_result",
                mapOf(
                    "action" to "start",
                    "success" to result.success,
                    "run_time" to result.runTime,
                    "error_code" to result.errorCode,
                ),
            )
            if (result.success && result.runTime > 0L) {
                val snapshot = awaitStartSnapshot()
                if (snapshot != null) {
                    applySnapshot(snapshot)
                    return startAcknowledged(snapshot.state)
                }
                GlobalState.log("Started, but session snapshot remains unavailable")
                runStateFlow.tryEmit(RunState.PENDING)
                return false
            }

            if (result.errorCode == com.follow.clash.service.models.ServiceErrorCode.SERVICE_DISCONNECTED) {
                val snapshot = awaitStartSnapshot()
                if (snapshot != null) {
                    applySnapshot(snapshot)
                    when (snapshot.state) {
                        SessionState.RUNNING, SessionState.PAUSED -> return true
                        SessionState.STARTING -> return false
                        SessionState.STOPPED -> Unit
                    }
                } else {
                    GlobalState.log("Start result is unknown; keeping pending until snapshot can be reconciled")
                    runStateFlow.tryEmit(RunState.PENDING)
                    return false
                }
            }

            GlobalState.log("Start failed: ${result.errorCode} ${result.message}")
            result.message?.takeIf { it.isNotEmpty() }?.let {
                GlobalState.application.showToast(it)
            }

            runTime = 0L
            runStateFlow.tryEmit(RunState.STOP)
            return false
        } catch (e: Exception) {
            GlobalState.log("Start state reconciliation failed: ${e.message}")
            runStateFlow.tryEmit(RunState.PENDING)
            return false
        }
    }

    private suspend fun awaitStartSnapshot(): SessionSnapshot? {
        repeat(4) { attempt ->
            Service.getSessionSnapshot().getOrNull()?.let { snapshot ->
                if (snapshot.state != SessionState.STARTING || attempt == 3) {
                    return snapshot
                }
            }
            delay(750L)
        }
        return null
    }

    fun handleStopService() {
        GlobalState.launch {
            stopServiceAndAwait()
        }
    }

    suspend fun stopServiceAndAwait(): Boolean {
        stopEpoch.incrementAndGet()
        return runLock.withLock {
            pendingStartEpoch = null
            when (stopRequestActionForSessionState(sessionSnapshot.state)) {
                StopRequestAction.CANCEL_PENDING_START -> {
                    // A Flutter Start can still be preparing Core/config or
                    // waiting for VPN permission while the authoritative
                    // native session remains STOPPED. Invalidating stopEpoch
                    // above is sufficient; dispatching a remote full-stop here
                    // would tear down the service underneath that cancelled
                    // request and surface a spurious binder disconnect.
                    applySnapshot(sessionSnapshot)
                    return@withLock sessionSnapshot.state == SessionState.STOPPED
                }
                StopRequestAction.WAIT_FOR_TRANSITION -> {
                    // STARTING/STOPPING are serialized remote transitions.
                    // A rapid UI tap must not destroy their physical service;
                    // lifecycle signals will publish the terminal snapshot.
                    return@withLock false
                }
                StopRequestAction.FULL_STOP -> Unit
            }
            try {
                runStateFlow.tryEmit(RunState.PENDING)
                val result = Service.stopService()
                Phase4Mark.emit(
                    "vpn_service_result",
                    mapOf(
                        "action" to "stop",
                        "success" to result.success,
                        "error_code" to result.errorCode,
                    ),
                )
                if (result.success) {
                    applySnapshot(
                        Service.getSessionSnapshot().getOrNull()
                            ?: SessionSnapshot.stopped()
                    )
                } else {
                    GlobalState.log("Stop failed: ${result.errorCode} ${result.message}")
                    Service.getSessionSnapshot().onSuccess(::applySnapshot)
                }
                result.success && sessionSnapshot.state == SessionState.STOPPED
            } finally {
                if (runStateFlow.value == RunState.PENDING) {
                    runStateFlow.tryEmit(runStateForSessionState(sessionSnapshot.state))
                }
            }
        }
    }
}



