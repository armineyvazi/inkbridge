package app.inkbridge.core.canvas

/**
 * The engineering diagram as the Mac sends it (diagram.state). The Mac owns
 * and edits it; connector paths arrive already routed, so the tablet draws
 * exactly the same lines without its own routing code.
 */
data class DiagramSnapshot(val nodes: List<Node> = emptyList(), val edges: List<Edge> = emptyList()) {
    data class Node(val id: String, val kind: String, val label: String, val shape: String,
                    val x: Double, val y: Double, val w: Double, val h: Double)

    /** [points] are canvas px, x0,y0,x1,y1,... */
    data class Edge(val id: String, val from: String, val to: String, val kind: String, val style: String,
                    val label: String, val dashed: Boolean, val points: List<Double>)

    val isEmpty get() = nodes.isEmpty() && edges.isEmpty()

    /** For Fit: everything the diagram covers. */
    fun bounds(): Bounds = nodes.fold(Bounds.EMPTY) { b, n -> b.union(Bounds(n.x, n.y, n.x + n.w, n.y + n.h)) }
}
