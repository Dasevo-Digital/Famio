package de.status403.famio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Text in photos (`famio/ocr`), e.g. appointments from a letter from
 * school: ML Kit on the phone. Its model is inside the app, or in the small
 * package for 64-bit phones comes from Google Play services: until those
 * have loaded it once, the answer is the error "downloading" and the
 * download starts.
 */
class OcrChannel(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        /** When the model was first asked for; null once it is there. */
        @Volatile private var askedAt: Long? = null

        /** Google Play refused the download (e.g. outdated Play services). */
        @Volatile private var refused = false

        /** A download that takes longer is not coming. */
        private const val PATIENCE_MS = 10 * 60 * 1000L
    }

    init {
        MethodChannel(messenger, "famio/ocr").setMethodCallHandler { call, result ->
            when (call.method) {
                "pdfText" -> withRecognizer(result) { pdfText(it, call.argument<String>("path")!!, result) }
                "recognize" -> withRecognizer(result) { recognize(it, call.argument<String>("path"), result) }
                "models" -> result.success(if (BuildConfig.PLAY_SERVICES_MODELS) "play" else "bundled")
                else -> result.notImplemented()
            }
        }
    }

    /** Runs [use] once the model is there; else starts its download. */
    private fun withRecognizer(result: MethodChannel.Result, use: (TextRecognizer) -> Unit) {
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        if (!BuildConfig.PLAY_SERVICES_MODELS) {
            use(recognizer)
            return
        }
        val modules = ModuleInstall.getClient(context)
        modules.areModulesAvailable(recognizer)
            .addOnSuccessListener { answer ->
                if (answer.areModulesAvailable()) {
                    askedAt = null
                    use(recognizer)
                    return@addOnSuccessListener
                }
                recognizer.close()
                val now = System.currentTimeMillis()
                val since = askedAt ?: now.also { askedAt = it }
                if (refused || now - since > PATIENCE_MS) {
                    result.error("unavailable", "Google Play services cannot provide the text recognition", null)
                    return@addOnSuccessListener
                }
                modules.installModules(
                    ModuleInstallRequest.newBuilder()
                        .addApi(TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS))
                        .build(),
                ).addOnFailureListener {
                    android.util.Log.w("FamioOcr", "model download refused: ${it.message}")
                    refused = true
                }
                result.error("downloading", "The text recognition is being loaded by Google Play services", null)
            }
            .addOnFailureListener {
                recognizer.close()
                result.error("unavailable", it.message, null)
            }
    }

    private fun recognize(recognizer: TextRecognizer, path: String?, result: MethodChannel.Result) {
        val image = runCatching {
            InputImage.fromFilePath(context, Uri.fromFile(File(path!!)))
        }.getOrNull()
        if (image == null) {
            recognizer.close()
            result.success(null)
            return
        }
        recognizer.process(image)
            .addOnSuccessListener { text ->
                // Blocks top to bottom, lines in order.
                val lines = text.textBlocks
                    .sortedBy { it.boundingBox?.top ?: 0 }
                    .flatMap { block -> block.lines.map { it.text } }
                result.success(lines.joinToString("\n"))
                recognizer.close()
            }
            .addOnFailureListener {
                result.success(null)
                recognizer.close()
            }
    }

    /** Up to the first three pages of a PDF, rendered and read with ML Kit. */
    private fun pdfText(recognizer: TextRecognizer, path: String, result: MethodChannel.Result) {
        val pages = runCatching {
            ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                PdfRenderer(fd).use { pdf ->
                    (0 until minOf(pdf.pageCount, 3)).map { index ->
                        pdf.openPage(index).use { page ->
                            val bitmap = Bitmap.createBitmap(
                                page.width * 2,
                                page.height * 2,
                                Bitmap.Config.ARGB_8888,
                            )
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            bitmap
                        }
                    }
                }
            }
        }.getOrNull()
        if (pages.isNullOrEmpty()) {
            recognizer.close()
            result.success(null)
            return
        }
        val texts = arrayOfNulls<String>(pages.size)
        var left = pages.size
        pages.forEachIndexed { i, bitmap ->
            recognizer.process(InputImage.fromBitmap(bitmap, 0))
                .addOnCompleteListener { task ->
                    texts[i] = (if (task.isSuccessful) task.result else null)?.textBlocks
                        ?.sortedBy { it.boundingBox?.top ?: 0 }
                        ?.flatMap { block -> block.lines.map { it.text } }
                        ?.joinToString("\n")
                    if (--left == 0) {
                        recognizer.close()
                        result.success(texts.filterNotNull().joinToString("\n"))
                    }
                }
        }
    }
}
