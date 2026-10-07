package de.status403.famio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Text in photos (`famio/ocr`), e.g. appointments from a letter from
 * school: ML Kit with its bundled model, on the phone.
 */
class OcrChannel(context: Context, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "famio/ocr").setMethodCallHandler { call, result ->
            if (call.method == "pdfText") {
                pdfText(call.argument<String>("path")!!, result)
                return@setMethodCallHandler
            }
            if (call.method != "recognize") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            val image = runCatching {
                InputImage.fromFilePath(context, Uri.fromFile(File(path!!)))
            }.getOrNull()
            if (image == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
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
    }

    /** Up to the first three pages of a PDF, rendered and read with ML Kit. */
    private fun pdfText(path: String, result: MethodChannel.Result) {
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
            result.success(null)
            return
        }
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
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
