package works.angel.angel_live_android_tv

import android.annotation.SuppressLint
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.View
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val runtimes = mutableMapOf<String, WebView>()
    private val bridges = mutableMapOf<String, HostBridge>()
    private val handler = Handler(Looper.getMainLooper())
    private val secretPrefs by lazy { getSharedPreferences("encrypted_vault_v1", MODE_PRIVATE) }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("angel_tv_vault", null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder("angel_tv_vault", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return generator.generateKey()
    }

    @Synchronized private fun readSecret(key: String): String {
        val stored = secretPrefs.getString(key, null) ?: return ""
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }

    @Synchronized private fun writeSecret(key: String, value: String) {
        if (value.isEmpty()) { secretPrefs.edit().remove(key).apply(); return }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val bytes = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        secretPrefs.edit().putString(key, Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
    }

    inner class HostBridge(private val engineId: String, val pluginId: String, cookie: String) {
        @Volatile var cookieHeader = cookie
        private val storage = ConcurrentHashMap<String, String>()
        @JavascriptInterface fun postMessage(message: String) {
            if (message.length > 20 * 1024 * 1024) return
            try {
                val payload = JSONObject(message)
                if (payload.optString("type") == "storage") {
                    val value = payload.optJSONObject("value")?.toString() ?: "{}"
                    if (value.length <= 1024 * 1024) writeSecret("storage:$pluginId", value)
                    return
                }
            } catch (_: Exception) { return }
            handler.post { if (runtimes.containsKey(engineId)) channel.invokeMethod("message", mapOf("engineId" to engineId, "message" to message)) }
        }
        @JavascriptInterface fun md5(value: String): String = MessageDigest.getInstance("MD5").digest(value.toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        @JavascriptInterface fun base64Decode(value: String): String = try { String(Base64.decode(value, Base64.DEFAULT), Charsets.UTF_8) } catch (_: Exception) { "" }
        @JavascriptInterface fun cookie(platformId: String): String = if (platformId.isEmpty() || platformId == pluginId) cookieHeader else ""
        @JavascriptInterface fun storageGet(key: String): String = storage[key] ?: readSecret("storage:$pluginId:$key").also { storage[key] = it }
        @JavascriptInterface fun storageSet(key: String, value: String) { if (key.length <= 200 && value.length <= 1024 * 1024) { storage[key] = value; writeSecret("storage:$pluginId:$key", value) } }
        @JavascriptInterface fun inflate(value: String, gzip: Boolean): String = try {
            val input = ByteArrayInputStream(Base64.decode(value, Base64.DEFAULT))
            val stream = if (gzip) GZIPInputStream(input) else InflaterInputStream(input)
            stream.use { String(it.readBytes(), Charsets.ISO_8859_1) }
        } catch (_: Exception) { "" }
    }

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "angel_tv/runtime")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "vault.read" -> result.success(readSecret(call.argument<String>("key")!!))
                    "vault.write" -> { writeSecret(call.argument<String>("key")!!, call.argument<String>("value") ?: ""); result.success(null) }
                    "create" -> {
                        val id = call.argument<String>("engineId")!!
                        val scripts = call.argument<List<String>>("scripts")!!
                        val bridge = HostBridge(id, call.argument<String>("pluginId")!!, call.argument<String>("cookie") ?: "")
                        val view = WebView(this)
                        view.setBackgroundColor(Color.TRANSPARENT)
                        view.alpha = 0f
                        view.isFocusable = false
                        view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                        view.settings.javaScriptEnabled = true
                        view.settings.allowFileAccess = false
                        view.settings.allowContentAccess = false
                        view.settings.blockNetworkLoads = true
                        view.settings.domStorageEnabled = false
                        view.addJavascriptInterface(bridge, "NativeHost")
                        runtimes[id] = view
                        bridges[id] = bridge
                        (findViewById<View>(android.R.id.content) as FrameLayout).addView(view, FrameLayout.LayoutParams(1, 1))
                        var finished = false
                        view.webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true
                            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                                WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                            override fun onPageFinished(v: WebView, url: String) {
                                if (finished) return
                                finished = true
                                val config = JSONObject().put("pluginId", bridge.pluginId).put("cookie", bridge.cookieHeader)
                                config.put("storage", try { JSONObject(readSecret("storage:${bridge.pluginId}").ifEmpty { "{}" }) } catch (_: Exception) { JSONObject() })
                                val wrapped = "globalThis.__tvConfig=" + config.toString() + ";\n" + scripts.joinToString("\n") { "(0,eval)(" + JSONObject.quote(it) + ");" }
                                val workerScript = "try { $wrapped NativeHost.postMessage(JSON.stringify({type:'ready'})); } catch(e) { postMessage(JSON.stringify({type:'loadError',error:String(e && e.message || e)})); }"
                                val launch = "globalThis.__tvWorker=new Worker(URL.createObjectURL(new Blob([" + JSONObject.quote(workerScript) + "],{type:'application/javascript'})));__tvWorker.onmessage=function(e){NativeHost.postMessage(e.data);};__tvWorker.onerror=function(e){NativeHost.postMessage(JSON.stringify({type:'loadError',error:String(e.message)}));};"
                                v.evaluateJavascript(launch, null)
                            }
                        }
                        view.loadDataWithBaseURL("https://runtime.invalid/", "<html><head><meta charset='utf-8'></head><body></body></html>", "text/html", "UTF-8", null)
                        result.success(null)
                    }
                    "eval" -> {
                        val view = runtimes[call.argument<String>("engineId")!!]
                        if (view == null) result.error("CLOSED", "Runtime closed", null)
                        else { view.evaluateJavascript("__tvWorker.postMessage({script:" + JSONObject.quote(call.argument<String>("script")!!) + "});", null); result.success(null) }
                    }
                    "session" -> {
                        val id = call.argument<String>("engineId")!!
                        val cookie = call.argument<String>("cookie") ?: ""
                        bridges[id]?.cookieHeader = cookie
                        runtimes[id]?.evaluateJavascript("__tvWorker.postMessage({script:" + JSONObject.quote("NativeHost.setCookie(" + JSONObject.quote(cookie) + ");") + "});", null)
                        result.success(null)
                    }
                    "dispose" -> {
                        val id = call.argument<String>("engineId")!!
                        runtimes.remove(id)?.let { it.evaluateJavascript("if(globalThis.__tvWorker)__tvWorker.terminate();", null); (it.parent as? FrameLayout)?.removeView(it); it.removeJavascriptInterface("NativeHost"); it.destroy() }
                        bridges.remove(id)
                        result.success(null)
                    }
                    "webviewVersion" -> result.success(if (android.os.Build.VERSION.SDK_INT >= 26) WebView.getCurrentWebViewPackage()?.versionName else "system")
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("HOST", e.javaClass.simpleName, null) }
        }
    }

    override fun onDestroy() {
        runtimes.values.forEach { it.evaluateJavascript("if(globalThis.__tvWorker)__tvWorker.terminate();", null); it.removeJavascriptInterface("NativeHost"); it.destroy() }
        runtimes.clear()
        bridges.clear()
        super.onDestroy()
    }
}
