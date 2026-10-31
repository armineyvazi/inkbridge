package app.inkbridge.core

import app.inkbridge.core.client.ClientState
import app.inkbridge.core.client.FailureKind
import app.inkbridge.core.connection.ConnectionFacts
import app.inkbridge.core.connection.ConnectionMode
import app.inkbridge.core.connection.ConnectionStatus
import app.inkbridge.core.connection.PairingLink
import app.inkbridge.core.connection.PrimaryAction
import app.inkbridge.core.connection.Stage
import app.inkbridge.core.connection.Tone
import app.inkbridge.core.input.PressureResponse
import app.inkbridge.core.protocol.PairingAuth
import app.inkbridge.core.transport.TransportKind.USB
import app.inkbridge.core.transport.TransportKind.WIFI
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConnectionStatusTest {
    private fun facts(
        client: ClientState? = null, paired: String? = null, discovered: Int = 0, pairing: Boolean = false,
        was: Boolean = false, mode: ConnectionMode = ConnectionMode.WIFI, paused: Boolean = false,
    ) = ConnectionStatus.describe(ConnectionFacts(mode, paired, pairing, discovered, client, 4.2, was, paused))

    @Test
    fun firstConnectionWalksThroughTheStages() {
        val stages = listOf(
            facts(),
            facts(discovered = 1),
            facts(ClientState.Connecting(WIFI, 1), pairing = true),
            facts(ClientState.Authenticating(WIFI, pairing = true), pairing = true),
            facts(ClientState.Ready(WIFI, "Studio Mac", "s"), paired = "Studio Mac"),
        ).map { it.stage }
        assertEquals(listOf(Stage.NOT_PAIRED, Stage.FOUND, Stage.CONNECTING, Stage.PAIRING, Stage.CONNECTED), stages)
    }

    @Test
    fun primaryActionIsTheObviousNextStep() {
        assertEquals(PrimaryAction.CONNECT_TO_MAC, facts().primary)
        val ready = facts(ClientState.Ready(WIFI, "Studio Mac", "s"), paired = "Studio Mac")
        assertEquals(PrimaryAction.OPEN_CANVAS, ready.primary)
        assertEquals(Tone.GOOD, ready.tone)
        assertTrue(ready.detail.contains("4 ms"))
        assertEquals(PrimaryAction.CONNECT_TO_MAC, facts(paired = "Studio Mac", paused = true).primary)
    }

    @Test
    fun lostLinkReadsAsReconnectingNotSearching() {
        val r = facts(ClientState.Retrying(WIFI, 2, 500, "connect 10.0.0.2:8766: ECONNREFUSED"), paired = "M", was = true)
        assertEquals(Stage.RECONNECTING, r.stage)
        assertTrue(r.detail.contains("isn't accepting"), "socket errors are reworded: ${r.detail}")
        assertEquals(Stage.DISCOVERING, facts(ClientState.Retrying(WIFI, 1, 250, "x"), paired = "M").stage)
        assertEquals(Stage.CONNECTING, facts(ClientState.Retrying(USB, 1, 250, "x"), mode = ConnectionMode.USB).stage)
    }

    @Test
    fun everyFailureTellsTheUserWhatToDo() {
        for (kind in FailureKind.entries) {
            val s = facts(ClientState.Failed("r", kind), paired = "M")
            assertEquals(Stage.FAILED, s.stage)
            assertEquals(Tone.PROBLEM, s.tone)
            assertTrue(s.detail.isNotBlank())
            val expected = if (kind == FailureKind.PROTOCOL) PrimaryAction.RETRY else PrimaryAction.PAIR_AGAIN
            assertEquals(expected, s.primary, kind.name)
        }
    }
}

class PairingLinkTest {
    @Test
    fun parsesTheSharedFixture() {
        val link = assertNotNull(PairingLink.parse(Fixtures.bytes("pairing-link.txt").decodeToString()))
        assertEquals("Armin’s MacBook Pro", link.hostName)
        assertEquals(listOf("192.168.1.20", "10.0.0.5"), link.addresses)
        assertEquals(8766, link.port)
        assertEquals("K7QWM3XP", link.code)
        assertEquals("a0a1", PairingAuth.toHex(link.fingerprint).take(4))
        assertTrue(link.expired(nowEpochSec = 1793448000))
    }

    @Test
    fun rejectsIncompleteOrForeignLinks() {
        val good = Fixtures.bytes("pairing-link.txt").decodeToString().trim()
        assertNull(PairingLink.parse("https://example.com/pair"))
        assertNull(PairingLink.parse(good.replace("v=3", "v=2")))
        assertNull(PairingLink.parse(good.replace(Regex("fp=[0-9a-f]+"), "fp=abcd")))
        assertNull(PairingLink.parse(good.replace("code=K7QWM3XP", "code=K7Q")))
    }
}

class PressureResponseTest {
    @Test
    fun curvesKeepEndpointsAndOrder() {
        for (r in listOf(PressureResponse.SOFT, PressureResponse.NORMAL, PressureResponse.FIRM)) {
            assertEquals(0.0, r.apply(0.0))
            assertEquals(1.0, r.apply(1.0))
        }
        assertTrue(PressureResponse.SOFT.apply(0.5) > PressureResponse.NORMAL.apply(0.5))
        assertTrue(PressureResponse.FIRM.apply(0.5) < PressureResponse.NORMAL.apply(0.5))
        assertEquals(1.0, PressureResponse.OFF.apply(0.1))
    }
}
