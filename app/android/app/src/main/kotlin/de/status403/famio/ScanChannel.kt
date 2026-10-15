package de.status403.famio

import android.app.Activity
import android.content.Intent
import android.util.Log
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Letters and forms with the camera (`famio/scan`): Google's document
 * scanner (Play services) finds the page edges, straightens the pages and
 * makes one PDF of them, on the phone. Famio then uploads it like any file.
 */
class ScanChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private var pending: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, "famio/scan").setMethodCallHandler { call, result ->
            if (call.method != "scan") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pending != null) {
                result.error("busy", null, null)
                return@setMethodCallHandler
            }
            val options = GmsDocumentScannerOptions.Builder()
                .setGalleryImportAllowed(true)
                .setPageLimit(20)
                .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
                .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
                .build()
            GmsDocumentScanning.getClient(options).getStartScanIntent(activity)
                .addOnSuccessListener { sender ->
                    pending = result
                    activity.startIntentSenderForResult(sender, REQUEST, null, 0, 0, 0)
                }
                .addOnFailureListener { e ->
                    // No Play services, or the scanner module is missing.
                    Log.w("FamioScan", "scanner not available", e)
                    result.error("unavailable", e.message, null)
                }
        }
    }

    /** From [MainActivity.onActivityResult]; true if it was the scanner's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            Log.i("FamioScan", "scan ended without pages ($resultCode)")
            result.success(null)
            return true
        }
        val uri = GmsDocumentScanningResult.fromActivityResultIntent(data)?.pdf?.uri
        val bytes = uri?.let {
            runCatching {
                activity.contentResolver.openInputStream(it)?.use { input -> input.readBytes() }
            }.getOrNull()
        }
        result.success(bytes)
        return true
    }

    private companion object {
        const val REQUEST = 4711
    }
}
