package dev.guigo.guigo

import android.app.Dialog
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// local_auth needs a FragmentActivity host
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // the Office pane's export (lib/features/session/office_platform.dart):
        // client-side only, nothing goes back to the SAP server
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guigo/office_document")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val name = call.argument<String>("fileName")
                val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (bytes == null || name.isNullOrBlank()) {
                    result.error("bad_args", "bytes and fileName required", null)
                    return@setMethodCallHandler
                }
                try {
                    result.success(saveToDownloads(bytes, safeName(name), mime))
                } catch (e: Exception) {
                    result.error("write_failed", e.message, null)
                }
            }
        // the server's browser launches (lib/features/session/browser_platform.dart)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guigo/browser")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openExternal" -> {
                        val url = webUri(call.argument<String>("url"))
                        if (url == null) {
                            result.error("bad_url", "an http(s) url is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, url)
                                    .addCategory(Intent.CATEGORY_BROWSABLE)
                            )
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.success(false)
                        }
                    }
                    "openSso" -> {
                        val service = webUri(call.argument<String>("serviceUrl"))
                        val target = webUri(call.argument<String>("url"))
                        val body = call.argument<String>("body")
                        if (service == null || target == null || body == null) {
                            result.error("bad_args", "serviceUrl, url and body required", null)
                            return@setMethodCallHandler
                        }
                        // the token goes to the host the server launched, over https only
                        if (!sameHttpsOrigin(service, target)) {
                            result.error(
                                "sso_refused",
                                "the SSO service is not the launched https host",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        showSsoBrowser(service.toString(), body)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun webUri(text: String?): Uri? {
        if (text.isNullOrBlank()) return null
        val u = Uri.parse(text.trim())
        val scheme = u.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        if (u.host.isNullOrEmpty()) return null
        return u
    }

    private fun portOf(u: Uri): Int =
        if (u.port != -1) u.port else if (u.scheme?.lowercase() == "https") 443 else 80

    private fun sameHttpsOrigin(a: Uri, b: Uri): Boolean =
        a.scheme?.lowercase() == "https" && b.scheme?.lowercase() == "https" &&
            a.host?.lowercase() == b.host?.lowercase() && portOf(a) == portOf(b)

    /** The in-app browser of an SSO launch: a full-screen WebView POSTs [body]
     *  (the real SAP GUI's `sap-mysapsso` / `sap-mysapred` form) to [service];
     *  the server sets its MYSAPSSO2 cookie and redirects. The app's WebView
     *  cookie store starts empty and is wiped when the dialog closes (GuiGo
     *  has no other WebView), so the ticket's cookie never outlives the view;
     *  the token itself is never logged. "Open in browser" hands the current
     *  page to the system browser (signed off there). */
    private fun showSsoBrowser(service: String, body: String) {
        val cookies = CookieManager.getInstance()
        cookies.removeAllCookies(null)
        cookies.setAcceptCookie(true)
        val dialog = Dialog(this, android.R.style.Theme_DeviceDefault_NoActionBar)
        val web = WebView(this)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.webViewClient = WebViewClient() // navigations stay in this view
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        bar.addView(Button(this).apply {
            text = "Done"
            setOnClickListener { dialog.dismiss() }
        })
        bar.addView(Button(this).apply {
            text = "Open in browser"
            setOnClickListener {
                val now = webUri(web.url) ?: return@setOnClickListener
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, now).addCategory(Intent.CATEGORY_BROWSABLE)
                    )
                } catch (e: ActivityNotFoundException) {
                    // no browser installed: the page stays in this view
                }
            }
        })
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(bar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(web, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        dialog.setContentView(root)
        dialog.setOnDismissListener {
            web.stopLoading()
            web.clearHistory()
            web.clearCache(true)
            web.destroy()
            WebStorage.getInstance().deleteAllData()
            cookies.removeAllCookies(null)
            cookies.flush()
        }
        dialog.show()
        web.postUrl(service, body.toByteArray(Charsets.UTF_8))
    }

    private fun safeName(name: String): String {
        val s = name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").trim()
        return if (s.isEmpty() || s.startsWith(".")) "document$s" else s
    }

    /** [bytes] as Downloads/GuiGo/[name] (MediaStore, API 29+), else in the
     *  app's own documents folder; the place it went, for the snackbar. */
    private fun saveToDownloads(bytes: ByteArray, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val folder = Environment.DIRECTORY_DOWNLOADS + "/GuiGo"
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore refused the file")
            try {
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("cannot open $uri")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return "$folder/$name"
        }
        val dir = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: filesDir
        val file = File(dir, name)
        file.writeBytes(bytes)
        return file.absolutePath
    }
}
