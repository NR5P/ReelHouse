package com.reelhouse.android.push

import com.reelhouse.android.data.PushDeliveryReport
import com.reelhouse.android.data.PushStatus
import com.reelhouse.android.data.parsePushDeliveryReport
import com.reelhouse.android.data.parsePushStatus
import com.reelhouse.android.data.pushStatusSummary
import com.reelhouse.android.data.pushTestSummary
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The push contract: /api/push/status and /api/push/test bodies, the FCM data keys a tapped
// notification carries, and the channel ids the server addresses.
class PushLogicTest {

    @Test
    fun `status parses every contract field`() {
        val status = parsePushStatus(
            JSONObject(
                """{ "enabled": true, "appleConfigured": false, "androidConfigured": true, "myDevices": 2,
                    "newEpisodes": true, "downloads": false, "loginAlerts": true }""",
            ),
        )
        assertEquals(PushStatus(true, false, true, 2, newEpisodes = true, downloads = false, loginAlerts = true), status)
    }

    @Test
    fun `test report parses`() {
        val report = parsePushDeliveryReport(JSONObject("""{ "attempted": 3, "delivered": 2, "failed": 1, "removed": 1 }"""))
        assertEquals(PushDeliveryReport(3, 2, 1, 1), report)
        assertEquals("Sent to 2 of 3 devices.", pushTestSummary(report))
    }

    @Test
    fun `summary explains why push is off`() {
        val on = PushStatus(true, false, true, 1, newEpisodes = true, downloads = true, loginAlerts = false)
        assertEquals("Push isn't set up in this build.", pushStatusSummary(false, on, false))
        assertTrue(pushStatusSummary(true, on.copy(enabled = false), false).startsWith("Off on the server"))
        assertTrue(pushStatusSummary(true, on.copy(androidConfigured = false), false).contains("reach Android"))
        assertEquals(
            "On: new podcast episodes, finished downloads. 1 device of yours is registered.",
            pushStatusSummary(true, on, false),
        )
    }

    @Test
    fun `each type lands on its channel`() {
        assertEquals("new_episodes", PushChannels.forType("podcast"))
        assertEquals("downloads", PushChannels.forType("download"))
        assertEquals("account", PushChannels.forType("login"))
        assertEquals("general", PushChannels.forType("test"))
        assertEquals("general", PushChannels.forType(null))
    }

    @Test
    fun `a tapped notification opens what it names`() {
        fun open(vararg extras: Pair<String, String>) = PushOpen.from(mapOf(*extras)::get)

        assertEquals(
            PushDestination.Episode("e1", "p1"),
            open("type" to "podcast", "itemId" to "e1", "podcastId" to "p1")?.destination(),
        )
        assertEquals(PushDestination.Show("p1"), open("type" to "podcast", "podcastId" to "p1")?.destination())
        assertEquals(PushDestination.MovieItem("m1"), open("type" to "download", "itemId" to "m1")?.destination())
        assertEquals(PushDestination.Movies, open("type" to "download", "itemId" to "")?.destination())
        assertEquals(PushDestination.None, open("type" to "login")?.destination())
        // Not one of ours.
        assertNull(open("type" to "something-else"))
        assertNull(open())
    }
}
