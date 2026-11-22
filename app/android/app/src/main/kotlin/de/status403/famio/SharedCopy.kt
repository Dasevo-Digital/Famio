package de.status403.famio

import java.io.File
import java.io.InputStream
import java.io.OutputStream

/** What other apps hand to Famio, read within limits (#580). */
object SharedCopy {
    /**
     * Copies [input] to [output]: the number of bytes, or null as soon as
     * there are more than [limit]; it stops reading then.
     */
    fun copyAtMost(input: InputStream, output: OutputStream, limit: Long): Long? {
        val buffer = ByteArray(64 * 1024)
        var copied = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return copied
            copied += n
            if (copied > limit) return null
            output.write(buffer, 0, n)
        }
    }

    /**
     * Copies [input] into [target]: true for 1 to [limit] bytes. Anything
     * else (empty, too large, unreadable) leaves no partial file behind.
     */
    fun copyToFile(input: InputStream, target: File, limit: Long): Boolean {
        val ok = runCatching {
            target.outputStream().use { out -> (copyAtMost(input, out, limit) ?: 0L) > 0L }
        }.getOrDefault(false)
        if (!ok) target.delete()
        return ok
    }

    /**
     * Whether Famio reads a file another app hands over: only through a
     * content provider ([scheme] `content`) that is not one of Famio's own
     * ([owner], the package the provider belongs to, if known). A `file://`
     * address or one of Famio's own providers could point at Famio's
     * private files (#580, #519).
     */
    fun fromOtherApp(scheme: String?, owner: String?, ownPackage: String) =
        scheme == "content" && owner != ownPackage
}
