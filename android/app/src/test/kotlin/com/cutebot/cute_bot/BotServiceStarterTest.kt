// JVM unit test for the watchdog / presence "should be running" decision
// (M2.5 done bar). Run with: cd android && ./gradlew :app:testDebugUnitTest

package com.cutebot.cute_bot

import com.pravera.flutter_foreground_task.models.ForegroundServiceAction
import org.junit.Assert.assertEquals
import org.junit.Test

class BotServiceStarterTest {

    @Test
    fun `never started on this install - not wanted`() {
        assertEquals(
            StartDecision.NOT_WANTED,
            BotServiceStarter.decide(lastAction = null, isRunning = false))
    }

    @Test
    fun `explicitly stopped by user - not wanted even if somehow running`() {
        assertEquals(
            StartDecision.NOT_WANTED,
            BotServiceStarter.decide(ForegroundServiceAction.API_STOP, isRunning = false))
        assertEquals(
            StartDecision.NOT_WANTED,
            BotServiceStarter.decide(ForegroundServiceAction.API_STOP, isRunning = true))
    }

    @Test
    fun `started and alive - leave it alone`() {
        assertEquals(
            StartDecision.ALREADY_RUNNING,
            BotServiceStarter.decide(ForegroundServiceAction.API_START, isRunning = true))
    }

    @Test
    fun `started but dead - restart`() {
        assertEquals(
            StartDecision.START,
            BotServiceStarter.decide(ForegroundServiceAction.API_START, isRunning = false))
    }

    @Test
    fun `previous restart or reboot actions still count as wanted`() {
        for (action in listOf(
            ForegroundServiceAction.RESTART,
            ForegroundServiceAction.REBOOT,
            ForegroundServiceAction.API_RESTART,
            ForegroundServiceAction.API_UPDATE,
        )) {
            assertEquals(
                "action=$action",
                StartDecision.START,
                BotServiceStarter.decide(action, isRunning = false))
        }
    }
}
