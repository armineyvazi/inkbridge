package app.inkbridge.core.protocol

/** `#rrggbbaa` ↔ Android-style ARGB ints, as used on the wire. */
object Colors {
    fun toHex(argb: Int): String {
        val a = argb ushr 24 and 0xff
        val rgb = argb and 0xffffff
        return "#%06x%02x".format(rgb, a)
    }

    fun fromHex(s: String): Int? {
        if (s.length != 9 || s[0] != '#') return null
        val v = s.substring(1).toLongOrNull(16) ?: return null
        val rgba = v.toInt()
        return (rgba and 0xff shl 24) or (rgba ushr 8 and 0xffffff)
    }
}
