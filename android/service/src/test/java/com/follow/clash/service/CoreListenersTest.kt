package com.follow.clash.service

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CoreListenersTest {
    @Test
    fun cancellationCannotReleaseLifecycleMutexBeforeGoAcknowledges() = runBlocking {
        val gate = Mutex()
        val callback = CompletableDeferred<(String?) -> Unit>()
        val first = launch(start = CoroutineStart.UNDISPATCHED) {
            gate.withLock {
                coreLifecycleAction("stopListener") { _, complete -> callback.complete(complete) }
            }
        }
        val complete = callback.await()
        first.cancel()
        var nextStarted = false
        val next = launch(start = CoroutineStart.UNDISPATCHED) {
            gate.withLock { nextStarted = true }
        }
        assertFalse(nextStarted)
        complete("""{"code":0,"data":true}""")
        first.join()
        next.join()
        assertTrue(nextStarted)
    }

    @Test
    fun onlyConfirmedBooleanSuccessAcknowledgesMutation() = runBlocking {
        suspend fun result(raw: String?) = coreLifecycleAction("startListener") { action, complete ->
            assertTrue(action.contains("startListener"))
            complete(raw)
        }
        assertTrue(result("""{"code":0,"data":true}"""))
        assertFalse(result("""{"code":0,"data":false}"""))
        assertFalse(result("""{"code":-1,"data":true}"""))
        assertFalse(result(null))
        assertFalse(result("invalid"))
    }
}
