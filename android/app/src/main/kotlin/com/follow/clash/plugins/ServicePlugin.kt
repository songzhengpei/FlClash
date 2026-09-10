package com.follow.clash.plugins

import com.follow.clash.Service
import com.follow.clash.State
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.common.RunTimeProbe
import com.follow.clash.common.Phase4Mark
import com.follow.clash.invokeMethodOnMainThread
import com.follow.clash.models.SharedState
import com.follow.clash.common.SessionPresence
import com.follow.clash.service.models.SessionSnapshot
import com.follow.clash.service.models.SessionState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean

internal suspend fun forwardCoreInvocation(
    invoke: suspend (((String?) -> Unit)) -> Result<Unit>,
    complete: (String?) -> Unit,
) {
    val completed = AtomicBoolean(false)
    val completeOnce: (String?) -> Unit = { value ->
        if (completed.compareAndSet(false, true)) complete(value)
    }
    runCatching { invoke(completeOnce) }.fold(
        onSuccess = { it.onFailure { completeOnce(null) } },
        onFailure = { completeOnce(null) },
    )
}

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    private lateinit var flutterMethodChannel: MethodChannel

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            Components.SERVICE_CHANNEL
        )
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
        "init" -> {
            handleInit(result)
        }

        "shutdown" -> {
            handleShutdown(result)
        }

        "invokeAction" -> {
            handleInvokeAction(call, result)
        }

        "getRunTime" -> {
            handleGetRunTime(result)
        }

        "getSessionSnapshot" -> {
            handleGetSessionSnapshot(result)
        }

        "syncState" -> {
            handleSyncState(call, result)
        }

        "start" -> {
            handleStart(result)
        }
        "reconfigureSettings" -> {
            val options = Gson().fromJson(call.argument<String>("options"),
                com.follow.clash.service.models.VpnOptions::class.java)
            val sessionId = call.argument<Number>("sessionId")!!.toLong()
            launch {
                val outcome = Service.reconfigureSettings(options, sessionId)
                State.handleSyncState()
                result.success(if (outcome.success) "" else
                    outcome.message ?: "VPN settings application failed")
            }
            Unit
        }

        "clearTaskRemovalStop" -> {
            handleClearTaskRemovalStop(result)
        }

        "stop" -> {
            handleStop(result)
        }

        "getLocalIpAddresses" -> {
            handleGetLocalIpAddresses(result)
        }

        "smartStop" -> {
            handleSmartStop(result)
        }

        "smartResume" -> {
            handleSmartResume(result)
        }

        "setSmartStopped" -> {
            handleSetSmartStopped(call, result)
        }

        "isSmartStopped" -> {
            handleIsSmartStopped(result)
        }
        "updateSmartPauseConfig" -> handleUpdateSmartPauseConfig(call, result)
        "reevaluateSmartPause" -> handleReevaluateSmartPause(result)

        else -> {
            result.notImplemented()
        }
    }

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val data = call.arguments<String>()!!
            forwardCoreInvocation(
                invoke = { callback -> Service.invokeAction(data, callback) },
                complete = result::success,
            )
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        Service.unbind()
        result.success(true)
    }

    private fun handleStart(result: MethodChannel.Result) {
        Phase4Mark.emit("vpn_action_requested", mapOf("action" to "start", "source" to "flutter_ui"))
        launch {
            val success = State.handleStartService()
            result.success(success)
        }
    }

    private fun handleClearTaskRemovalStop(result: MethodChannel.Result) {
        launch {
            Service.bind()
            result.success(Service.clearTaskRemovalStop())
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        Phase4Mark.emit("vpn_action_requested", mapOf("action" to "stop", "source" to "flutter_ui"))
        launch {
            result.success(State.stopServiceAndAwait())
        }
    }

    val semaphore = Semaphore(10)

    fun handleSendEvent(value: String?) {
        launch(Dispatchers.Main) {
            semaphore.withPermit {
                flutterMethodChannel.invokeMethod("event", value)
            }
        }
    }

    private fun onServiceDisconnected(message: String) {
        launch { State.handleSyncState() }
        flutterMethodChannel.invokeMethodOnMainThread<Any>("crash", message)
    }

    private fun handleSyncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>()!!
        State.sharedState = Gson().fromJson(data, SharedState::class.java)
        launch {
            State.syncState()
            result.success("")
        }
    }


    fun handleInit(result: MethodChannel.Result) {
        Service.bind()
        launch {
            Service.setEventListener {
                handleSendEvent(it)
            }.onSuccess {
                result.success("")
            }.onFailure {
                result.success(it.message)
            }

        }
        Service.onServiceDisconnected = ::onServiceDisconnected
    }

    private fun handleGetRunTime(result: MethodChannel.Result) {
        launch {
            val app = GlobalState.application
            val presence = SessionPresence.readValid(
                app,
                "${app.packageName}:remote",
            )
            if (presence != null) {
                State.sessionSnapshot = SessionSnapshot(
                    sessionId = presence.sessionId,
                    state = presence.state,
                    startedAt = presence.startedAt,
                    smartPaused = presence.smartPaused,
                )
                State.runTime =
                    if (presence.state == SessionState.RUNNING) presence.startedAt else 0L
            }
            val remoteAlive =
                presence != null || RunTimeProbe.isRemoteProcessAlive(app)
            val shouldBind =
                RunTimeProbe.shouldBindForRunTime(
                    remoteProcessAlive = remoteAlive,
                    alreadyBound = Service.isBound(),
                    cachedRunTime = State.runTime,
                )
            if (shouldBind) {
                State.handleSyncState()
            }
            result.success(State.runTime)
        }
    }

    private fun handleGetSessionSnapshot(result: MethodChannel.Result) {
        val snapshot = State.sessionSnapshot
        result.success(
            mapOf(
                "sessionId" to snapshot.sessionId,
                "state" to snapshot.state,
                "startedAt" to snapshot.startedAt,
                "smartPaused" to snapshot.smartPaused,
            )
        )
    }

    private fun handleGetLocalIpAddresses(result: MethodChannel.Result) {
        launch {
            val addresses = mutableListOf<String>()
            try {
                val interfaces = java.util.Collections.list(
                    NetworkInterface.getNetworkInterfaces()
                )
                for (intf in interfaces) {
                    if (intf.isLoopback || !intf.isUp) continue
                    val name = intf.name.lowercase()
                    if (name.startsWith("tun") || name.startsWith("utun") ||
                        name.startsWith("ppp") || name.startsWith("vpn") ||
                        name.startsWith("lo")) continue
                    for (addr in intf.inetAddresses) {
                        if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                            addresses.add(addr.hostAddress ?: "")
                        }
                    }
                }
            } catch (_: Exception) {}
            result.success(addresses)
        }
    }

    private fun handleSmartStop(result: MethodChannel.Result) {
        launch {
            val res = Service.smartStop()
            State.handleSyncState()
            result.success(res != 0L)
        }
    }

    private fun handleSmartResume(result: MethodChannel.Result) {
        launch {
            val res = Service.smartResume()
            State.handleSyncState()
            result.success(res > 0L)
        }
    }

    private fun handleSetSmartStopped(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val value = call.arguments<Boolean>() ?: false
            Service.setSmartStopped(value)
            State.handleSyncState()
            result.success(true)
        }
    }

    private fun handleIsSmartStopped(result: MethodChannel.Result) {
        launch {
            val value = Service.isSmartStopped()
            result.success(value)
        }
    }

    private fun handleUpdateSmartPauseConfig(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val args = call.arguments<Map<String, Any?>>() ?: emptyMap()
            val enabled = args["enabled"] as? Boolean ?: false
            val networks = (args["trustedNetworks"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
            val closeConnections = args["closeConnections"] as? Boolean ?: true
            result.success(Service.updateSmartPauseConfig(enabled, networks, closeConnections))
        }
    }

    private fun handleReevaluateSmartPause(result: MethodChannel.Result) {
        launch { result.success(Service.reevaluateSmartPause()) }
    }
}
