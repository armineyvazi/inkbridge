package app.inkbridge.android.features.canvas

import android.os.Process
import android.os.SystemClock
import app.inkbridge.android.input.AndroidMotionEventSource

/**
 * CPU and memory for the perf log: process CPU time since the last snapshot as a share
 * of one core, Java + native heap in use, and input samples seen / dropped. Cheap enough
 * to call every 200 frames (reads two counters, no file I/O).
 */
object PerfProbe {
    private var lastCpuMs = Process.getElapsedCpuTime()
    private var lastWallMs = SystemClock.elapsedRealtime()

    @Synchronized fun snapshot(): String {
        val cpu = Process.getElapsedCpuTime()
        val wall = SystemClock.elapsedRealtime()
        val share = if (wall > lastWallMs) 100.0 * (cpu - lastCpuMs) / (wall - lastWallMs) else 0.0
        lastCpuMs = cpu; lastWallMs = wall
        val rt = Runtime.getRuntime()
        val javaMb = (rt.totalMemory() - rt.freeMemory()) / 1_048_576.0
        val nativeMb = android.os.Debug.getNativeHeapAllocatedSize() / 1_048_576.0
        return "cpu %.0f%% of a core · heap java %.1f MB native %.1f MB · samples %d dropped %d".format(
            share, javaMb, nativeMb, AndroidMotionEventSource.samplesSeen.get(), AndroidMotionEventSource.droppedSamples.get(),
        )
    }
}
