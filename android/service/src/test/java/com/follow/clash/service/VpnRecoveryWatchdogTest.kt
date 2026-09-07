package com.follow.clash.service

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VpnRecoveryWatchdogTest {
    @Test
    fun uiProcessOnlyDispatchesWhenCheckpointHintIsValid() {
        assertTrue(shouldDispatchVpnProcessRecovery(checkpointHintValid = true))
        assertFalse(shouldDispatchVpnProcessRecovery(checkpointHintValid = false))
    }

    @Test
    fun staleRecoveryStartStopsOnlyWhenNoLiveSessionRemains() {
        assertTrue(
            shouldStopOrphanStartedService(
                checkpointValid = false,
                taskRemovalStopRequested = false,
                recoveryOrSystemRestart = true,
                sessionKeepsService = false,
            )
        )
        assertFalse(
            shouldStopOrphanStartedService(
                checkpointValid = false,
                taskRemovalStopRequested = false,
                recoveryOrSystemRestart = true,
                sessionKeepsService = true,
            )
        )
        assertFalse(
            shouldStopOrphanStartedService(
                checkpointValid = false,
                taskRemovalStopRequested = false,
                recoveryOrSystemRestart = false,
                sessionKeepsService = false,
            )
        )
        assertTrue(
            shouldStopOrphanStartedService(
                checkpointValid = true,
                taskRemovalStopRequested = true,
                recoveryOrSystemRestart = true,
                sessionKeepsService = true,
            )
        )
    }

    @Test
    fun stopInvalidatesInFlightRecoveryByGeneration() {
        assertTrue(
            shouldContinueVpnRecovery(
                generation = 4L,
                currentGeneration = 4L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = false,
            )
        )
        assertFalse(
            shouldContinueVpnRecovery(
                generation = 4L,
                currentGeneration = 5L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = false,
            )
        )
        assertFalse(
            shouldContinueVpnRecovery(
                generation = 4L,
                currentGeneration = 4L,
                taskRemovalStopRequested = true,
                checkpointValid = true,
                forceNonSticky = false,
            )
        )
        assertFalse(
            shouldContinueVpnRecovery(
                generation = 4L,
                currentGeneration = 4L,
                taskRemovalStopRequested = false,
                checkpointValid = false,
                forceNonSticky = false,
            )
        )
        assertFalse(
            shouldContinueVpnRecovery(
                generation = 4L,
                currentGeneration = 4L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = true,
            )
        )
    }

    @Test
    fun recoveryFailureWritebackRequiresSameGenerationAndRoomToRetry() {
        assertTrue(
            shouldPersistRecoveryFailure(
                generation = 2L,
                currentGeneration = 2L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = false,
                nextFailures = 1,
            )
        )
        assertFalse(
            shouldPersistRecoveryFailure(
                generation = 2L,
                currentGeneration = 3L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = false,
                nextFailures = 1,
            )
        )
        assertFalse(
            shouldPersistRecoveryFailure(
                generation = 2L,
                currentGeneration = 2L,
                taskRemovalStopRequested = false,
                checkpointValid = false,
                forceNonSticky = false,
                nextFailures = 1,
            )
        )
        assertFalse(
            shouldPersistRecoveryFailure(
                generation = 2L,
                currentGeneration = 2L,
                taskRemovalStopRequested = false,
                checkpointValid = true,
                forceNonSticky = false,
                nextFailures = VPN_RECOVERY_MAX_FAILURES,
            )
        )
    }

    @Test
    fun watchdogRearmAfterTriggerIsBoundedAndRequiresALiveCheckpoint() {
        assertTrue(
            shouldRearmWatchdogAfterTrigger(
                checkpointValid = true,
                taskRemovalStopRequested = false,
                rearmsUsed = 0,
            )
        )
        assertTrue(
            shouldRearmWatchdogAfterTrigger(
                checkpointValid = true,
                taskRemovalStopRequested = false,
                rearmsUsed = VpnRecoveryWatchdog.TRIGGER_REARM_LIMIT - 1,
            )
        )
        assertFalse(
            shouldRearmWatchdogAfterTrigger(
                checkpointValid = true,
                taskRemovalStopRequested = false,
                rearmsUsed = VpnRecoveryWatchdog.TRIGGER_REARM_LIMIT,
            )
        )
        assertFalse(
            shouldRearmWatchdogAfterTrigger(
                checkpointValid = false,
                taskRemovalStopRequested = false,
                rearmsUsed = 0,
            )
        )
        assertFalse(
            shouldRearmWatchdogAfterTrigger(
                checkpointValid = true,
                taskRemovalStopRequested = true,
                rearmsUsed = 0,
            )
        )
    }

    @Test
    fun watchdogUsesOneMonotonicDeadlineShorterThanAMinute() {
        assertTrue(VpnRecoveryWatchdog.RECOVERY_DEADLINE_MILLIS <= 15_000L)
        assertTrue(
            VpnRecoveryWatchdog.HEARTBEAT_INTERVAL_MILLIS <
                VpnRecoveryWatchdog.RECOVERY_DEADLINE_MILLIS,
        )
        assertEquals(
            15_000L,
            nextWatchdogTriggerAt(0L, VpnRecoveryWatchdog.RECOVERY_DEADLINE_MILLIS),
        )
    }
}
