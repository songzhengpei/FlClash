package com.follow.clash.service

import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.os.RemoteException
import android.os.UserManager
import android.util.Log
import androidx.core.content.getSystemService
import com.follow.clash.common.AccessControlMode
import com.follow.clash.common.GlobalState
import com.follow.clash.common.Phase4Mark
import com.follow.clash.common.TaskRemovalStopStore
import com.follow.clash.core.Core
import com.follow.clash.service.models.ServiceErrorCode
import com.follow.clash.service.models.ServiceOperationResult
import com.follow.clash.service.models.SessionSnapshot
import com.follow.clash.service.models.SessionState
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.getIpv4RouteAddress
import com.follow.clash.service.models.getIpv6RouteAddress
import com.follow.clash.service.models.toCIDR
import com.follow.clash.service.models.shouldAttachVpnHttpProxy
import com.follow.clash.service.models.tunDnsHijackServers
import com.follow.clash.service.modules.NotificationModule
import com.follow.clash.service.modules.SuspendModule
import com.follow.clash.service.modules.moduleLoader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.LinkedHashMap
import java.net.InetSocketAddress
import android.net.VpnService as SystemVpnService

internal fun shouldStopRevokedSession(
    revokedSessionId: Long,
    current: SessionSnapshot,
): Boolean =
    revokedSessionId != 0L &&
        current.sessionId == revokedSessionId &&
        current.state != SessionState.STOPPED

class VpnService : SystemVpnService(), IBaseService, CoroutineScope {

    private val serviceJob = SupervisorJob()
    override val coroutineContext = serviceJob + Dispatchers.Default
    private val lifecycleMutex = Mutex()
    private var shutdownComplete = false
    @Volatile
    private var tunEstablished = false

    private val self: VpnService
        get() = this

    private val loader = moduleLoader {
        install(NotificationModule(self))
        install(SuspendModule(self))
    }

    private var startupFailure: ServiceOperationResult? = null

    override fun onCreate() {
        super.onCreate()
        startupFailure = runCatching {
            NotificationModule.showLoadingNotification(this)
            null
        }.getOrElse {
            GlobalState.log("VpnService foreground start failed: ${it.message}")
            ServiceOperationResult.failure(ServiceErrorCode.FOREGROUND_SERVICE_FAILED, it.message)
        }
        handleCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskRemovalStopRequested = TaskRemovalStopStore.isRequested(this)
        if (taskRemovalStopRequested) {
            VpnRecoveryStore(this).clear()
        }
        val checkpoint = if (taskRemovalStopRequested) {
            null
        } else {
            VpnRecoveryStore(this).readValid()
        }
        val recoveryOrSystemRestart =
            intent == null || intent.action == VpnRecoveryWatchdog.ACTION_RECOVER
        if (shouldStopOrphanStartedService(
                checkpointValid = checkpoint != null,
                taskRemovalStopRequested = taskRemovalStopRequested,
                recoveryOrSystemRestart = recoveryOrSystemRestart,
                sessionKeepsService = tunEstablished ||
                    SessionState.keepsRemoteService(State.snapshot.state),
            )
        ) {
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        if (checkpoint == null) {
            // A bound VpnService can be promoted to a started service only after
            // the session checkpoint commits. Do not retain a failed or
            // explicitly stopped session merely because onStartCommand ran.
            return START_NOT_STICKY
        }

        if (intent == null || intent.action == VpnRecoveryWatchdog.ACTION_RECOVER) {
            val recoveryRequested = runCatching {
                startService(
                    Intent(this, RemoteService::class.java).setAction(
                        RemoteService.ACTION_RECOVER_FROM_VPN_SERVICE,
                    )
                )
            }.onFailure { error ->
                GlobalState.log("VpnService failed to request process recovery: ${error.message}")
            }.isSuccess
            Phase4Mark.emit(
                "vpn_recovery_anchor",
                mapOf("operation" to "restore", "result" to recoveryRequested),
            )
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        TaskRemovalStopStore.mark(this)
        VpnRecoveryStore(this).clear()
        runCatching {
            startService(
                Intent(this, RemoteService::class.java).setAction(
                    RemoteService.ACTION_STOP_AFTER_TASK_REMOVED,
                )
            )
        }
        GlobalState.launch { shutdown("task_removed") }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        runBlocking {
            withTimeoutOrNull(2_000L) {
                lifecycleMutex.withLock {
                    if (!shutdownComplete) cleanupLocked(stopService = false, stopListeners = false)
                }
            }
        }
        serviceJob.cancel()
        handleDestroy()
        super.onDestroy()
    }

    override fun onRevoke() {
        // Android has already deactivated our interface. Publish that fact
        // synchronously so a later explicit Start cannot reuse a stale
        // RUNNING session while shutdown is still being dispatched.
        tunEstablished = false
        val revokedSessionId = State.snapshot.sessionId
        VpnRecoveryStore(this).clear()
        GlobalState.launch {
            var stoppedRevokedSession = false
            State.runLock.withLock {
                if (shouldStopRevokedSession(revokedSessionId, State.snapshot)) {
                    shutdown("vpn_revoked")
                    State.snapshot = SessionSnapshot.stopped(
                        ServiceErrorCode.VPN_REVOKED,
                        "VPN ownership was revoked by Android",
                    )
                    stoppedRevokedSession = true
                }
            }
            if (stoppedRevokedSession) {
                stopService(Intent(this@VpnService, RemoteService::class.java))
            }
        }
        super.onRevoke()
    }

    private val connectivity by lazy {
        getSystemService<ConnectivityManager>()
    }

    private fun hasAssociatedUserProfiles(): Boolean =
        runCatching {
            val currentUser = Process.myUserHandle()
            getSystemService<UserManager>()
                ?.userProfiles
                ?.any { it != currentUser }
                ?: true
        }.onFailure { error ->
            GlobalState.log("Detect associated user profiles failed: ${error.message}")
        }.getOrDefault(true)

    private val uidPageNameMap = object : LinkedHashMap<Int, String>(128, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, String>?): Boolean {
            return size > 256
        }
    }

    private fun clearResolverCache() {
        synchronized(uidPageNameMap) {
            uidPageNameMap.clear()
        }
    }

    private fun getPackageNameForUid(uid: Int): String {
        synchronized(uidPageNameMap) {
            uidPageNameMap[uid]?.let { return it }
            val packageName = this.packageManager?.getPackagesForUid(uid)?.first() ?: ""
            uidPageNameMap[uid] = packageName
            return packageName
        }
    }

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String {
        val nextUid = if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            source.address != null &&
            target.address != null
        ) {
            runCatching {
                connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
            }.getOrElse {
                GlobalState.log("Resolve process fallback: ${it.message}")
                uid
            }
        } else {
            uid
        }
        if (nextUid == -1) {
            return ""
        }
        return getPackageNameForUid(nextUid)
    }

    val VpnOptions.address
        get(): String = buildString {
            append(IPV4_ADDRESS)
            if (ipv6) {
                append(",")
                append(IPV6_ADDRESS)
            }
        }

    val VpnOptions.dns
        get(): String = tunDnsHijackServers(ipv6)


    override fun onLowMemory() {
        Core.forceGC()
        super.onLowMemory()
    }

    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): VpnService = this@VpnService

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            try {
                val isSuccess = super.onTransact(code, data, reply, flags)
                if (!isSuccess) {
                    GlobalState.log("VpnService disconnected")
                    handleDestroy()
                }
                return isSuccess
            } catch (e: RemoteException) {
                GlobalState.log("VpnService onTransact $e")
                return false
            }
        }
    }

    override fun onBind(intent: Intent): IBinder {
        return binder
    }

    private fun handleStart(options: VpnOptions) {
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "handle_start_begin", "tun_present" to tunEstablished),
        )
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "establish_begin", "tun_present" to false),
        )
        val fd = with(Builder()) {
            val cidr = IPV4_ADDRESS.toCIDR()
            addAddress(cidr.address, cidr.prefixLength)
            Log.d(
                "addAddress", "address: ${cidr.address} prefixLength:${cidr.prefixLength}"
            )
            val routeAddress = options.getIpv4RouteAddress()
            if (routeAddress.isNotEmpty()) {
                try {
                    routeAddress.forEach { i ->
                        Log.d(
                            "addRoute4", "address: ${i.address} prefixLength:${i.prefixLength}"
                        )
                        addRoute(i.address, i.prefixLength)
                    }
                } catch (_: Exception) {
                    addRoute(NET_ANY, 0)
                }
            } else {
                addRoute(NET_ANY, 0)
            }
            if (options.ipv6) {
                try {
                    val cidr = IPV6_ADDRESS.toCIDR()
                    Log.d(
                        "addAddress6", "address: ${cidr.address} prefixLength:${cidr.prefixLength}"
                    )
                    addAddress(cidr.address, cidr.prefixLength)
                } catch (_: Exception) {
                    Log.d(
                        "addAddress6", "IPv6 is not supported."
                    )
                }

                try {
                    val routeAddress = options.getIpv6RouteAddress()
                    if (routeAddress.isNotEmpty()) {
                        try {
                            routeAddress.forEach { i ->
                                Log.d(
                                    "addRoute6",
                                    "address: ${i.address} prefixLength:${i.prefixLength}"
                                )
                                addRoute(i.address, i.prefixLength)
                            }
                        } catch (_: Exception) {
                            addRoute("::", 0)
                        }
                    } else {
                        addRoute(NET_ANY6, 0)
                    }
                } catch (_: Exception) {
                    addRoute(NET_ANY6, 0)
                }
            }
            addDnsServer(DNS)
            if (options.ipv6) {
                addDnsServer(DNS6)
            }
            setMtu(9000)
            options.accessControlProps.let { accessControl ->
                if (accessControl.enable) {
                    when (accessControl.mode) {
                        AccessControlMode.ACCEPT_SELECTED -> {
                            (accessControl.acceptList + packageName).forEach {
                                runCatching { addAllowedApplication(it) }
                                    .onFailure { error ->
                                        GlobalState.log("Ignore invalid allowed package $it: ${error.message}")
                                    }
                            }
                        }

                        AccessControlMode.REJECT_SELECTED -> {
                            (accessControl.rejectList - packageName).forEach {
                                runCatching { addDisallowedApplication(it) }
                                    .onFailure { error ->
                                        GlobalState.log("Ignore invalid disallowed package $it: ${error.message}")
                                    }
                            }
                        }
                    }
                }
            }
            setSession("FlClash")
            setBlocking(false)
            if (Build.VERSION.SDK_INT >= 29) {
                setMetered(false)
            }
            if (options.allowBypass) {
                allowBypass()
            }
            val hasAssociatedProfiles =
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    options.systemProxy &&
                    hasAssociatedUserProfiles()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                shouldAttachVpnHttpProxy(options.systemProxy, hasAssociatedProfiles)
            ) {
                GlobalState.log("Open http proxy")
                setHttpProxy(
                    ProxyInfo.buildDirectProxy(
                        "127.0.0.1", options.port, options.bypassDomain
                    )
                )
            } else if (options.systemProxy) {
                GlobalState.log(
                    if (hasAssociatedProfiles) {
                        "Skip localhost HTTP proxy for associated user profiles; use TUN capture"
                    } else {
                        "Skip HTTP proxy because this Android version does not support it"
                    },
                )
            }
            Phase4Mark.emit("vpn_tun_observed", mapOf("phase" to "builder_establish_begin"))
            establish()?.detachFd()
                ?: throw NullPointerException("Establish VPN rejected by system")
        }
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "establish_complete", "fd_valid" to (fd >= 0)),
        )
        GlobalState.log("TUN dns hijack ${options.dns}")
        val started = Core.startTun(
            fd,
            protect = this::protect,
            resolverProcess = this::resolverProcess,
            options.stack,
            options.address,
            options.dns
        )
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "core_start_result", "tun_present" to started),
        )
        if (!started) {
            Core.stopTun()
            throw ServiceStartException(
                ServiceErrorCode.TUN_START_FAILED,
                "Native TUN listener failed to start",
            )
        }
        tunEstablished = true
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "tun_operational", "tun_present" to true),
        )
    }

    override suspend fun start(): ServiceOperationResult = lifecycleMutex.withLock {
        startupFailure?.let { return it }
        shutdownComplete = false
        return try {
            loader.load()
            val options = State.options
                ?: throw IllegalStateException("VPN options is null")
            check(setCoreListeners(true)) { "Core listeners did not start" }
            handleStart(options)
            ServiceOperationResult.success()
        } catch (e: ServiceStartException) {
            GlobalState.log("VpnService start failed: ${e.message}")
            cleanupLocked(stopService = true)
            ServiceOperationResult.failure(e.errorCode, e.message)
        } catch (e: Exception) {
            GlobalState.log("VpnService start failed: ${e.message}")
            cleanupLocked(stopService = true)
            ServiceOperationResult.failure(
                if (e is NullPointerException && e.message == "Establish VPN rejected by system") {
                    ServiceErrorCode.VPN_ESTABLISH_FAILED
                } else {
                    ServiceErrorCode.INTERNAL_ERROR
                },
                e.message,
            )
        }
    }

    override suspend fun stop(): ServiceOperationResult = shutdown("user_stop")

    override fun isOperational(): Boolean = tunEstablished && !shutdownComplete

    override suspend fun smartStop(): Boolean = lifecycleMutex.withLock {
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "smart_stop_begin", "shutdown_complete" to shutdownComplete),
        )
        if (shutdownComplete) return@withLock false
        if (!tunEstablished && State.snapshot.state == SessionState.STARTING) {
            // Checkpoint recovery may establish a PAUSED session without ever
            // creating TUN. Keep notification/suspend modules alive while
            // confirming that the runtime is already physically paused.
            loader.load()
            return@withLock setCoreListeners(false)
        }
        if (!tunEstablished) return@withLock false
        if (!setCoreListeners(false)) return@withLock false
        clearResolverCache()
        Core.stopTun()
        tunEstablished = false
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "smart_stop_complete", "tun_present" to false),
        )
        true
    }

    override suspend fun smartResume(): Boolean = lifecycleMutex.withLock {
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "smart_resume_begin", "shutdown_complete" to shutdownComplete),
        )
        if (shutdownComplete) return@withLock false
        return@withLock try {
            State.options?.let {
                // A checkpoint can restore PAUSED without ever calling start().
                // Load the runtime modules before recreating TUN in that path.
                loader.load()
                check(setCoreListeners(true)) { "Core listeners did not resume" }
                handleStart(it)
                Phase4Mark.emit(
                    "vpn_tun_observed",
                    mapOf("phase" to "smart_resume_complete", "tun_present" to true),
                )
                true
            } ?: false
        } catch (e: Exception) {
            Core.stopTun()
            tunEstablished = false
            setCoreListeners(false)
            GlobalState.log("VpnService smartResume failed: ${e.message}")
            Phase4Mark.emit(
                "vpn_tun_observed",
                mapOf(
                    "phase" to "smart_resume_failed",
                    "tun_present" to false,
                    "error" to e.javaClass.simpleName,
                ),
            )
            false
        }
    }

    private suspend fun shutdown(
        reason: String,
        stopService: Boolean = true,
    ): ServiceOperationResult = withContext(NonCancellable) {
        lifecycleMutex.withLock {
            if (shutdownComplete) return@withLock ServiceOperationResult.success()
            GlobalState.log("VpnService shutdown: $reason")
            cleanupLocked(stopService)
            ServiceOperationResult.success()
        }
    }

    private suspend fun cleanupLocked(stopService: Boolean, stopListeners: Boolean = true) {
        Phase4Mark.emit("vpn_tun_observed", mapOf("phase" to "stop_begin"))
        tunEstablished = false
        Core.stopTun()
        Phase4Mark.emit(
            "vpn_tun_observed",
            mapOf("phase" to "stop_complete", "tun_present" to false),
        )
        // onDestroy has a main-thread deadline. The remote disconnect handler
        // cleans listeners under the session lock after checking delegate identity.
        if (stopListeners) check(setCoreListeners(false)) { "Core listeners did not stop" }
        loader.unload()
        clearResolverCache()
        shutdownComplete = true
        if (stopService) stopSelf()
    }

    companion object {
        private const val IPV4_ADDRESS = "172.19.0.1/30"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1/126"
        private const val DNS = "172.19.0.2"
        private const val DNS6 = "fdfe:dcba:9876::2"
        private const val NET_ANY = "0.0.0.0"
        private const val NET_ANY6 = "::"
    }
}

private class ServiceStartException(
    val errorCode: String,
    message: String,
) : Exception(message)
