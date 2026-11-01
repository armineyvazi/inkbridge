package app.inkbridge.core

import app.inkbridge.core.canvas.CanvasDocument
import app.inkbridge.core.canvas.DiagramSnapshot
import app.inkbridge.core.protocol.MessageCodec
import app.inkbridge.core.protocol.Payload
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiagramTest {
    @Test
    fun snapshotDecodesTheSharedFixtureAndReachesTheMirror() {
        val m = MessageCodec.decode(Fixtures.bytes("valid/diagram.state.json"))
        val p = m.payload as Payload.Diagram
        assertEquals(listOf("API Gateway", "Orders DB"), p.diagram.nodes.map { it.label })
        assertEquals("cylinder", p.diagram.nodes[1].shape)
        assertEquals(8, p.diagram.edges[0].points.size, "routed path arrives ready to draw")
        assertEquals(m, MessageCodec.decode(MessageCodec.encode(m)))
        val doc = CanvasDocument()
        doc.applyHost(p)
        assertEquals(2, doc.diagram.nodes.size)
        assertTrue(doc.contentBoundsWithDiagram().width >= 430, "Fit includes the diagram")
        doc.applyHost(Payload.Diagram(DiagramSnapshot(), 2))  // older revision ignored
        assertEquals(2, doc.diagram.nodes.size)
    }

    @Test
    fun emptyAndNonLatinLabelsAreValid() {
        val json = "{\"version\":3,\"type\":\"diagram.state\",\"sequence\":1,\"timestamp_ns\":1,\"revision\":9," +
            "\"nodes\":[{\"id\":\"a\",\"kind\":\"process\",\"label\":\"پرداخت سفارش\",\"shape\":\"box\",\"x\":0,\"y\":0,\"w\":10,\"h\":10}]," +
            "\"edges\":[{\"id\":\"e\",\"from\":\"a\",\"to\":\"a\",\"kind\":\"http\",\"style\":\"straight\",\"label\":\"\",\"dashed\":false,\"points\":[0,0,1,1]}]}"
        val d = (MessageCodec.decode(json.encodeToByteArray()).payload as Payload.Diagram).diagram
        assertEquals("پرداخت سفارش", d.nodes[0].label)
        assertEquals("", d.edges[0].label)
    }
}
