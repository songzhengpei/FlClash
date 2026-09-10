package com.follow.clash

import com.follow.clash.common.GlobalState
import com.follow.clash.common.ServiceDelegate
import com.follow.clash.common.formatString
import com.follow.clash.common.intent
import com.follow.clash.service.IAckInterface
import com.follow.clash.service.ICallbackInterface
import com.follow.clash.service.IEventInterface
import com.follow.clash.service.IOperationResultInterface
import com.follow.clash.service.IRemoteInterface
import com.follow.clash.service.IResultInterface
import com.follow.clash.service.RemoteService
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.ServiceErrorCode
import com.follow.clash.service.models.ServiceOperationResult
import com.follow.clash.service.models.SessionSnapshot
import com.follow.clash.service.models.VpnOptions
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun completedCorePayload(chunks: List<ByteArray>): String? =
    chunks.formatString().ifEmpty { null }

object Service {
    private val delegate by lazy {
        ServiceDelegate<IRemoteInterface>(
            RemoteService::class.intent, ::handleServiceDisconnected
        ) {
            IRemoteInterface.Stub.asInterface(it)
        }
    }

    var onServiceDisconnected: ((String) -> Unit)? = null

    private fun handleServiceDisconnected(message: String) {
        onServiceDisconnected?.let {
            it(message)
        }
    }

    fun bind() {
        delegate.bind()
    }

    fun isBound(): Boolean = delegate.serviceState.value?.first != null

    fun unbind() {
        delegate.unbind()
    }

    suspend fun invokeAction(data: String, cb: ((result: String?) -> Unit)?): Result<Unit> {
        val res = mutableListOf<ByteArray>()
        return delegate.useService {
            it.invokeAction(
                data, object : ICallbackInterface.Stub() {
                    override fun onResult(
                        result: ByteArray?, isSuccess: Boolean, ack: IAckInterface?
                    ) {
                        res.add(result ?: byteArrayOf())
                        ack?.onAck()
                        if (isSuccess) {
                            cb?.let { cb ->
                                cb(completedCorePayload(res))
                            }
                        }
                    }
                })
        }
    }

    suspend fun quickSetup(
        initParamsString: String,
        setupParamsString: String,
    ): ServiceOperationResult {
        return delegate.useService {
            awaitOperationResult { callback ->
                it.quickSetup(initParamsString, setupParamsString, callback)
            }
        }.getOrElse {
            ServiceOperationResult.failure(ServiceErrorCode.SERVICE_DISCONNECTED, it.message)
        }
    }

    suspend fun setEventListener(
        cb: ((result: String?) -> Unit)?
    ): Result<Unit> {
        val results = HashMap<String, MutableList<ByteArray>>()
        return delegate.useService {
            it.setEventListener(
                when (cb != null) {
                    true -> object : IEventInterface.Stub() {
                        override fun onEvent(
                            id: String, data: ByteArray?, isSuccess: Boolean, ack: IAckInterface?
                        ) {
                            if (results[id] == null) {
                                results[id] = mutableListOf()
                            }
                            results[id]?.add(data ?: byteArrayOf())
                            ack?.onAck()
                            if (isSuccess) {
                                cb(results[id]?.formatString())
                                results.remove(id)
                            }
                        }
                    }

                    false -> null
                })
        }
    }

    suspend fun updateNotificationParams(
        params: NotificationParams
    ): Result<Unit> {
        return delegate.useService {
            it.updateNotificationParams(params)
        }
    }

    private suspend fun awaitIResultInterface(
        block: (IResultInterface) -> Unit
    ): Long = suspendCancellableCoroutine { continuation ->
        val callback = object : IResultInterface.Stub() {
            override fun onResult(time: Long) {
                if (continuation.isActive) {
                    continuation.resume(time)
                }
            }
        }

        try {
            block(callback)
        } catch (e: Exception) {
            GlobalState.log("awaitIResultInterface $e")
            if (continuation.isActive) {
                continuation.resumeWithException(e)
            }
        }
    }

    private suspend fun awaitOperationResult(
        block: (IOperationResultInterface) -> Unit
    ): ServiceOperationResult = suspendCancellableCoroutine { continuation ->
        val callback = object : IOperationResultInterface.Stub() {
            override fun onResult(result: ServiceOperationResult?) {
                if (continuation.isActive) {
                    continuation.resume(
                        result ?: ServiceOperationResult.failure(
                            ServiceErrorCode.INTERNAL_ERROR,
                            "Empty service result",
                        )
                    )
                }
            }
        }
        try {
            block(callback)
        } catch (e: Exception) {
            if (continuation.isActive) continuation.resumeWithException(e)
        }
    }

    suspend fun startService(options: VpnOptions, runTime: Long): ServiceOperationResult {
        return delegate.useService {
            awaitOperationResult { callback ->
                it.startService(options, runTime, callback)
            }
        }.getOrElse {
            ServiceOperationResult.failure(ServiceErrorCode.SERVICE_DISCONNECTED, it.message)
        }
    }
    suspend fun stopService(): ServiceOperationResult {
        return delegate.useService(timeoutMillis = 12_000L) {
            awaitOperationResult { callback ->
                it.stopService(callback)
            }
        }.getOrElse {
            ServiceOperationResult.failure(ServiceErrorCode.SERVICE_DISCONNECTED, it.message)
        }
    }
    suspend fun reconfigureSettings(options: VpnOptions, sessionId: Long): ServiceOperationResult {
        return delegate.useService(timeoutMillis = 30_000L) {
            awaitOperationResult { callback ->
                it.reconfigureSettings(options, sessionId, callback)
            }
        }.getOrElse {
            ServiceOperationResult.failure(ServiceErrorCode.SERVICE_DISCONNECTED, it.message)
        }
    }
    suspend fun clearTaskRemovalStop(): Boolean {
        return delegate.useService {
            it.clearTaskRemovalStop()
            true
        }.getOrDefault(false)
    }
    suspend fun getRunTime(): Long {
        return delegate.useService {
            it.runTime
        }.getOrNull() ?: 0L
    }

    suspend fun getSessionSnapshot(): Result<SessionSnapshot> {
        val first = delegate.useService { it.sessionSnapshot }
        if (first.isSuccess) return first
        delegate.bind()
        return delegate.useService(timeoutMillis = 8_000L) { it.sessionSnapshot }
    }

    suspend fun smartStop(): Long {
        return delegate.useService {
            awaitIResultInterface { callback ->
                it.smartStop(callback)
            }
        }.getOrNull() ?: 0L
    }

    suspend fun smartResume(): Long {
        return delegate.useService {
            awaitIResultInterface { callback ->
                it.smartResume(callback)
            }
        }.getOrNull() ?: 0L
    }

    suspend fun setSmartStopped(value: Boolean) {
        delegate.useService {
            it.isSmartStopped = value
        }
    }

    suspend fun isSmartStopped(): Boolean {
        return delegate.useService {
            it.isSmartStopped
        }.getOrNull() ?: false
    }

    suspend fun updateSmartPauseConfig(
        enabled: Boolean,
        trustedNetworks: List<String>,
        closeConnections: Boolean,
    ): Boolean = delegate.useService {
        it.updateSmartPauseConfig(enabled, trustedNetworks, closeConnections)
        true
    }.getOrDefault(false)

    suspend fun reevaluateSmartPause(): Boolean = delegate.useService {
        awaitIResultInterface { callback -> it.reevaluateSmartPause(callback) } > 0L
    }.getOrDefault(false)
}
