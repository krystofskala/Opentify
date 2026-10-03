package app.opentify.opentify_client

import android.content.Intent
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// audio_service: přehrávání na pozadí + ovládání v notifikaci / na zámku.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Aktualizace appky: stažené APK předá systémovému instalátoru
        // (napoprvé se Android zeptá na "Instalovat z tohoto zdroje").
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.opentify/update").setMethodCallHandler { call, result ->
            if (call.method != "installApk") return@setMethodCallHandler result.notImplemented()
            try {
                val file = File(call.argument<String>("path")!!)
                val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                startActivity(Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                })
                result.success(null)
            } catch (e: Exception) {
                result.error("install", e.message, null)
            }
        }
    }
}
