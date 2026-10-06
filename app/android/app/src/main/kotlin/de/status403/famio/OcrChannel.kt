package de.status403.famio

import android.content.Context
import android.net.Uri
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
}
