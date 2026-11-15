package com.carriez.flutter_hbb

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.text.InputType
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.BreakIterator

/**
 * Soft keyboard typing for the remote session, in place of a Flutter text
 * field.
 *
 * Flutter shares one editing state between all input connections and changes
 * it under the IME without restarting it, so IME edits made against the text
 * the app just replaced land on the new text: words broke apart, letters got
 * capitalized at random and autocorrect rewrote the wrong text. Here every
 * reset from Dart restarts the IME on a new connection, and edits that still
 * reach an old connection are dropped.
 *
 * Dart owns the buffer: `reset` replaces it, and every change the IME makes is
 * reported back as a `state` with the generation of the reset it is based on.
 */
class RemoteIme private constructor(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        private const val CHANNEL = "rustdesk/remote_ime"

        fun attach(activity: Activity, engine: FlutterEngine) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val ime = RemoteIme(activity, channel)
            channel.setMethodCallHandler(ime::onMethodCall)
        }
    }

    private val imm =
        activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    private val buffer = SpannableStringBuilder()
    private var generation = 0
    private var rawInput = false
    private var view: ImeView? = null

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "reset" -> {
                reset(
                    call.argument<Int>("generation") ?: 0,
                    call.argument<String>("text") ?: "",
                    call.argument<Int>("base") ?: 0,
                    call.argument<Int>("extent") ?: 0,
                    call.argument<Boolean>("raw") ?: false,
                )
                result.success(true)
            }
            "focus" -> {
                val v = ensureView()
                v.requestFocus()
                // showSoftInput is ignored until the IME has bound to the view
                // that just got focus; the insets API waits for that.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    v.windowInsetsController?.show(WindowInsets.Type.ime())
                }
                v.post { if (v.hasFocus()) imm.showSoftInput(v, 0) }
                result.success(true)
            }
            "blur" -> {
                view?.let { v ->
                    if (call.argument<Boolean>("hide") == true) {
                        imm.hideSoftInputFromWindow(v.windowToken, 0)
                    }
                    if (v.hasFocus()) {
                        v.clearFocus()
                        flutterView()?.requestFocus()
                    }
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureView(): ImeView = view ?: ImeView(activity).also {
        activity.addContentView(it, FrameLayout.LayoutParams(1, 1))
        view = it
    }

    private fun flutterView(): View? = activity.findViewById(FlutterActivity.FLUTTER_VIEW_ID)

    private fun reset(gen: Int, text: String, base: Int, extent: Int, raw: Boolean) {
        generation = gen
        rawInput = raw
        buffer.replace(0, buffer.length, text)
        BaseInputConnection.removeComposingSpans(buffer)
        Selection.setSelection(
            buffer,
            base.coerceIn(0, buffer.length),
            extent.coerceIn(0, buffer.length)
        )
        view?.let { if (it.hasFocus()) imm.restartInput(it) }
    }

    private fun report() {
        val v = view ?: return
        val selStart = Selection.getSelectionStart(buffer)
        val selEnd = Selection.getSelectionEnd(buffer)
        val compStart = BaseInputConnection.getComposingSpanStart(buffer)
        val compEnd = BaseInputConnection.getComposingSpanEnd(buffer)
        imm.updateSelection(v, selStart, selEnd, compStart, compEnd)
        channel.invokeMethod(
            "state",
            mapOf(
                "generation" to generation,
                "text" to buffer.toString(),
                "base" to selStart,
                "extent" to selEnd,
                "composingStart" to compStart,
                "composingEnd" to compEnd,
            )
        )
    }

    // Key codes whose down event handleEditingKey() took, so their up event
    // goes the same way.
    private val editingKeysDown = HashSet<Int>()

    // What a text view does for the keys an IME (or a hardware keyboard)
    // sends as key events, so the buffer stays the remote's mirror. Returns
    // false for keys that go to the remote as they are.
    private fun handleEditingKey(e: KeyEvent): Boolean {
        if (e.action == KeyEvent.ACTION_UP) return editingKeysDown.remove(e.keyCode)
        if (e.action != KeyEvent.ACTION_DOWN) return false
        if (applyEditingKey(e)) {
            editingKeysDown.add(e.keyCode)
            return true
        }
        return false
    }

    private fun applyEditingKey(e: KeyEvent): Boolean {
        if (e.isCtrlPressed || e.isAltPressed || e.isMetaPressed || e.isShiftPressed) {
            return false
        }
        val start = Selection.getSelectionStart(buffer)
        val end = Selection.getSelectionEnd(buffer)
        if (start < 0 || end < 0) return false
        val lo = minOf(start, end)
        val hi = maxOf(start, end)
        when (e.keyCode) {
            KeyEvent.KEYCODE_DEL -> {
                val from = if (lo < hi) lo else precedingGrapheme(lo)
                if (from < 0) return false
                replace(from, hi, "")
            }
            KeyEvent.KEYCODE_FORWARD_DEL -> {
                val to = if (lo < hi) hi else followingGrapheme(hi)
                if (to < 0) return false
                replace(lo, to, "")
            }
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> replace(lo, hi, "\n")
            KeyEvent.KEYCODE_TAB -> replace(lo, hi, "\t")
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val left = e.keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                val to = when {
                    lo < hi -> if (left) lo else hi
                    left -> precedingGrapheme(lo)
                    else -> followingGrapheme(hi)
                }
                if (to < 0) return false
                BaseInputConnection.removeComposingSpans(buffer)
                Selection.setSelection(buffer, to)
                report()
            }
            else -> return false
        }
        return true
    }

    private fun replace(start: Int, end: Int, text: String) {
        BaseInputConnection.removeComposingSpans(buffer)
        buffer.replace(start, end, text)
        Selection.setSelection(buffer, start + text.length)
        report()
    }

    private fun graphemes(): BreakIterator =
        BreakIterator.getCharacterInstance().apply { setText(buffer.toString()) }

    private fun precedingGrapheme(offset: Int): Int =
        if (offset <= 0) -1 else graphemes().preceding(offset)

    private fun followingGrapheme(offset: Int): Int =
        if (offset >= buffer.length) -1 else graphemes().following(offset)

    private inner class ImeView(context: Context) : View(context) {
        init {
            isFocusable = true
            isFocusableInTouchMode = true
        }

        override fun onCheckIsTextEditor() = true

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
            outAttrs.inputType = if (rawInput) {
                InputType.TYPE_CLASS_TEXT or
                    InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
                    InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            } else {
                InputType.TYPE_CLASS_TEXT or
                    InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                    InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or
                    InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            }
            outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or
                EditorInfo.IME_FLAG_NO_EXTRACT_UI or
                EditorInfo.IME_ACTION_NONE or
                EditorInfo.IME_FLAG_NO_ENTER_ACTION
            outAttrs.initialSelStart = Selection.getSelectionStart(buffer)
            outAttrs.initialSelEnd = Selection.getSelectionEnd(buffer)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                outAttrs.setInitialSurroundingText(buffer)
            }
            return Connection(this, generation)
        }

        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (handleEditingKey(event)) return true
            // Everything else reaches the remote through Flutter's key
            // handling, as hardware keys do. Flutter skips events it hands
            // back to the view hierarchy, so this cannot loop.
            return flutterView()?.dispatchKeyEvent(event) ?: super.dispatchKeyEvent(event)
        }
    }

    private inner class Connection(view: View, private val gen: Int) :
        BaseInputConnection(view, true) {
        private var batch = 0

        // Edits made against an older reset go to a scratch copy and are
        // never reported.
        private val stale by lazy { SpannableStringBuilder() }
        private val current get() = gen == generation

        override fun getEditable(): android.text.Editable =
            if (current) buffer else stale

        private fun <T> edit(op: () -> T): T {
            val r = op()
            if (current && batch == 0) report()
            return r
        }

        override fun beginBatchEdit(): Boolean {
            batch++
            return true
        }

        override fun endBatchEdit(): Boolean {
            if (batch > 0) batch--
            if (current && batch == 0) report()
            return batch > 0
        }

        override fun commitText(text: CharSequence?, newCursorPosition: Int) =
            edit { super.commitText(text, newCursorPosition) }

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int) =
            edit { super.setComposingText(text, newCursorPosition) }

        override fun setComposingRegion(start: Int, end: Int) =
            edit { super.setComposingRegion(start, end) }

        override fun finishComposingText() = edit { super.finishComposingText() }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int) =
            edit { super.deleteSurroundingText(beforeLength, afterLength) }

        @RequiresApi(Build.VERSION_CODES.N)
        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int) =
            edit { super.deleteSurroundingTextInCodePoints(beforeLength, afterLength) }

        override fun setSelection(start: Int, end: Int) = edit { super.setSelection(start, end) }

        override fun sendKeyEvent(event: KeyEvent): Boolean =
            if (current) super.sendKeyEvent(event) else false

        override fun performEditorAction(actionCode: Int): Boolean {
            if (!current) return false
            sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
            return true
        }

        override fun performContextMenuAction(id: Int): Boolean {
            if (!current) return false
            when (id) {
                android.R.id.selectAll -> setSelection(0, buffer.length)
                android.R.id.paste, android.R.id.pasteAsPlainText -> {
                    val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE)
                        as ClipboardManager
                    val clip = cm.primaryClip ?: return false
                    if (clip.itemCount == 0) return false
                    val text = clip.getItemAt(0).coerceToText(activity) ?: return false
                    commitText(text, 1)
                }
                else -> return false
            }
            return true
        }

        override fun getExtractedText(request: ExtractedTextRequest?, flags: Int): ExtractedText? {
            if (!current) return null
            return ExtractedText().apply {
                text = buffer.toString()
                startOffset = 0
                partialStartOffset = -1
                partialEndOffset = -1
                selectionStart = Selection.getSelectionStart(buffer)
                selectionEnd = Selection.getSelectionEnd(buffer)
            }
        }
    }
}
