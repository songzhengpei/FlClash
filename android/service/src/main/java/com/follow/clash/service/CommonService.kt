package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import com.follow.clash.service.modules.NotificationModule
import com.follow.clash.service.modules.SuspendModule
import com.follow.clash.service.modules.moduleLoader
import com.follow.clash.service.models.ServiceErrorCode
import com.follow.clash.service.models.ServiceOperationResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class CommonService : Service(), IBaseService, CoroutineScope {

    private val serviceJob = SupervisorJob()
    override val coroutineContext = serviceJob + Dispatchers.Default
    private val lifecycleMutex = Mutex()
    private var shutdownComplete = false
    @Volatile
    private var operational = false

    private val self: CommonService
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
            GlobalState.log("CommonService foreground start failed: ${it.message}")
            ServiceOperationResult.failure(ServiceErrorCode.FOREGROUND_SERVICE_FAILED, it.message)
        }
        handleCreate()
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

    override fun onLowMemory() {
        Core.forceGC()
        super.onLowMemory()
    }

    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): CommonService = this@CommonService
    }

    override fun onBind(intent: Intent): IBinder {
        return binder
    }

    override suspend fun start(): ServiceOperationResult = lifecycleMutex.withLock {
        startupFailure?.let { return it }
        shutdownComplete = false
        return try {
            loader.load()
            check(setCoreListeners(true)) { "Core listeners did not start" }
            operational = true
            ServiceOperationResult.success()
        } catch (e: Exception) {
            GlobalState.log("CommonService start failed: ${e.message}")
            cleanupLocked(stopService = true)
            ServiceOperationResult.failure(ServiceErrorCode.INTERNAL_ERROR, e.message)
        }
    }

    override suspend fun stop(): ServiceOperationResult = shutdown("user_stop")

    override fun isOperational(): Boolean = operational && !shutdownComplete

    private suspend fun shutdown(
        reason: String,
        stopService: Boolean = true,
    ): ServiceOperationResult = withContext(NonCancellable) {
        lifecycleMutex.withLock {
            if (shutdownComplete) return@withLock ServiceOperationResult.success()
            GlobalState.log("CommonService shutdown: $reason")
            cleanupLocked(stopService)
            ServiceOperationResult.success()
        }
    }

    private suspend fun cleanupLocked(stopService: Boolean, stopListeners: Boolean = true) {
        operational = false
        // onDestroy has a main-thread deadline. The remote disconnect handler
        // cleans listeners under the session lock after checking delegate identity.
        if (stopListeners) check(setCoreListeners(false)) { "Core listeners did not stop" }
        loader.unload()
        shutdownComplete = true
        if (stopService) stopSelf()
    }
}
