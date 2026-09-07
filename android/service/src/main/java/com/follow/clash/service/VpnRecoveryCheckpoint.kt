package com.follow.clash.service

import android.content.Context
import android.os.Build
import com.follow.clash.common.AccessControlMode
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.service.models.SessionState
import com.follow.clash.service.models.VpnOptions
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser

internal const val VPN_RECOVERY_SCHEMA_VERSION = 1
internal const val VPN_RECOVERY_MAX_FAILURES = 3

internal data class QuickSetupPayload(
    val initParamsJson: String,
    val setupParamsJson: String,
)

internal data class VpnRecoveryCheckpoint(
    val schemaVersion: Int = VPN_RECOVERY_SCHEMA_VERSION,
    val installEpoch: Long,
    val sessionId: Long,
    val startedAt: Long,
    val state: String,
    val setup: QuickSetupPayload,
    val options: VpnOptions,
    val recoveryFailures: Int = 0,
    val updatedAt: Long,
) {
    fun withState(nextState: String, now: Long) = copy(
        state = nextState,
        recoveryFailures = 0,
        updatedAt = now,
    )

    fun withFailureCount(count: Int, now: Long) = copy(
        recoveryFailures = count,
        updatedAt = now,
    )
}

internal fun shouldKeepVpnServiceSticky(
    forceNonSticky: Boolean,
    checkpointValid: Boolean,
): Boolean = !forceNonSticky && checkpointValid

internal fun shouldStartStickyRecovery(
    recoveryRequested: Boolean,
    checkpointValid: Boolean,
    recoveryAlreadyActive: Boolean,
): Boolean = recoveryRequested && checkpointValid && !recoveryAlreadyActive

internal fun isCheckpointCompatible(
    checkpoint: VpnRecoveryCheckpoint,
    installEpoch: Long,
): Boolean = checkpoint.installEpoch == installEpoch &&
    checkpoint.recoveryFailures < VPN_RECOVERY_MAX_FAILURES

internal fun quickSetupPayloadFromSharedState(
    rawSharedState: String,
    homeDir: String,
    sdkInt: Int,
): QuickSetupPayload? = runCatching {
    val sharedState = JsonParser.parseString(rawSharedState).asJsonObject
    val setupParams = sharedState.get("setupParams")
        ?.takeUnless { it.isJsonNull }
        ?.asJsonObject
        ?: return null
    val initParams = JsonObject().apply {
        addProperty("home-dir", homeDir)
        addProperty("version", sdkInt)
    }
    QuickSetupPayload(
        initParamsJson = initParams.toString(),
        setupParamsJson = setupParams.toString(),
    )
}.getOrNull()

internal fun loadPersistedQuickSetupPayload(context: Context): QuickSetupPayload? {
    val raw = context.getSharedPreferences(
        "FlutterSharedPreferences",
        Context.MODE_PRIVATE,
    ).getString("flutter.sharedState", null) ?: return null
    return quickSetupPayloadFromSharedState(
        rawSharedState = raw,
        homeDir = context.filesDir.path,
        sdkInt = Build.VERSION.SDK_INT,
    )
}

internal object VpnRecoveryCheckpointCodec {
    fun encode(checkpoint: VpnRecoveryCheckpoint): String = JsonObject().apply {
        addProperty("schemaVersion", checkpoint.schemaVersion)
        addProperty("installEpoch", checkpoint.installEpoch)
        addProperty("sessionId", checkpoint.sessionId)
        addProperty("startedAt", checkpoint.startedAt)
        addProperty("state", checkpoint.state)
        addProperty("initParamsJson", checkpoint.setup.initParamsJson)
        addProperty("setupParamsJson", checkpoint.setup.setupParamsJson)
        addProperty("recoveryFailures", checkpoint.recoveryFailures)
        addProperty("updatedAt", checkpoint.updatedAt)
        add("options", encodeOptions(checkpoint.options))
    }.toString()

    fun decode(raw: String): VpnRecoveryCheckpoint? = runCatching {
        val root = JsonParser.parseString(raw).asJsonObject
        val options = decodeOptions(root.getAsJsonObject("options"))
        VpnRecoveryCheckpoint(
            schemaVersion = root.requiredInt("schemaVersion"),
            installEpoch = root.requiredLong("installEpoch"),
            sessionId = root.requiredLong("sessionId"),
            startedAt = root.requiredLong("startedAt"),
            state = root.requiredString("state"),
            setup = QuickSetupPayload(
                initParamsJson = root.requiredString("initParamsJson"),
                setupParamsJson = root.requiredString("setupParamsJson"),
            ),
            options = options,
            recoveryFailures = root.requiredInt("recoveryFailures"),
            updatedAt = root.requiredLong("updatedAt"),
        )
    }.getOrNull()?.takeIf(::isStructurallyValid)

    private fun isStructurallyValid(checkpoint: VpnRecoveryCheckpoint): Boolean =
        checkpoint.schemaVersion == VPN_RECOVERY_SCHEMA_VERSION &&
            checkpoint.sessionId > 0L &&
            checkpoint.startedAt > 0L &&
            checkpoint.state in setOf(SessionState.RUNNING, SessionState.PAUSED) &&
            checkpoint.setup.initParamsJson.isNotBlank() &&
            checkpoint.setup.setupParamsJson.isNotBlank() &&
            checkpoint.options.enable &&
            checkpoint.recoveryFailures in 0..VPN_RECOVERY_MAX_FAILURES

    private fun encodeOptions(options: VpnOptions) = JsonObject().apply {
        addProperty("enable", options.enable)
        addProperty("port", options.port)
        addProperty("ipv6", options.ipv6)
        addProperty("dnsHijacking", options.dnsHijacking)
        addProperty("allowBypass", options.allowBypass)
        addProperty("systemProxy", options.systemProxy)
        addProperty("stack", options.stack)
        add("bypassDomain", options.bypassDomain.toJsonArray())
        add("routeAddress", options.routeAddress.toJsonArray())
        add("accessControl", JsonObject().apply {
            addProperty("enable", options.accessControlProps.enable)
            addProperty(
                "mode",
                when (options.accessControlProps.mode) {
                    AccessControlMode.ACCEPT_SELECTED -> "acceptSelected"
                    AccessControlMode.REJECT_SELECTED -> "rejectSelected"
                },
            )
            add("acceptList", options.accessControlProps.acceptList.toJsonArray())
            add("rejectList", options.accessControlProps.rejectList.toJsonArray())
        })
    }

    private fun decodeOptions(root: JsonObject): VpnOptions {
        val access = root.getAsJsonObject("accessControl")
        val mode = when (access.requiredString("mode")) {
            "acceptSelected" -> AccessControlMode.ACCEPT_SELECTED
            "rejectSelected" -> AccessControlMode.REJECT_SELECTED
            else -> error("Unknown access-control mode")
        }
        return VpnOptions(
            enable = root.requiredBoolean("enable"),
            port = root.requiredInt("port"),
            ipv6 = root.requiredBoolean("ipv6"),
            dnsHijacking = root.requiredBoolean("dnsHijacking"),
            accessControlProps = AccessControlProps(
                enable = access.requiredBoolean("enable"),
                mode = mode,
                acceptList = access.requiredStringList("acceptList"),
                rejectList = access.requiredStringList("rejectList"),
            ),
            allowBypass = root.requiredBoolean("allowBypass"),
            systemProxy = root.requiredBoolean("systemProxy"),
            bypassDomain = root.requiredStringList("bypassDomain"),
            stack = root.requiredString("stack"),
            routeAddress = root.requiredStringList("routeAddress"),
        )
    }

    private fun List<String>.toJsonArray() = JsonArray().also { array ->
        forEach(array::add)
    }

    private fun JsonObject.requiredString(name: String): String = get(name).asString
    private fun JsonObject.requiredBoolean(name: String): Boolean = get(name).asBoolean
    private fun JsonObject.requiredInt(name: String): Int = get(name).asInt
    private fun JsonObject.requiredLong(name: String): Long = get(name).asLong
    private fun JsonObject.requiredStringList(name: String): List<String> =
        getAsJsonArray(name).map { it.asString }
}

internal class VpnRecoveryStore(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    val installEpoch: Long
        get() = runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)

    fun peekValid(): VpnRecoveryCheckpoint? {
        val raw = preferences.getString(KEY_CHECKPOINT, null) ?: return null
        val checkpoint = VpnRecoveryCheckpointCodec.decode(raw) ?: return null
        if (!isCheckpointCompatible(checkpoint, installEpoch)) return null
        return checkpoint
    }

    fun readValid(): VpnRecoveryCheckpoint? {
        val checkpoint = peekValid()
        if (checkpoint == null && preferences.contains(KEY_CHECKPOINT)) {
            clear()
        }
        return checkpoint
    }

    fun save(checkpoint: VpnRecoveryCheckpoint): Boolean =
        preferences.edit()
            .putString(KEY_CHECKPOINT, VpnRecoveryCheckpointCodec.encode(checkpoint))
            .commit()

    fun clear(): Boolean = preferences.edit().remove(KEY_CHECKPOINT).commit()

    companion object {
        private const val PREFERENCES_NAME = "vpn_recovery_checkpoint"
        private const val KEY_CHECKPOINT = "checkpoint"
    }
}
