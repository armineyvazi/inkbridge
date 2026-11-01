package app.inkbridge.core

import app.inkbridge.core.input.LatencyRecorder
import app.inkbridge.core.protocol.JOURNAL_ACTIONS
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.Payload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class JournalProtocolTest {
    @Test
    fun hiddenIsOptionalAndHideShowAreActions() {
        // A Mac without hide/show omits "hidden".
        val old = """{"version":3,"type":"journal.state","sequence":1,"timestamp_ns":1,"active":true,"day":"2026-11-01","today":true,"title":"","revision":1,"entries":[]}"""
        assertFalse((MessageCodec.decode(old.toByteArray()).payload as Payload.Journal).hidden)
        val hide = MessageCodec.decode(Fixtures.bytes("valid/journal.request.hide.json")).payload as Payload.JournalRequest
        assertEquals("hide", hide.action)
        assertTrue(JOURNAL_ACTIONS.containsAll(listOf("hide", "show")))
        val state = MessageCodec.decode(Fixtures.bytes("valid/journal.state.json")).payload as Payload.Journal
        assertFalse(state.hidden)
    }

    @Test
    fun latencyPercentilesUseTheMostRecentWindow() {
        val r = LatencyRecorder(capacity = 100)
        assertNull(r.percentile(0.5))
        for (i in 1..100) r.add(i.toDouble())
        assertEquals(50.0, r.percentile(0.5))
        assertEquals(95.0, r.percentile(0.95))
        // Older samples fall out of the ring.
        for (i in 1..100) r.add(1000.0)
        assertEquals(1000.0, r.percentile(0.05))
        assertEquals(100, r.size)
        assertTrue(r.summary().startsWith("p50 1000.0"))
    }
}
