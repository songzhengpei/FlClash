package com.follow.clash.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.follow.clash.common.BroadcastAction
import com.follow.clash.common.GlobalState
import com.follow.clash.common.Phase4Mark
import com.follow.clash.common.ServiceDelegate
import com.follow.clash.common.TaskRemovalStopStore
import com.follow.clash.common.chunkedForAidl
import com.follow.clash.common.intent
import com.follow.clash.common.sendBroadcast
import com.follow.clash.core.Core
import com.follow.clash.service.State.delegate
import com.follow.clash.service.State.intent
import com.follow.clash.service.State.runLock
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.SessionSnapshot
import com.follow.clash.service.models.SessionState
import com.follow.clash.service.models.SessionTransitions
import com.follow.clash.service.models.ServiceErrorCode
import com.follow.clash.service.models.ServiceOperationResult
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.modules.NetworkObserveModule
import com.follow.clash.service.modules.PhysicalNetworkControlPlane
import com.follow.clash.service.modules.PhysicalNetworkSnapshot
import com.follow.clash.service.modules.PhysicalNetworkUpdateReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume

internal fun quickSetupOperationResult(message: String?): ServiceOperationResult = when {
    message == null -> ServiceOperationResult.failure(
        ServiceErrorCode.INTERNAL_ERROR,
        "Core quick setup returned no result",
    )
    message.isEmpty() -> ServiceOperationResult.success()
    message == "init failed" -> ServiceOperationResult.failure(
        ServiceErrorCode.CORE_INIT_FAILED,
        message,
    )
    else -> ServiceOperationResult.failure(
        ServiceErrorCode.CONFIG_LOAD_FAILED,
        message,
    )
}

internal fun canReuseRunningSession(state: String, operational: Boolean): Boolean =
    state == SessionState.RUNNING && operational

internal fun disconnectedSessionSnapshot(message: String): SessionSnapshot =
    SessionSnapshot.stopped(ServiceErrorCode.SERVICE_DISCONNECTED, message)

internal data class CleanupResolution(
    val snapshot: SessionSnapshot,
    val clearDelegate: Boolean,
)

internal fun cleanupResolution(
    current: SessionSnapshot,
    result: ServiceOperationResult,
): CleanupResolution = if (result.success) {
    CleanupResolution(
        snapshot = SessionSnapshot.stopped(),
        clearDelegate = true,
    )
} else {
    CleanupResolution(
        snapshot = current.copy(
            state = SessionState.STOPPING,
            lastErrorCode = result.errorCode,
            lastErrorMessage = result.message,
        ),
        clearDelegate = false,
    )
}

internal fun isCurrentDelegateGeneration(callbackGeneration: Long, currentGeneration: Long): Boolean =
    callbackGeneration == currentGeneration

class RemoteService : Service(), CoroutineScope {
    private val serviceJob = SupervisorJob()
    override val coroutineContext = serviceJob + Dispatchers.Default
    private val sessionCounter = AtomicLong(System.currentTimeMillis())
    private var delegateGeneration = 0L
    private val smartPausePolicy = SmartPausePolicy()
    @Volatile private var smartPauseConfig = SmartPauseConfig()
    @Volatile private var latestPhysicalNetwork: PhysicalNetworkSnapshot? = null
    private lateinit var policyExecutor: ConflatedPolicyExecutor<String>
    private val retryEpoch = AtomicLong(0L)
    private val unknownRetrySchedule = BoundedRetrySchedule(RETRY_DELAYS)
    private val transitionRetrySchedule = BoundedRetrySchedule(RETRY_DELAYS)
    private var unknownRetryJob: Job? = null
    private var transitionRetryJob: Job? = null
    private var lastStableNetworkId: Long? = null
    private val networkObserveModule by lazy { NetworkObserveModule(this) }
    private var networkObserverJob: Job? = null
    private var previousDesiredState: SmartPauseDesiredState? = null
    private var pendingRecovery: VpnRecoveryCheckpoint? = null
    private val recoveryStore by lazy { VpnRecoveryStore(this) }
    @Volatile private var activeSetupPayload: QuickSetupPayload? = null
    @Volatile private var forceNonSticky = false
    private var recoveryJob: Job? = null
    private var recoveryWatchdogJob: Job? = null
    private var recoveryGeneration = 0L
    private var activeRecoveryGeneration = 0L

    override fun onCreate() {
        super.onCreate()
        recoveryStore.readValid()?.let { checkpoint ->
            if (TaskRemovalExitGuard.applyIfNeeded(this, checkpoint)) {
                forceNonSticky = true
            }
        }
        val preferences = getSharedPreferences(SMART_PAUSE_PREFERENCES, Context.MODE_PRIVATE)
        smartPauseConfig = SmartPauseConfig(
            enabled = preferences.getBoolean(KEY_ENABLED, false),
            trustedNetworks = preferences.getStringSet(KEY_NETWORKS, emptySet()).orEmpty().toList(),
            closeConnections = preferences.getBoolean(KEY_CLOSE_CONNECTIONS, true),
        )
        policyExecutor = ConflatedPolicyExecutor(
            scope = this,
            evaluate = ::reconcileSmartPauseState,
            onError = { GlobalState.log("Smart Pause policy evaluator failed: ${it.message}") },
        )
        PhysicalNetworkControlPlane.attach(::onPhysicalNetworkSnapshot)
        networkObserverJob = launch {
            runCatching { networkObserveModule.install() }
                .onSuccess {
                    networkObserveModule.setCoreDnsUpdatesEnabled(
                        State.snapshot.state != SessionState.STOPPED,
                    )
                }
                .onFailure {
                    GlobalState.log("Physical network observer failed to install: ${it.message}")
                }
            requestSmartPauseEvaluation(PhysicalNetworkUpdateReason.SERVICE_CREATED.name)
        }
        requestSmartPauseEvaluation(PhysicalNetworkUpdateReason.SERVICE_CREATED.name)
    }

    private fun onPhysicalNetworkSnapshot(snapshot: PhysicalNetworkSnapshot) {
        latestPhysicalNetwork = snapshot
        invalidateTransitionRetry()
        if (classifySmartPauseNetwork(snapshot, smartPauseConfig.trustedNetworks) !=
            SmartPausePhysicalNetwork.UNKNOWN
        ) {
            unknownRetryJob?.cancel()
            unknownRetryJob = null
            unknownRetrySchedule.reset()
        }
        Phase4Mark.emit(
            "smart_pause_network_snapshot",
            mapOf(
                "network_generation" to snapshot.generation,
                "network_type" to snapshot.transport,
                "ip_count" to snapshot.ipv4Addresses.size,
                "known" to snapshot.isKnown,
            ),
        )
        requestSmartPauseEvaluation(snapshot.reason.name)
    }

    private fun requestSmartPauseEvaluation(reason: String): Long = policyExecutor.submit(reason)

    private suspend fun reconcileSmartPauseState(reason: String) {
        runLock.withLock {
            reconcileSmartPauseStateLocked(reason)
        }
    }

    private suspend fun reconcileSmartPauseStateLocked(reason: String): Boolean? {
        // Read physical truth only after acquiring runLock. A snapshot captured
        // while waiting for this lifecycle gate is historical, not authority.
        val network = latestPhysicalNetwork
        val current = State.snapshot
        val config = smartPauseConfig
        val recovering = pendingRecovery != null && current.state == SessionState.STARTING
        val networkState = classifySmartPauseNetwork(network, config.trustedNetworks)
        val previousOverride = smartPausePolicy.manualOverride
        val policyConfig = config.copy(
            enabled = config.enabled && State.options?.enable == true,
        )
        val desired = smartPausePolicy.desiredState(
            config = policyConfig,
            sessionState = current.state,
            network = networkState,
            unknownExhausted = unknownRetrySchedule.nextDelay() == null,
            recovering = recovering,
        )
        val action = smartPauseActionFor(current.state, desired, recovering)
        if (previousOverride != smartPausePolicy.manualOverride) {
            Phase4Mark.emit(
                "smart_pause_override_changed",
                mapOf(
                    "manual_override" to smartPausePolicy.manualOverride,
                    "source" to "policy",
                ),
            )
        }
        Phase4Mark.emit(
            "smart_pause_evaluate",
            mapOf(
                "session_state" to current.state,
                "session_id" to current.sessionId,
                "smart_paused" to current.smartPaused,
                "state_options_enable" to State.options?.enable,
                "config_enabled" to config.enabled,
                "network_state" to networkState.name,
                "network_generation" to (network?.generation ?: 0L),
                "trusted" to (networkState == SmartPausePhysicalNetwork.TRUSTED_WIFI),
                "ip_count" to (network?.ipv4Addresses?.size ?: 0),
                "reason" to reason,
                "manual_override" to smartPausePolicy.manualOverride,
                "desired" to desired.name,
                "action" to action.name,
                "attempt" to (transitionRetrySchedule.executedAttempts + 1),
            ),
        )
        runCatching {
            SmartPauseDiagnostics.record(
                context = this,
                sessionId = current.sessionId,
                reason = reason,
                runtimeState = current.state,
                previousDesiredState = previousDesiredState,
                desiredState = desired,
                networkState = networkState,
                network = network,
                trusted = networkState == SmartPausePhysicalNetwork.TRUSTED_WIFI,
                action = action,
            )
        }
        previousDesiredState = desired
        maybeCloseConnectionsForHandover(network, config, current)

        if (action == SmartPauseAction.RETRY) {
            scheduleUnknownRetry()
            return null
        }
        val transitionSucceeded = when {
            recovering -> completePendingRecoveryLocked(action)
            action == SmartPauseAction.PAUSE ->
                transitionSmartPauseLocked(current, true, "native_policy")
            action == SmartPauseAction.START ->
                resumePausedSessionLocked(current, PausedResumeSource.POLICY)
            else -> null
        }
        when (transitionSucceeded) {
            true -> clearTransitionRetry()
            false -> if (!recovering) scheduleTransitionRetry()
            null -> Unit
        }
        return transitionSucceeded
    }

    private suspend fun completePendingRecoveryLocked(action: SmartPauseAction): Boolean? {
        val checkpoint = pendingRecovery ?: return null
        if (!recoveryStillValidLocked(activeRecoveryGeneration)) {
            cleanupRecoveryAttemptLocked("VPN recovery was invalidated")
            return false
        }
        val starting = State.snapshot
        val next = when (action) {
            SmartPauseAction.PAUSE -> {
                val paused = delegate?.useService(timeoutMillis = 10_000L) { service ->
                    service.smartStop() && !service.isOperational()
                }?.getOrNull() == true
                if (!paused) return false
                SessionTransitions.paused(starting)
            }
            SmartPauseAction.START -> {
                val startResult = delegate?.useService(timeoutMillis = 10_000L) { service ->
                    service.start()
                }?.getOrNull() ?: ServiceOperationResult.failure(
                    ServiceErrorCode.SERVICE_DISCONNECTED,
                    "VPN recovery physical service is unavailable",
                )
                if (!startResult.success) return false
                SessionTransitions.running(starting)
            }
            SmartPauseAction.NO_ACTION,
            SmartPauseAction.RETRY,
            -> return null
        }
        if (!recoveryStillValidLocked(activeRecoveryGeneration)) {
            cleanupRecoveryAttemptLocked("VPN recovery was invalidated")
            return false
        }
        if (!persistCheckpoint(next, next.state, checkpoint.options, checkpoint.setup)) {
            return false
        }
        pendingRecovery = null
        applySession(next)
        BroadcastAction.SERVICE_CREATED.sendBroadcast()
        return true
    }

    @Synchronized
    private fun scheduleUnknownRetry() {
        if (unknownRetryJob?.isActive == true) return
        val retryDelay = unknownRetrySchedule.nextDelay() ?: return
        val attempt = unknownRetrySchedule.executedAttempts + 1
        Phase4Mark.emit("smart_pause_retry", mapOf("kind" to "unknown", "attempt" to attempt, "delay_ms" to retryDelay))
        unknownRetryJob = launch {
            delay(retryDelay)
            synchronized(this@RemoteService) {
                unknownRetryJob = null
                unknownRetrySchedule.markExecuted()
            }
            PhysicalNetworkControlPlane.refresh(
                PhysicalNetworkUpdateReason.UNKNOWN_RETRY,
            )
            requestSmartPauseEvaluation(PhysicalNetworkUpdateReason.UNKNOWN_RETRY.name)
        }
    }

    @Synchronized
    private fun scheduleTransitionRetry() {
        if (transitionRetryJob?.isActive == true) return
        val retryDelay = transitionRetrySchedule.nextDelay() ?: return
        val attempt = transitionRetrySchedule.executedAttempts + 1
        val epoch = retryEpoch.get()
        Phase4Mark.emit("smart_pause_retry", mapOf("kind" to "transition", "attempt" to attempt, "delay_ms" to retryDelay))
        transitionRetryJob = launch {
            delay(retryDelay)
            synchronized(this@RemoteService) {
                transitionRetryJob = null
                if (retryEpoch.get() != epoch) return@launch
                transitionRetrySchedule.markExecuted()
            }
            requestSmartPauseEvaluation("transition_retry")
        }
    }

    @Synchronized
    private fun invalidateTransitionRetry() {
        retryEpoch.incrementAndGet()
        clearTransitionRetry()
    }

    @Synchronized
    private fun clearTransitionRetry() {
        transitionRetryJob?.cancel()
        transitionRetryJob = null
        transitionRetrySchedule.reset()
    }

    @Synchronized
    private fun resetAllPolicyRetries() {
        retryEpoch.incrementAndGet()
        clearTransitionRetry()
        unknownRetryJob?.cancel()
        unknownRetryJob = null
        unknownRetrySchedule.reset()
    }

    private fun maybeCloseConnectionsForHandover(
        network: PhysicalNetworkSnapshot?, config: SmartPauseConfig, session: SessionSnapshot,
    ) {
        val networkId = network?.takeIf { it.isKnown }?.networkId ?: return
        val previous = lastStableNetworkId
        lastStableNetworkId = networkId
        if (previous == null || previous == networkId || !config.closeConnections ||
            (session.state != SessionState.RUNNING && session.state != SessionState.PAUSED)
        ) return
        Phase4Mark.emit(
            "network_handover_close_connections",
            mapOf("network_generation" to network.generation, "network_type" to network.transport),
        )
        val action = "{\"id\":\"native-network-${network.generation}\",\"method\":\"closeConnections\",\"data\":null}"
        Core.invokeAction(action) { result ->
            Phase4Mark.emit(
                "network_handover_close_connections_complete",
                mapOf("result" to (result != null)),
            )
        }
    }

    private suspend fun transitionSmartPauseLocked(
        current: SessionSnapshot, pause: Boolean, source: String,
    ): Boolean {
        Phase4Mark.emit(
            "smart_pause_transition_requested",
            mapOf("session_state" to current.state, "action" to if (pause) "pause" else "resume", "source" to source),
        )
        val active = delegate
        if (active == null) {
            if (!pause) {
                Phase4Mark.emit(
                    "smart_pause_resume",
                    mapOf(
                        "phase" to "vpn_service_result",
                        "result" to false,
                        "tun_operational" to false,
                        "failure" to "delegate_absent",
                    ),
                )
            }
            Phase4Mark.emit(
                "smart_pause_transition_complete",
                mapOf("result" to false, "session_state" to State.snapshot.state, "source" to source),
            )
            return false
        }
        val serviceResult = active.useService { service ->
            if (pause) {
                service.smartStop() && !service.isOperational()
            } else {
                Phase4Mark.emit("smart_pause_resume", mapOf("phase" to "vpn_service_begin"))
                val resumed = service.smartResume()
                val operational = resumed && service.isOperational()
                Phase4Mark.emit(
                    "smart_pause_resume",
                    mapOf(
                        "phase" to "vpn_service_result",
                        "result" to resumed,
                        "tun_operational" to operational,
                    ),
                )
                operational
            }
        }
        if (!pause && serviceResult.isFailure) {
            Phase4Mark.emit(
                "smart_pause_resume",
                mapOf(
                    "phase" to "vpn_service_result",
                    "result" to false,
                    "tun_operational" to false,
                    "failure" to "service_call_failed",
                ),
            )
        }
        var success = serviceResult.getOrNull() == true
        if (success) {
            val next = if (pause) {
                SessionTransitions.paused(current)
            } else {
                SessionTransitions.running(current)
            }
            if (State.options?.enable == true && !persistCheckpoint(next, next.state)) {
                GlobalState.log("Smart-pause transition rolled back because recovery checkpoint commit failed")
                val rolledBack = active.useService { service ->
                    if (pause) {
                        service.smartResume() && service.isOperational()
                    } else {
                        service.smartStop() && !service.isOperational()
                    }
                }.getOrNull() == true
                if (!rolledBack) {
                    clearRecoveryCheckpoint("smart_pause_checkpoint_rollback_failed")
                }
                success = false
            } else {
                applySession(next)
            }
        }
        Phase4Mark.emit(
            "smart_pause_transition_complete",
            mapOf("result" to success, "session_state" to State.snapshot.state, "source" to source),
        )
        return success
    }

    private suspend fun resumePausedSessionLocked(
        current: SessionSnapshot,
        source: PausedResumeSource,
    ): Boolean {
        Phase4Mark.emit(
            "smart_pause_resume",
            mapOf(
                "phase" to "begin",
                "source" to source.name.lowercase(),
                "session_state" to current.state,
                "session_id" to current.sessionId,
                "attempt" to (transitionRetrySchedule.executedAttempts + 1),
            ),
        )
        val success = transitionSmartPauseLocked(
            current = current,
            pause = false,
            source = source.name.lowercase(),
        )
        if (!success) {
            Phase4Mark.emit(
                "smart_pause_resume",
                mapOf(
                    "phase" to "final",
                    "result" to false,
                    "final_state" to State.snapshot.state,
                    "session_id" to State.snapshot.sessionId,
                ),
            )
            return false
        }
        smartPausePolicy.markManualResume(
            manualResumeTrusted(source, latestPhysicalNetwork, smartPauseConfig),
        )
        Phase4Mark.emit(
            "smart_pause_override_changed",
            mapOf(
                "manual_override" to smartPausePolicy.manualOverride,
                "source" to source.name.lowercase(),
            ),
        )
        Phase4Mark.emit(
            "smart_pause_resume",
            mapOf(
                "phase" to "final",
                "result" to true,
                "tun_operational" to true,
                "final_state" to State.snapshot.state,
                "session_id" to State.snapshot.sessionId,
                "smart_paused" to State.snapshot.smartPaused,
            ),
        )
        return true
    }

    private fun checkpointFor(
        snapshot: SessionSnapshot,
        state: String,
        options: VpnOptions,
        setup: QuickSetupPayload,
        recoveryFailures: Int = 0,
    ) = VpnRecoveryCheckpoint(
        installEpoch = recoveryStore.installEpoch,
        sessionId = snapshot.sessionId,
        startedAt = snapshot.startedAt,
        state = state,
        setup = setup,
        options = options,
        recoveryFailures = recoveryFailures,
        updatedAt = System.currentTimeMillis(),
    )

    private fun persistCheckpoint(
        snapshot: SessionSnapshot,
        state: String,
        options: VpnOptions? = State.options,
        setup: QuickSetupPayload? = activeSetupPayload,
    ): Boolean {
        options ?: return false
        val resolvedSetup = setup ?: loadPersistedQuickSetupPayload(this) ?: return false
        activeSetupPayload = resolvedSetup
        if (!options.enable) {
            recoveryStore.clear()
            return true
        }
        val saved = recoveryStore.save(checkpointFor(snapshot, state, options, resolvedSetup))
        Phase4Mark.emit(
            "vpn_recovery_checkpoint",
            mapOf(
                "operation" to "save",
                "result" to saved,
                "state" to state,
                "session_id" to snapshot.sessionId,
            ),
        )
        if (!saved) return false

        forceNonSticky = false
        startRecoveryWatchdog()
        val restartAnchorArmed = runCatching {
            // VpnService is already alive and foreground by the time a RUNNING
            // checkpoint is committed. Starting it as well as binding it gives
            // Android a foreground, sticky service record that can recreate the
            // process even when a vendor low-memory policy kills the whole UID.
            startService(VpnService::class.intent)
        }.onFailure { error ->
            GlobalState.log("Failed to arm VPN restart anchor: ${error.message}")
        }.isSuccess
        Phase4Mark.emit(
            "vpn_recovery_anchor",
            mapOf("operation" to "arm", "result" to restartAnchorArmed),
        )
        // The checkpoint is already durable. Anchor arming is a best-effort
        // reliability enhancement and must not turn a healthy VPN start into
        // an application-visible failure.
        return true
    }

    private fun startRecoveryWatchdog() {
        VpnRecoveryWatchdog.arm(this)
        if (recoveryWatchdogJob?.isActive == true) return
        recoveryWatchdogJob = launch {
            while (true) {
                delay(VpnRecoveryWatchdog.HEARTBEAT_INTERVAL_MILLIS)
                if (
                    TaskRemovalStopStore.isRequested(this@RemoteService) ||
                    recoveryStore.readValid() == null
                ) {
                    VpnRecoveryWatchdog.cancel(this@RemoteService)
                    break
                }
                VpnRecoveryWatchdog.arm(this@RemoteService)
            }
        }
    }

    private fun stopRecoveryWatchdog() {
        recoveryWatchdogJob?.cancel()
        recoveryWatchdogJob = null
        VpnRecoveryWatchdog.cancel(this)
    }

    private fun invalidateQueuedRecovery() {
        recoveryGeneration += 1L
        activeRecoveryGeneration = 0L
        recoveryJob?.cancel()
        recoveryJob = null
        pendingRecovery = null
    }

    private fun recoveryStillValidLocked(generation: Long): Boolean =
        shouldContinueVpnRecovery(
            generation = generation,
            currentGeneration = recoveryGeneration,
            taskRemovalStopRequested = TaskRemovalStopStore.isRequested(this),
            checkpointValid = recoveryStore.readValid() != null,
            forceNonSticky = forceNonSticky,
        )

    private fun clearRecoveryCheckpoint(reason: String, preventSticky: Boolean = true): Boolean {
        if (preventSticky) forceNonSticky = true
        invalidateQueuedRecovery()
        stopRecoveryWatchdog()
        val cleared = recoveryStore.clear()
        Phase4Mark.emit(
            "vpn_recovery_checkpoint",
            mapOf("operation" to "clear", "result" to cleared, "reason" to reason),
        )
        return cleared
    }

    private fun ensurePhysicalDelegateLocked(options: VpnOptions) {
        val nextIntent = when (options.enable) {
            true -> VpnService::class.intent
            false -> CommonService::class.intent
        }
        if (intent == nextIntent && delegate != null) return
        clearDelegate()
        val generation = delegateGeneration
        delegate = ServiceDelegate(
            nextIntent,
            { message -> handleServiceDisconnected(generation, message) },
        ) { binder ->
            when (binder) {
                is VpnService.LocalBinder -> binder.getService()
                is CommonService.LocalBinder -> binder.getService()
                else -> throw IllegalArgumentException("Invalid binder type")
            }
        }
        intent = nextIntent
        delegate?.bind()
    }

    private suspend fun quickSetupAwait(payload: QuickSetupPayload): ServiceOperationResult =
        suspendCancellableCoroutine { continuation ->
            Core.quickSetup(payload.initParamsJson, payload.setupParamsJson) { message ->
                if (continuation.isActive) {
                    continuation.resume(quickSetupOperationResult(message))
                }
            }
        }

    private suspend fun cleanupRecoveryAttemptLocked(message: String) {
        pendingRecovery = null
        delegate?.useService(timeoutMillis = 3_000L) { service -> service.stop() }
        clearDelegate()
        State.options = null
        State.snapshot = SessionSnapshot.stopped(
            ServiceErrorCode.SERVICE_DISCONNECTED,
            message,
        )
        networkObserveModule.setCoreDnsUpdatesEnabled(false)
    }

    private suspend fun attemptCheckpointRecoveryLocked(
        checkpoint: VpnRecoveryCheckpoint,
        generation: Long,
    ): Boolean {
        if (State.snapshot.state != SessionState.STOPPED) return true
        if (android.net.VpnService.prepare(this) != null) {
            GlobalState.log("VPN recovery skipped because VPN ownership is unavailable")
            return false
        }

        val setupResult = quickSetupAwait(checkpoint.setup)
        if (!setupResult.success) {
            GlobalState.log("VPN recovery quick setup failed: ${setupResult.message}")
            return false
        }

        activeSetupPayload = checkpoint.setup
        State.options = checkpoint.options
        val starting = SessionTransitions.starting(checkpoint.sessionId, checkpoint.startedAt)
        State.snapshot = starting
        networkObserveModule.setCoreDnsUpdatesEnabled(true)
        ensurePhysicalDelegateLocked(checkpoint.options)

        val physicalReady = delegate?.useService(timeoutMillis = 5_000L) { true }
            ?.getOrNull() == true
        if (!physicalReady) {
            cleanupRecoveryAttemptLocked("VPN recovery could not bind the physical service")
            return false
        }

        PhysicalNetworkControlPlane.refresh(
            PhysicalNetworkUpdateReason.PROCESS_RECOVERY,
        )
        pendingRecovery = checkpoint
        activeRecoveryGeneration = generation
        val reconciled = reconcileSmartPauseStateLocked(
            PhysicalNetworkUpdateReason.PROCESS_RECOVERY.name,
        )
        if (reconciled == false) {
            cleanupRecoveryAttemptLocked("VPN recovery state reconciliation failed")
            return false
        }
        // A null result means UNKNOWN is inside its bounded retry window.
        // The checkpoint remains historical context while the single policy
        // reconciler owns the eventual PAUSED or RUNNING commit.
        return true
    }

    private suspend fun recoverFromCheckpoint(initial: VpnRecoveryCheckpoint) {
        val generation = recoveryGeneration
        var failures = initial.recoveryFailures
        var checkpointState = initial.state
        while (failures < VPN_RECOVERY_MAX_FAILURES) {
            val attempt = runLock.withLock {
                if (!recoveryStillValidLocked(generation)) {
                    RecoveryAttemptResult.ABORTED
                } else {
                    val checkpoint = recoveryStore.readValid()
                        ?: return@withLock RecoveryAttemptResult.ABORTED
                    checkpointState = checkpoint.state
                    if (attemptCheckpointRecoveryLocked(checkpoint, generation)) {
                        RecoveryAttemptResult.SUCCEEDED
                    } else {
                        RecoveryAttemptResult.RETRY
                    }
                }
            }
            Phase4Mark.emit(
                "vpn_process_recovery",
                mapOf(
                    "attempt" to (failures + 1),
                    "result" to attempt.name.lowercase(),
                    "checkpoint_state" to checkpointState,
                ),
            )
            when (attempt) {
                RecoveryAttemptResult.SUCCEEDED -> return
                RecoveryAttemptResult.ABORTED -> return
                RecoveryAttemptResult.RETRY -> {
                    failures += 1
                    val latest = recoveryStore.readValid() ?: break
                    val next = latest.withFailureCount(failures, System.currentTimeMillis())
                    if (failures >= VPN_RECOVERY_MAX_FAILURES || !recoveryStore.save(next)) break
                    delay(RETRY_DELAYS[(failures - 1).coerceAtMost(RETRY_DELAYS.lastIndex)])
                }
            }
        }
        runLock.withLock {
            if (!recoveryStillValidLocked(generation)) return@withLock
            clearRecoveryCheckpoint("recovery_exhausted")
            applySession(
                SessionSnapshot.stopped(
                    ServiceErrorCode.SERVICE_DISCONNECTED,
                    "VPN process recovery failed",
                )
            )
        }
    }

    private fun clearDelegate() {
        delegate?.unbind()
        delegate = null
        intent = null
        delegateGeneration += 1L
    }

    private fun applySession(snapshot: SessionSnapshot) {
        networkObserveModule.setCoreDnsUpdatesEnabled(snapshot.state != SessionState.STOPPED)
        if (snapshot.state == SessionState.STOPPED) {
            pendingRecovery = null
            previousDesiredState = null
        }
        if (snapshot.state == SessionState.STOPPED && smartPausePolicy.manualOverride) {
            smartPausePolicy.onSessionStopped()
            Phase4Mark.emit(
                "smart_pause_override_changed",
                mapOf(
                    "manual_override" to false,
                    "source" to "session_stopped",
                ),
            )
        }
        State.snapshot = snapshot
        if (SessionState.keepsRemoteService(snapshot.state)) {
            runCatching { startService(Intent(this, RemoteService::class.java)) }
        } else {
            stopSelf()
        }
    }
    private fun replyOperation(
        callback: IOperationResultInterface,
        result: ServiceOperationResult,
    ) {
        runCatching { callback.onResult(result) }
            .onFailure { GlobalState.log("Operation result callback failed: ${it.message}") }
    }

    private fun handleStopService(result: IOperationResultInterface) {
        resetAllPolicyRetries()
        clearRecoveryCheckpoint("explicit_stop")
        Phase4Mark.emit(
            "vpn_service_dispatch",
            mapOf("action" to "stop", "state" to State.snapshot.state),
        )
        launch {
            runLock.withLock {
                // Recovery may have completed after the binder thread's first
                // clear but before this lifecycle lock was acquired. Clear the
                // intent again at the serialized stop commit point.
                clearRecoveryCheckpoint("explicit_stop_commit")
                val stopResult = stopActiveSessionLocked()
                replyOperation(result, stopResult)
            }
        }
    }

    private suspend fun stopActiveSessionLocked(): ServiceOperationResult {
        val current = State.snapshot
        if (current.state == SessionState.STOPPED) {
            clearDelegate()
            applySession(SessionSnapshot.stopped())
            return ServiceOperationResult.success()
        }
        applySession(SessionTransitions.stopping(current))
        val stopResult = delegate?.useService(timeoutMillis = 10_000L) { service ->
            service.stop()
        }?.getOrNull() ?: ServiceOperationResult.failure(
            ServiceErrorCode.SERVICE_DISCONNECTED,
            "Background service is unavailable during stop",
        )
        val resolution = cleanupResolution(State.snapshot, stopResult)
        if (resolution.clearDelegate) clearDelegate()
        applySession(resolution.snapshot)
        return stopResult
    }

    private fun requestTaskRemovalStop() {
        resetAllPolicyRetries()
        TaskRemovalStopStore.mark(this)
        // These commits are synchronous so a vendor task cleaner cannot race
        // process death against durable user intent.
        clearRecoveryCheckpoint("task_removed")
        Phase4Mark.emit(
            "vpn_task_removed",
            mapOf("phase" to "stop_requested", "state" to State.snapshot.state),
        )
        launch {
            runLock.withLock {
                clearRecoveryCheckpoint("task_removed_commit")
                val result = stopActiveSessionLocked()
                Phase4Mark.emit(
                    "vpn_task_removed",
                    mapOf("phase" to "stop_complete", "success" to result.success),
                )
            }
        }
    }

    private fun handleServiceDisconnected(generation: Long, message: String) {
        Phase4Mark.emit(
            "vpn_remote_disconnected",
            mapOf("service" to "background", "state" to State.snapshot.state, "message" to message),
        )
        GlobalState.log("Background service disconnected: $message")
        launch {
            runLock.withLock {
                // A disconnect from a service discarded during handover must
                // not overwrite the replacement session that is now RUNNING.
                if (!isCurrentDelegateGeneration(generation, delegateGeneration)) return@withLock
                clearRecoveryCheckpoint("physical_service_disconnected")
                clearDelegate()
                // The bound physical service is gone and this delegate does
                // not reconnect automatically. STOPPING would therefore be a
                // permanent phantom state with no actor left to complete it.
                applySession(disconnectedSessionSnapshot(message))
            }
        }
    }

    private fun handleStartService(
        options: VpnOptions,
        runTime: Long,
        result: IOperationResultInterface,
    ) {
        if (TaskRemovalStopStore.isRequested(this)) {
            replyOperation(
                result,
                ServiceOperationResult.failure(
                    ServiceErrorCode.INTERNAL_ERROR,
                    "VPN start is suppressed after the app task was removed",
                ),
            )
            return
        }
        resetAllPolicyRetries()
        Phase4Mark.emit(
            "vpn_service_dispatch",
            mapOf("action" to "start", "state" to State.snapshot.state, "run_time" to runTime),
        )
        launch {
            runLock.withLock {
                var current = State.snapshot
                if (current.state == SessionState.RUNNING) {
                    val operational = delegate?.useService { service ->
                        service.isOperational()
                    }?.getOrNull() == true
                    if (canReuseRunningSession(current.state, operational)) {
                        State.options = options
                        if (options.enable && !persistCheckpoint(current, SessionState.RUNNING, options)) {
                            replyOperation(
                                result,
                                ServiceOperationResult.failure(
                                    ServiceErrorCode.INTERNAL_ERROR,
                                    "VPN recovery checkpoint update failed",
                                ),
                            )
                            return@withLock
                        }
                        applySession(current)
                        replyOperation(result, ServiceOperationResult.success(current.startedAt))
                        return@withLock
                    }

                    // A different VPN app can revoke our TUN while the remote
                    // process and its RUNNING snapshot remain alive. Discard
                    // that stale session so this explicit Start establishes a
                    // new interface and reclaims Android VPN ownership.
                    GlobalState.log("Discard stale RUNNING session without an operational service")
                    delegate?.useService(timeoutMillis = 10_000L) { service ->
                        service.stop()
                    }
                    clearDelegate()
                    applySession(SessionSnapshot.stopped())
                    current = State.snapshot
                }
                if (current.state == SessionState.PAUSED) {
                    State.options = options
                    val resumed = resumePausedSessionLocked(current, PausedResumeSource.USER)
                    if (resumed) {
                        replyOperation(result, ServiceOperationResult.success(current.startedAt))
                    } else {
                        replyOperation(
                            result,
                            ServiceOperationResult.failure(
                                ServiceErrorCode.TUN_START_FAILED,
                                "Paused session failed to resume",
                            ),
                        )
                    }
                    return@withLock
                }
                if (current.state != SessionState.STOPPED) {
                    replyOperation(
                        result,
                        ServiceOperationResult.failure(
                            ServiceErrorCode.INTERNAL_ERROR,
                            "Session is busy: ${current.state}",
                        ),
                    )
                    return@withLock
                }
                clearRecoveryCheckpoint("explicit_start_reset")
                val sessionId = sessionCounter.incrementAndGet()
                val startedAt = runTime.takeIf { it > 0L } ?: System.currentTimeMillis()
                State.options = options
                applySession(SessionTransitions.starting(sessionId, startedAt))
                try {
                    ensurePhysicalDelegateLocked(options)

                    var startResult: ServiceOperationResult? = null
                    delegate?.useService { service ->
                        startResult = service.start()
                    }

                    val serviceResult = startResult ?: ServiceOperationResult.failure(
                        ServiceErrorCode.SERVICE_DISCONNECTED,
                        "Background service is unavailable",
                    )
                    if (!serviceResult.success) {
                        GlobalState.log("Start service failed: ${serviceResult.errorCode} ${serviceResult.message}")
                        rollbackStart(serviceResult.errorCode, serviceResult.message)
                        replyOperation(result, serviceResult)
                        return@withLock
                    }

                    val running = SessionTransitions.running(State.snapshot)
                    if (options.enable && !persistCheckpoint(running, SessionState.RUNNING, options)) {
                        rollbackStart(
                            ServiceErrorCode.INTERNAL_ERROR,
                            "VPN recovery checkpoint commit failed",
                        )
                        replyOperation(
                            result,
                            ServiceOperationResult.failure(
                                ServiceErrorCode.INTERNAL_ERROR,
                                "VPN recovery checkpoint commit failed",
                            ),
                        )
                        return@withLock
                    }
                    applySession(running)
                    requestSmartPauseEvaluation("session_started")
                    replyOperation(result, ServiceOperationResult.success(startedAt))
                } catch (e: Exception) {
                    GlobalState.log("Start service internal error: ${e.message}")
                    rollbackStart(ServiceErrorCode.INTERNAL_ERROR, e.message)
                    replyOperation(
                        result,
                        ServiceOperationResult.failure(
                            ServiceErrorCode.INTERNAL_ERROR,
                            e.message,
                        ),
                    )
                }
            }
        }
    }

    private suspend fun rollbackStart(errorCode: String?, message: String?) {
        val activeDelegate = delegate
        val cleanupResult = if (activeDelegate == null) {
            ServiceOperationResult.success()
        } else {
            activeDelegate.useService(timeoutMillis = 10_000L) { service ->
                service.stop()
            }.getOrElse {
                ServiceOperationResult.failure(ServiceErrorCode.SERVICE_DISCONNECTED, it.message)
            }
        }
        val resolution = cleanupResolution(
            current = State.snapshot,
            result = if (cleanupResult.success) {
                ServiceOperationResult.success()
            } else {
                ServiceOperationResult.failure(
                    errorCode ?: cleanupResult.errorCode ?: ServiceErrorCode.INTERNAL_ERROR,
                    message ?: cleanupResult.message,
                )
            },
        )
        if (resolution.clearDelegate) clearDelegate()
        applySession(
            if (resolution.clearDelegate && (errorCode != null || message != null)) {
                SessionSnapshot.stopped(errorCode, message)
            } else {
                resolution.snapshot
            },
        )
    }

    private val binder = object : IRemoteInterface.Stub() {
        override fun invokeAction(data: String, callback: ICallbackInterface) {
            Core.invokeAction(data) {
                launch {
                    runCatching {
                        val chunks = it?.chunkedForAidl().orEmpty()
                        if (chunks.isEmpty()) {
                            callback.onResult(null, true, null)
                            return@runCatching
                        }
                        for ((index, chunk) in chunks.withIndex()) {
                            suspendCancellableCoroutine { cont ->
                                callback.onResult(
                                    chunk,
                                    index == chunks.lastIndex,
                                    object : IAckInterface.Stub() {
                                        override fun onAck() {
                                            cont.resume(Unit)
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }

        override fun quickSetup(
            initParamsString: String,
            setupParamsString: String,
            result: IOperationResultInterface,
        ) {
            Core.quickSetup(initParamsString, setupParamsString) {
                launch {
                    runLock.withLock {
                        val operationResult = quickSetupOperationResult(it)
                        if (!operationResult.success) {
                            applySession(
                                SessionSnapshot.stopped(
                                operationResult.errorCode,
                                operationResult.message,
                                )
                            )
                        } else {
                            activeSetupPayload = QuickSetupPayload(
                                initParamsJson = initParamsString,
                                setupParamsJson = setupParamsString,
                            )
                        }
                        replyOperation(result, operationResult)
                    }
                }
            }
        }

        override fun updateNotificationParams(params: NotificationParams?) {
            State.notificationParamsFlow.tryEmit(params)
        }


        override fun startService(
            options: VpnOptions,
            runtime: Long,
            result: IOperationResultInterface,
        ) {
            GlobalState.log("remote startService")
            handleStartService(options, runtime, result)
        }

        override fun stopService(result: IOperationResultInterface) {
            handleStopService(result)
        }

        override fun clearTaskRemovalStop() {
            TaskRemovalStopStore.clear(this@RemoteService)
        }

        override fun setEventListener(eventListener: IEventInterface?) {
            GlobalState.log("RemoveEventListener ${eventListener == null}")
            when (eventListener != null) {
                true -> Core.callSetEventListener {
                    launch {
                        runCatching {
                            val id = UUID.randomUUID().toString()
                            val chunks = it?.chunkedForAidl() ?: listOf()
                            for ((index, chunk) in chunks.withIndex()) {
                                suspendCancellableCoroutine { cont ->
                                    eventListener.onEvent(
                                        id,
                                        chunk,
                                        index == chunks.lastIndex,
                                        object : IAckInterface.Stub() {
                                            override fun onAck() {
                                                cont.resume(Unit)
                                            }
                                        },
                                    )
                                }
                            }
                        }
                    }
                }

                false -> Core.callSetEventListener(null)
            }
        }

        override fun getRunTime(): Long {
            return State.snapshot.takeIf { it.state == SessionState.RUNNING }?.startedAt ?: 0L
        }

        override fun getSessionSnapshot(): SessionSnapshot {
            Phase4Mark.emit(
                "vpn_snapshot",
                mapOf(
                    "layer" to "remote_binder",
                    "state" to State.snapshot.state,
                    "session_id" to State.snapshot.sessionId,
                    "smart_paused" to State.snapshot.smartPaused,
                ),
            )
            return State.snapshot
        }

        override fun smartStop(result: IResultInterface) {
            resetAllPolicyRetries()
            Phase4Mark.emit(
                "smart_stop_begin",
                mapOf("state" to State.snapshot.state, "session_id" to State.snapshot.sessionId),
            )
            launch {
                runLock.withLock {
                    // Already stopped — return success (idempotent)
                    val current = State.snapshot
                    if (current.state == SessionState.PAUSED) {
                        Phase4Mark.emit(
                            "smart_stop_complete",
                            mapOf("result_class" to "idempotent", "state" to current.state),
                        )
                        result.onResult(1)
                        return@withLock
                    }
                    if (current.state != SessionState.RUNNING) {
                        Phase4Mark.emit(
                            "smart_stop_complete",
                            mapOf("result_class" to "rejected", "state" to current.state),
                        )
                        result.onResult(0)
                        return@withLock
                    }
                    val success = transitionSmartPauseLocked(current, true, "manual")
                    if (success) {
                        Phase4Mark.emit(
                            "smart_stop_complete",
                            mapOf("result_class" to "success", "state" to State.snapshot.state),
                        )
                        result.onResult(1)
                    } else {
                        Phase4Mark.emit(
                            "smart_stop_complete",
                            mapOf("result_class" to "service_unavailable", "state" to current.state),
                        )
                        result.onResult(0)
                    }
                }
            }
        }

        override fun smartResume(result: IResultInterface) {
            resetAllPolicyRetries()
            Phase4Mark.emit(
                "smart_resume_begin",
                mapOf("state" to State.snapshot.state, "session_id" to State.snapshot.sessionId),
            )
            launch {
                runLock.withLock {
                    // Only a physically operational RUNNING session is
                    // idempotent. A stale snapshot must not confirm resume.
                    val current = State.snapshot
                    if (current.state != SessionState.PAUSED) {
                        val operational = if (current.state == SessionState.RUNNING) {
                            delegate?.useService { it.isOperational() }?.getOrNull() == true
                        } else {
                            false
                        }
                        if (current.state == SessionState.RUNNING && !operational) {
                            delegate?.useService(timeoutMillis = 10_000L) { it.stop() }
                            clearDelegate()
                            applySession(
                                SessionSnapshot.stopped(
                                    ServiceErrorCode.SERVICE_DISCONNECTED,
                                    "RUNNING session is not operational",
                                )
                            )
                        }
                        Phase4Mark.emit(
                            "smart_resume_complete",
                            mapOf(
                                "result_class" to if (operational) "idempotent" else "rejected",
                                "state" to State.snapshot.state,
                            ),
                        )
                        result.onResult(current.takeIf { operational }?.startedAt ?: 0L)
                        return@withLock
                    }
                    val options = State.options
                    if (options == null || delegate == null) {
                        result.onResult(0)
                        return@withLock
                    }
                    val success = resumePausedSessionLocked(current, PausedResumeSource.USER)
                    if (success) {
                        Phase4Mark.emit(
                            "smart_resume_complete",
                            mapOf("result_class" to "success", "state" to State.snapshot.state),
                        )
                        result.onResult(current.startedAt)
                    } else {
                        Phase4Mark.emit(
                            "smart_resume_complete",
                            mapOf("result_class" to "tun_start_failed", "state" to current.state),
                        )
                        result.onResult(0)
                    }
                }
            }
        }

        override fun setSmartStopped(value: Boolean) {
            if (State.snapshot.smartPaused != value) {
                GlobalState.log("Ignoring stale smart-pause flag; physical service state is authoritative")
            }
        }

        override fun isSmartStopped(): Boolean {
            return State.snapshot.smartPaused
        }

        override fun updateSmartPauseConfig(
            enabled: Boolean,
            trustedNetworks: MutableList<String>?,
            closeConnections: Boolean,
        ) {
            resetAllPolicyRetries()
            val networks = trustedNetworks.orEmpty().map(String::trim).filter(String::isNotEmpty)
            smartPauseConfig = SmartPauseConfig(enabled, networks, closeConnections)
            getSharedPreferences(SMART_PAUSE_PREFERENCES, Context.MODE_PRIVATE).edit()
                .putBoolean(KEY_ENABLED, enabled)
                .putStringSet(KEY_NETWORKS, networks.toSet())
                .putBoolean(KEY_CLOSE_CONNECTIONS, closeConnections)
                .apply()
            requestSmartPauseEvaluation(PhysicalNetworkUpdateReason.CONFIG_CHANGE.name)
            launch {
                PhysicalNetworkControlPlane.refresh(
                    PhysicalNetworkUpdateReason.CONFIG_CHANGE,
                )
                requestSmartPauseEvaluation(PhysicalNetworkUpdateReason.CONFIG_CHANGE.name)
            }
        }

        override fun reevaluateSmartPause(result: IResultInterface) {
            launch {
                PhysicalNetworkControlPlane.refresh(
                    PhysicalNetworkUpdateReason.APP_FOREGROUND,
                )
                val generation = requestSmartPauseEvaluation(
                    PhysicalNetworkUpdateReason.APP_FOREGROUND.name,
                )
                policyExecutor.await(generation)
                result.onResult(1L)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (
            intent?.action == ACTION_STOP_AFTER_TASK_REMOVED ||
            TaskRemovalStopStore.isRequested(this)
        ) {
            requestTaskRemovalStop()
            return START_NOT_STICKY
        }
        if (!shouldKeepVpnServiceSticky(forceNonSticky, checkpointValid = true)) {
            return START_NOT_STICKY
        }
        val checkpoint = recoveryStore.readValid()
        val recoveryOrSystemRestart =
            intent == null || intent.action == ACTION_RECOVER_FROM_VPN_SERVICE
        if (shouldStopOrphanStartedService(
                checkpointValid = checkpoint != null,
                taskRemovalStopRequested = false,
                recoveryOrSystemRestart = recoveryOrSystemRestart,
                sessionKeepsService = SessionState.keepsRemoteService(State.snapshot.state),
            )
        ) {
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (checkpoint == null) {
            return START_NOT_STICKY
        }
        if (shouldStartStickyRecovery(
                recoveryRequested = intent == null ||
                    intent.action == ACTION_RECOVER_FROM_VPN_SERVICE,
                checkpointValid = true,
                recoveryAlreadyActive = recoveryJob?.isActive == true,
            )
        ) {
            Phase4Mark.emit(
                "vpn_process_recovery",
                mapOf(
                    "phase" to "scheduled",
                    "checkpoint_state" to checkpoint.state,
                    "prior_failures" to checkpoint.recoveryFailures,
                ),
            )
            recoveryJob = launch { recoverFromCheckpoint(checkpoint) }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        requestTaskRemovalStop()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        PhysicalNetworkControlPlane.detach()
        resetAllPolicyRetries()
        policyExecutor.close()
        runBlocking {
            withTimeoutOrNull(2_000L) {
                networkObserverJob?.cancelAndJoin()
                networkObserverJob = null
                runCatching { networkObserveModule.uninstall() }
            }
        }
        if (SessionState.keepsRemoteService(State.snapshot.state)) {
            GlobalState.log(
                "RemoteService onDestroy with active session ${State.snapshot.state}; keeping VPN"
            )
            serviceJob.cancel()
            super.onDestroy()
            return
        }
        runBlocking {
            withTimeoutOrNull(2_000L) {
                runLock.withLock {
                    val activeDelegate = delegate
                    val stopped = if (activeDelegate == null) {
                        true
                    } else {
                        activeDelegate.useService(timeoutMillis = 1_500L) { service ->
                            service.stop()
                        }.getOrNull()?.success == true
                    }
                    clearDelegate()
                    applySession(
                        if (stopped) {
                            SessionSnapshot.stopped()
                        } else {
                            State.snapshot.copy(
                                state = SessionState.STOPPING,
                                lastErrorCode = ServiceErrorCode.SERVICE_DISCONNECTED,
                                lastErrorMessage = "Remote service destroyed before cleanup completed",
                            )
                        }
                    )
                }
            }
        }
        Core.callSetEventListener(null)
        serviceJob.cancel()
        GlobalState.log("Remote service destroy")
        super.onDestroy()
    }

    companion object {
        internal const val ACTION_RECOVER_FROM_VPN_SERVICE =
            "com.follow.clash.service.action.RECOVER_VPN"
        internal const val ACTION_STOP_AFTER_TASK_REMOVED =
            "com.follow.clash.service.action.STOP_AFTER_TASK_REMOVED"
        private const val SMART_PAUSE_PREFERENCES = "smart_pause_control"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_NETWORKS = "trusted_networks"
        private const val KEY_CLOSE_CONNECTIONS = "close_connections"
        private val RETRY_DELAYS = longArrayOf(500L, 1_500L, 3_000L)
    }
}

private enum class RecoveryAttemptResult {
    SUCCEEDED,
    RETRY,
    ABORTED,
}
