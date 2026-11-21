package com.carriez.flutter_hbb

import android.app.Activity
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import kotlin.concurrent.thread

/**
 * Android side of moving files between the phone and the PC being controlled:
 * received files go to Downloads, and files shared from other apps are handed
 * to the running remote session.
 */
object QuickShare {
    private const val TAG = "QuickShare"
    private const val CHANNEL = "rustdesk/quick_share"
    const val EXTRA_PATHS = "quick_share_paths"
    const val EXTRA_TEXT = "quick_share_text"

    private var channel: MethodChannel? = null

    fun attach(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "save_to_downloads" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("bad_args", null, null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val subdir = call.argument<String>("subdir")
                                ?.split('/')?.filter { it.isNotBlank() && it != "." && it != ".." }
                                ?.joinToString("/") ?: ""
                            val uri = saveToDownloads(activity, File(path), name, subdir)
                            activity.runOnUiThread { result.success(uri.toString()) }
                        } catch (e: Exception) {
                            Log.e(TAG, "Saving $name failed", e)
                            activity.runOnUiThread { result.error("save_failed", e.message, null) }
                        }
                    }
                }
                "save_to_pictures" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("bad_args", null, null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val uri = saveToPictures(activity, File(path), name)
                            activity.runOnUiThread { result.success(uri.toString()) }
                        } catch (e: UnsupportedOperationException) {
                            activity.runOnUiThread { result.error("unsupported", null, null) }
                        } catch (e: Exception) {
                            Log.e(TAG, "Saving $name failed", e)
                            activity.runOnUiThread { result.error("save_failed", e.message, null) }
                        }
                    }
                }
                "share" -> {
                    val uri = call.argument<String>("uri")?.let { Uri.parse(it) }
                    val send = Intent(Intent.ACTION_SEND).apply {
                        if (uri != null) {
                            type = call.argument<String>("mime")
                                ?: activity.contentResolver.getType(uri) ?: "*/*"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = ClipData.newRawUri(null, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        } else {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        }
                    }
                    val chooser = Intent.createChooser(send, null)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        // Back into RustDesk it would only go to the PC it came from.
                        chooser.putExtra(
                            Intent.EXTRA_EXCLUDE_COMPONENTS,
                            arrayOf(ComponentName(activity, ShareReceiverActivity::class.java))
                        )
                    }
                    try {
                        activity.startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("no_app", e.message, null)
                    }
                }
                "open" -> {
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    try {
                        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, activity.contentResolver.getType(uri))
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("no_app", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Files another app shared, copied by [ShareReceiverActivity]. */
    fun deliver(activity: Activity, intent: Intent?) {
        deliverText(activity, intent)
        val paths = intent?.getStringArrayListExtra(EXTRA_PATHS) ?: return
        intent.removeExtra(EXTRA_PATHS)
        if (paths.isEmpty()) return
        val ch = channel
        val noSession = {
            Toast.makeText(
                activity, "Connect to a PC in RustDesk first, then share again.",
                Toast.LENGTH_LONG
            ).show()
        }
        if (ch == null) {
            noSession()
            return
        }
        ch.invokeMethod("incoming", paths, object : MethodChannel.Result {
            override fun success(r: Any?) {
                if (r != true) noSession()
            }

            override fun error(code: String, msg: String?, details: Any?) = noSession()
            override fun notImplemented() = noSession()
        })
    }

    /** Text another app shared, passed on by [ShareReceiverActivity]. */
    private fun deliverText(activity: Activity, intent: Intent?) {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: return
        intent.removeExtra(EXTRA_TEXT)
        val noSession = {
            Toast.makeText(
                activity, "Connect to a PC in RustDesk first, then share again.",
                Toast.LENGTH_LONG
            ).show()
        }
        val ch = channel ?: return noSession()
        ch.invokeMethod("incoming_text", text, object : MethodChannel.Result {
            override fun success(r: Any?) {
                if (r != true) noSession()
            }

            override fun error(code: String, msg: String?, details: Any?) = noSession()
            override fun notImplemented() = noSession()
        })
    }

    private fun saveToPictures(context: Context, source: File, name: String): Uri {
        // Older versions need a storage permission the app does not ask for.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) throw UnsupportedOperationException()
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/RustDesk")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore refused $name")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(source).use { it.copyTo(out) }
            } ?: throw IllegalStateException("Cannot write $name")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    private fun saveToDownloads(context: Context, source: File, name: String, subdir: String): Uri {
        val mime = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
                if (subdir.isNotEmpty()) {
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/" + subdir
                    )
                }
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore refused $name")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(source).use { it.copyTo(out) }
                } ?: throw IllegalStateException("Cannot write $name")
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return uri
        }
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), subdir
        )
        dir.mkdirs()
        var target = File(dir, name)
        var i = 2
        while (target.exists()) {
            val stem = name.substringBeforeLast('.')
            val ext = if (name.contains('.')) "." + name.substringAfterLast('.') else ""
            target = File(dir, "$stem ($i)$ext")
            i++
        }
        source.copyTo(target)
        return Uri.fromFile(target)
    }
}

/**
 * Target of "Share" in other apps. Copies the shared files where the app can
 * read them and passes them to [MainActivity], whose remote session sends
 * them on. A separate activity, so sharing never starts a second Flutter
 * engine in the sharing app's task.
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = sharedUris(intent)
        if (uris.isEmpty()) {
            sharedText(intent)?.let { text ->
                startActivity(Intent(this, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    )
                    putExtra(QuickShare.EXTRA_TEXT, text)
                })
            }
            finish()
            return
        }
        thread {
            val dir = File(cacheDir, "quick_share_in").apply { mkdirs() }
            val paths = ArrayList<String>()
            for (uri in uris) {
                try {
                    val name = displayName(uri) ?: uri.lastPathSegment ?: "file"
                    val safe = name.replace('/', '_').replace('\\', '_')
                    val target = File(File(dir, System.nanoTime().toString()).apply { mkdirs() }, safe)
                    contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { input.copyTo(it) }
                    } ?: continue
                    paths.add(target.absolutePath)
                } catch (e: Exception) {
                    Log.e("QuickShare", "Cannot read shared $uri", e)
                }
            }
            runOnUiThread {
                startActivity(Intent(this, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    )
                    putStringArrayListExtra(QuickShare.EXTRA_PATHS, paths)
                })
                finish()
            }
        }
    }

    private fun sharedUris(intent: Intent?): List<Uri> {
        intent ?: return emptyList()
        @Suppress("DEPRECATION")
        return when (intent.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            else -> emptyList()
        }
    }

    private fun sharedText(intent: Intent?): String? =
        intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
}
