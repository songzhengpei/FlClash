package com.follow.clash.service

import com.follow.clash.core.Core
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

// The caller holds the session or physical lifecycle mutex. A cancelled caller
// must not release that mutex while its Go command can still mutate the core.
internal suspend fun setCoreListeners(running: Boolean): Boolean =
    coreLifecycleAction(if (running) "startListener" else "stopListener")

internal suspend fun coreLifecycleAction(
    method: String,
    invoke: (String, (String?) -> Unit) -> Unit = { data, callback ->
        Core.invokeAction(data, callback)
    },
): Boolean = withContext(NonCancellable) {
    suspendCoroutine { continuation ->
        val action = JsonObject().apply {
            addProperty("id", "native-$method")
            addProperty("method", method)
            add("data", com.google.gson.JsonNull.INSTANCE)
        }.toString()
        invoke(action) { result ->
            val success = runCatching {
                val value = JsonParser.parseString(result).asJsonObject
                value.get("code").asInt == 0 && value.get("data").asBoolean
            }.getOrDefault(false)
            continuation.resume(success)
        }
    }
}
