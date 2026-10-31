package app.inkbridge.core.input

import app.inkbridge.core.protocol.InkPoint
import app.inkbridge.core.protocol.Tool
import kotlinx.coroutines.flow.Flow

/** A stroke lifecycle event in normalized coordinates, ready to transmit. */
sealed interface StylusEvent {
    val strokeId: String

    data class Begin(override val strokeId: String, val tool: Tool, val point: InkPoint) : StylusEvent
    /** All samples from one input event, including historical (batched) ones. */
    data class Move(override val strokeId: String, val points: List<InkPoint>) : StylusEvent
    data class End(override val strokeId: String) : StylusEvent
    data class Cancel(override val strokeId: String) : StylusEvent
}

/**
 * Anything that produces stylus events: Android MotionEvents today, the
 * ONYX pen SDK later if it proves worthwhile. The rest of the app depends
 * only on this, never on a vendor SDK.
 */
interface StylusInputSource {
    fun observeEvents(): Flow<StylusEvent>
}

/** Platform-neutral pointer action, mapped from MotionEvent actions. */
enum class PointerAction { DOWN, MOVE, UP, CANCEL }

/** Platform-neutral tool type, mapped from MotionEvent.getToolType(). */
enum class ToolKind { STYLUS, ERASER, FINGER, MOUSE, UNKNOWN }

/** A raw sample in surface pixels with its event time in ns. */
data class RawSample(val x: Float, val y: Float, val pressure: Float, val timeNs: Long)
