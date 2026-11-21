import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/keyboard_toolbar_layout.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/soft_keyboard_sync.dart';
import 'package:flutter_hbb/mobile/widgets/typing_spot.dart';

/// `once` applies to the next key only, `locked` stays until tapped again.
enum ModifierLatch { off, once, locked }

/// Soft-keyboard typing for the mobile remote page: owns the hidden IME
/// buffer, mirrors its edits to the remote and keeps the sticky modifier and
/// panel state of [RemoteKeyboardToolbar].
class RemoteKeyboardController extends ChangeNotifier {
  RemoteKeyboardController(this.ffi, {required this.focusNode})
      : _rawInput =
            bind.mainGetLocalOption(key: kOptionSoftKeyboardRawInput) == 'Y',
        _layout = _loadLayout() {
    _owner = this;
    _channel.setMethodCallHandler(_onNativeCall);
    focusNode.addListener(_onFocusChanged);
    ffi.inputModel.onRemoteMouseDown = _onRemoteMouseDown;
  }

  // The native view the IME types into, see RemoteIme.kt.
  static const _channel = MethodChannel('rustdesk/remote_ime');
  static RemoteKeyboardController? _owner;

  static KeyboardToolbarLayout _loadLayout() => KeyboardToolbarLayout.parse(
      bind.mainGetLocalOption(key: kOptionSoftKeyboardToolbar));

  final FFI ffi;

  /// Focus node of [RemoteKeyboardField], owned by the page.
  final FocusNode focusNode;
  final composerText = TextEditingController();
  final composerFocus = FocusNode(debugLabel: 'RemoteKeyboardComposer');
  late final typingSpot = TypingSpotKeeper(ffi);

  final _sync = SoftKeyboardSync();
  final _latches = {
    for (final m in RemoteModifier.values) m: ModifierLatch.off,
  };
  final _usedWhileLatched = <RemoteModifier>{};
  // Modifiers on because of the toolbar, as opposed to InputModel state set
  // elsewhere.
  final _latchedHere = <RemoteModifier>{};
  bool _composerOpen = false;
  bool _moreOpen = false;
  bool _fnPage = false;
  bool _disposed = false;
  Timer? _resetTimer;
  // Each buffer pushed to the native view; IME edits come back tagged with
  // the one they were made on.
  int _generation = 0;
  int? _staleGeneration;

  InputModel get _input => ffi.inputModel;

  // Each bind call runs on a pool thread, so back-to-back calls can reach
  // the peer out of order: a correction's backspaces landed after the text
  // that replaced it. Every key goes out only after the previous one.
  Future<void> _queue = Future.value();

  void _enqueue(Future<void> Function() send) {
    // Windows apps fed a correction's keys back to back typed some of them
    // as blanks or repeats ("dog" came out "ggg"), so bursts are paced.
    _queue = _queue
        .then((_) => send())
        .then((_) => Future.delayed(const Duration(milliseconds: 30)))
        .catchError(
            (Object e) => debugPrint('RemoteKeyboard: send failed: $e'));
  }

  void _key(String name) {
    final input = _input;
    if (!input.keyboardPerm || input.isViewCamera) return;
    final alt = input.alt, ctrl = input.ctrl, shift = input.shift;
    final command = input.command;
    _enqueue(() => bind.sessionInputKey(
        sessionId: ffi.sessionId,
        name: name,
        down: false,
        press: true,
        alt: alt,
        ctrl: ctrl,
        shift: shift,
        command: command));
  }

  void _string(String s) =>
      _enqueue(() => bind.sessionInputString(sessionId: ffi.sessionId, value: s));

  bool get isMacPeer => ffi.ffiModel.pi.platform == kPeerPlatformMacOS;
  bool get composerOpen => _composerOpen;
  bool get moreOpen => _moreOpen;
  bool get fnPage => _fnPage;

  /// The keys the toolbar shows, as picked in the layout editor.
  KeyboardToolbarLayout get layout => _layout;
  KeyboardToolbarLayout _layout;

  /// Plain keys: no autocorrect, suggestions or auto-capitalization, for
  /// terminals and passwords.
  bool get rawInput => _rawInput;
  bool _rawInput;
  bool get _canType =>
      _input.keyboardInputAllowed && _input.keyboardPerm && !_input.isViewOnly;

  /// Starts a fresh IME buffer. Call whenever the remote caret may have moved
  /// on its own, so IME corrections never reach back into stale text.
  void reset() {
    if (_disposed) return;
    _resetTimer?.cancel();
    _push(_sync.reset());
  }

  // Hands [value] to the native view, which restarts the IME on it.
  void _push(TextEditingValue value) {
    _staleGeneration = _generation;
    final generation = ++_generation;
    _channel.invokeMethod('reset', {
      'generation': generation,
      'text': value.text,
      'base': value.selection.baseOffset,
      'extent': value.selection.extentOffset,
      'raw': _rawInput,
    }).then((_) {
      // The IME's edits on the old buffer were all reported before this
      // reply.
      if (_generation == generation) {
        _staleGeneration = null;
        _sync.clearStale();
      }
    }, onError: (e) => debugPrint('Soft keyboard reset failed: $e'));
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (_disposed || call.method != 'state') return;
    final a = call.arguments as Map;
    final value = TextEditingValue(
      text: a['text'] as String,
      selection: TextSelection(
          baseOffset: a['base'] as int, extentOffset: a['extent'] as int),
      composing: TextRange(
          start: a['composingStart'] as int, end: a['composingEnd'] as int),
    );
    final generation = a['generation'] as int;
    if (generation == _generation) {
      _onImeEdit(value);
    } else if (generation == _staleGeneration) {
      _send(_sync.updateStale(value));
    }
  }

  void _onFocusChanged() {
    if (_disposed) return;
    if (focusNode.hasFocus) {
      // After this frame's microtasks, where Flutter hides the keyboard of a
      // text field that just lost focus.
      Timer.run(() {
        if (!_disposed && focusNode.hasFocus) _channel.invokeMethod('focus');
      });
    } else {
      // The send-text row takes the keyboard over.
      _channel.invokeMethod('blur', {'hide': !_composerOpen});
    }
  }

  // Deferred a little, so IME follow-ups of the same action (SwiftKey sends
  // Enter first and commits the composing word right after) land on the old
  // buffer instead of racing the reset.
  void _scheduleReset() {
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 80), reset);
  }

  void _later(VoidCallback fn) => scheduleMicrotask(() {
        if (!_disposed) fn();
      });

  void _onImeEdit(TextEditingValue value) {
    if (value == _sync.value) return;
    final ops = _sync.update(value);
    _send(ops);
    if (_sync.needsReset) {
      _later(reset);
    } else {
      _later(() {
        final padded = _sync.maybeRepad();
        if (padded != null) _push(padded);
      });
    }
  }

  void _send(List<SoftKeyOp> ops) {
    if (ops.isEmpty || !_canType) return;
    // Some IMEs send Shift key events along with their text, which leaves
    // Shift set in InputModel: letters got capitalized at random and toolbar
    // arrows selected text. The IME already applied its own case, so only a
    // toolbar Shift survives text from it.
    if (_input.shift && !_latchedHere.contains(RemoteModifier.shift)) {
      _input.shift = false;
      notifyListeners();
    }
    final shortcut = _input.ctrl || _input.alt || _input.command;
    for (final op in ops) {
      switch (op) {
        case SoftKeyText(text: final s):
          if (shortcut) {
            for (final ch in s.characters) {
              _key(ch);
            }
          } else {
            _type(_input.shift ? s.toUpperCase() : s);
          }
        case SoftKeyPress(:final key, :final count, :final shift):
          final wasShift = _input.shift;
          if (shift) _input.shift = true;
          for (var i = 0; i < count; i++) {
            _key(key);
          }
          _input.shift = wasShift;
        case SoftKeySelectAll():
          _withModifier(isMacPeer ? RemoteModifier.meta : RemoteModifier.ctrl,
              () => _key('VK_A'));
      }
    }
    _consumeOnce();
    // A shortcut changed the remote in ways the buffer cannot follow, and
    // Enter usually submits.
    final entered =
        ops.any((op) => op is SoftKeyPress && op.key == kSoftKeyEnter);
    if (shortcut || entered) _scheduleReset();
  }

  void _type(String s) {
    // One key per character: a Windows peer sometimes typed a whole string
    // sent at once (an autocorrected word) as blanks.
    for (final ch in s.characters) {
      if (ch.length == 1) {
        _key(ch == ' ' ? 'VK_SPACE' : ch);
      } else {
        _string(ch);
      }
    }
  }

  /// Types [s] on the remote as-is, ignoring latched modifiers.
  void sendText(String s, {bool enter = false}) {
    if (!_canType) return;
    final saved = {for (final m in RemoteModifier.values) m: _flag(m)};
    for (final m in RemoteModifier.values) {
      _setFlag(m, false);
    }
    for (final op in SoftKeyboardSync.textOps(s)) {
      switch (op) {
        case SoftKeyText(text: final t):
          _type(t);
        case SoftKeyPress(:final key, :final count):
          for (var i = 0; i < count; i++) {
            _key(key);
          }
        case SoftKeySelectAll():
          break;
      }
    }
    if (enter) _key(kSoftKeyEnter);
    saved.forEach(_setFlag);
    _scheduleReset();
  }

  /// A toolbar key: sent with the latched modifiers, which it then consumes.
  void pressKey(String name) {
    if (!_canType) return;
    _key(name);
    _consumeOnce();
    _scheduleReset();
  }

  /// A shortcut key: its own modifiers are held on top of the latched ones.
  void pressShortcut(ToolbarKey key) {
    if (!_canType) return;
    final held = key.heldModifiers(macPeer: isMacPeer);
    final saved = {for (final m in held) m: _flag(m)};
    for (final m in held) {
      _setFlag(m, true);
    }
    _key(key.name);
    saved.forEach(_setFlag);
    _consumeOnce();
    _scheduleReset();
  }

  void pressCtrlAltDel() {
    if (!_canType) return;
    bind.sessionCtrlAltDel(sessionId: ffi.sessionId);
    _scheduleReset();
  }

  /// Picks up a layout saved by the layout editor.
  void reloadLayout() {
    _layout = _loadLayout();
    if (!_layout.contains('fn')) _fnPage = false;
    notifyListeners();
  }

  /// Key events the IME or a hardware keyboard sends to the hidden field.
  /// They reach the remote through the page's key handler; this only keeps
  /// the modifier latches and the buffer in step with them.
  void onFieldKeyEvent(KeyEvent e) {
    final key = e.logicalKey;
    if (_modifierKeys.contains(key)) return;
    if (e is KeyUpEvent) _later(_consumeOnce);
    if (e is KeyDownEvent && _navigationKeys.contains(key)) _scheduleReset();
  }

  // Only a click can move the remote caret. Resetting on every touch, pans
  // and zooms included, cut words in half, and the IME then capitalized
  // the rest as a new sentence.
  void _onRemoteMouseDown() => _scheduleReset();

  ModifierLatch latchOf(RemoteModifier m) {
    final on = _flag(m);
    var latch = _latches[m]!;
    // Modifiers may also be toggled elsewhere (key help tools, hardware keys).
    if (!on) {
      latch = ModifierLatch.off;
      _latchedHere.remove(m);
    } else if (latch == ModifierLatch.off) {
      latch = ModifierLatch.locked;
    }
    _latches[m] = latch;
    return latch;
  }

  void tapModifier(RemoteModifier m) {
    final latch = latchOf(m);
    if (latch == ModifierLatch.off) {
      _usedWhileLatched.remove(m);
      _setLatch(m, ModifierLatch.once);
      return;
    }
    _setLatch(m, ModifierLatch.off);
    // Win tapped on and off with nothing in between: press it on its own,
    // e.g. to open the Start menu.
    if (m == RemoteModifier.meta &&
        latch == ModifierLatch.once &&
        !_usedWhileLatched.contains(m) &&
        !isMacPeer &&
        _canType) {
      _key('Meta');
    }
  }

  void lockModifier(RemoteModifier m) {
    _usedWhileLatched.remove(m);
    _setLatch(m, ModifierLatch.locked);
  }

  /// Drops one-shot modifiers, e.g. when the keyboard closes.
  void releaseOnce() {
    for (final m in RemoteModifier.values) {
      if (latchOf(m) == ModifierLatch.once) {
        _latches[m] = ModifierLatch.off;
        _latchedHere.remove(m);
        _setFlag(m, false);
      }
    }
  }

  void _consumeOnce() {
    var changed = false;
    for (final m in RemoteModifier.values) {
      final latch = latchOf(m);
      if (latch != ModifierLatch.off) _usedWhileLatched.add(m);
      if (latch == ModifierLatch.once) {
        _latches[m] = ModifierLatch.off;
        _latchedHere.remove(m);
        _setFlag(m, false);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void _setLatch(RemoteModifier m, ModifierLatch latch) {
    _latches[m] = latch;
    if (latch == ModifierLatch.off) {
      _latchedHere.remove(m);
    } else {
      _latchedHere.add(m);
    }
    _setFlag(m, latch != ModifierLatch.off);
    notifyListeners();
  }

  void _withModifier(RemoteModifier m, VoidCallback fn) {
    final old = _flag(m);
    _setFlag(m, true);
    fn();
    _setFlag(m, old);
  }

  bool _flag(RemoteModifier m) => switch (m) {
        RemoteModifier.ctrl => _input.ctrl,
        RemoteModifier.alt => _input.alt,
        RemoteModifier.shift => _input.shift,
        RemoteModifier.meta => _input.command,
      };

  void _setFlag(RemoteModifier m, bool on) {
    switch (m) {
      case RemoteModifier.ctrl:
        _input.ctrl = on;
      case RemoteModifier.alt:
        _input.alt = on;
      case RemoteModifier.shift:
        _input.shift = on;
      case RemoteModifier.meta:
        _input.command = on;
    }
  }

  void toggleRawInput() {
    _rawInput = !_rawInput;
    bind.mainSetLocalOption(
        key: kOptionSoftKeyboardRawInput, value: _rawInput ? 'Y' : '');
    // The restart that comes with the reset applies the new keyboard type.
    reset();
    notifyListeners();
  }

  void toggleFnPage() {
    _fnPage = !_fnPage;
    notifyListeners();
  }

  void toggleMore() {
    _moreOpen = !_moreOpen;
    notifyListeners();
  }

  void openComposer() {
    _composerOpen = true;
    _moreOpen = false;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && _composerOpen) composerFocus.requestFocus();
    });
  }

  /// Closes the send-text row; [refocus] hands the IME back to the hidden
  /// field so typing goes live to the remote again.
  void closeComposer({bool refocus = true}) {
    if (!_composerOpen) return;
    _composerOpen = false;
    notifyListeners();
    if (refocus) {
      reset();
      focusNode.requestFocus();
    }
  }

  void submitComposer({required bool enter}) {
    final s = composerText.text;
    if (s.isEmpty && !enter) return;
    sendText(s, enter: enter);
    composerText.clear();
  }

  /// Called when the toolbar goes away with the keyboard.
  void onToolbarClosed() {
    _composerOpen = false;
    _moreOpen = false;
    releaseOnce();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_input.onRemoteMouseDown == _onRemoteMouseDown) {
      _input.onRemoteMouseDown = null;
    }
    _resetTimer?.cancel();
    focusNode.removeListener(_onFocusChanged);
    if (_owner == this) {
      _owner = null;
      _channel.setMethodCallHandler(null);
      _channel.invokeMethod('blur', {'hide': true});
    }
    composerText.dispose();
    composerFocus.dispose();
    typingSpot.dispose();
    super.dispose();
  }

  static final _modifierKeys = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  static final _navigationKeys = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
  };
}

/// Holds Flutter's focus while the soft keyboard types into the native view,
/// so the key events that view passes on reach the page's key handling.
class RemoteKeyboardField extends StatelessWidget {
  const RemoteKeyboardField({super.key, required this.controller});

  final RemoteKeyboardController controller;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: controller.focusNode,
      autofocus: true,
      onKeyEvent: (_, e) {
        controller.onFieldKeyEvent(e);
        return KeyEventResult.ignored;
      },
      child: const SizedBox.shrink(),
    );
  }
}

/// Extra keys shown right above the soft keyboard: sticky modifiers, keys
/// phone keyboards lack (with auto-repeat), F-keys, a send-text row and
/// clipboard typing.
class RemoteKeyboardToolbar extends StatefulWidget {
  const RemoteKeyboardToolbar({
    super.key,
    required this.controller,
    required this.onHideKeyboard,
    this.onCustomize,
  });

  final RemoteKeyboardController controller;
  final VoidCallback onHideKeyboard;

  /// Opens the layout editor; without it the toolbar offers no editing.
  final VoidCallback? onCustomize;

  @override
  State<RemoteKeyboardToolbar> createState() => _RemoteKeyboardToolbarState();
}

class _RemoteKeyboardToolbarState extends State<RemoteKeyboardToolbar> {
  static const _background = Color(0xF2141619);

  final _boxKey = GlobalKey();
  Rect? _blockedRect;

  RemoteKeyboardController get c => widget.controller;
  CursorModel get _cursor => c.ffi.cursorModel;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    c.typingSpot.keyboardShown();
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    c.onToolbarClosed();
    c.typingSpot.keyboardHidden();
    final rect = _blockedRect;
    if (rect != null) _cursor.removeBlockedRect(rect);
    c.ffi.canvasModel.mobileCanvasHeight = null;
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // The image may use the remote view above the toolbar. It is measured here
  // rather than derived from the window, whose metrics cannot tell what the
  // keyboard, the status bar and the page leave to the view. Only the view's
  // size changes: the picture stays where it is on the screen.
  void _updateCanvasHeight(RenderStack stack, Size toolbarSize) {
    final canvas = c.ffi.canvasModel;
    final height = stack.size.height - toolbarSize.height;
    if (height <= 0 || canvas.mobileCanvasHeight == height) return;
    canvas.mobileCanvasHeight = height;
    canvas.updateSize();
    c.typingSpot.viewHeightChanged(height);
  }

  // Touches on the toolbar must not reach the remote screen underneath.
  void _updateBlockedRect() {
    if (!mounted) return;
    final box = _boxKey.currentContext?.findRenderObject();
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    if (box is! RenderBox || !box.hasSize || stack == null) return;
    _updateCanvasHeight(stack, box.size);
    final rect = stack.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
    if (rect == _blockedRect) return;
    final old = _blockedRect;
    if (old != null) _cursor.removeBlockedRect(old);
    _cursor.addBlockedRect(rect);
    _blockedRect = rect;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateBlockedRect());
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Material(
      key: _boxKey,
      color: _background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.composerOpen) _composer(),
            if (c.moreOpen) _moreRow(),
            ..._keyRows(landscape),
          ],
        ),
      ),
    );
  }

  List<Widget> _keyRows(bool singleRow) => [
        for (final row
            in c.layout.toolbarRows(singleRow: singleRow, fnPage: c.fnPage))
          _keyRow([for (final id in row) _keyFor(id)]),
      ];

  Widget _keyFor(String id) {
    final face = toolbarKeyFace(id, macPeer: c.isMacPeer);
    Widget plain(VoidCallback onTap,
            {bool repeat = false, bool active = false}) =>
        _Key(
          key: ValueKey(id),
          label: face.label,
          icon: face.icon,
          repeat: repeat,
          active: active,
          onTap: onTap,
        );
    if (id == kToolbarMoreKey) return plain(c.toggleMore, active: c.moreOpen);
    if (id == kToolbarHideKey) return plain(widget.onHideKeyboard);
    final key = ToolbarKey.parse(id);
    if (key == null) return const SizedBox.shrink();
    return switch (key.kind) {
      ToolbarKeyKind.modifier => _Key(
          key: ValueKey(id),
          label: face.label,
          latch: c.latchOf(key.modifier!),
          onTap: () => c.tapModifier(key.modifier!),
          onLongPress: () => c.lockModifier(key.modifier!),
        ),
      ToolbarKeyKind.fn => plain(c.toggleFnPage, active: c.fnPage),
      ToolbarKeyKind.key =>
        plain(() => c.pressKey(key.name), repeat: key.repeat),
      ToolbarKeyKind.combo => plain(() => c.pressShortcut(key)),
      ToolbarKeyKind.ctrlAltDel => plain(c.pressCtrlAltDel),
    };
  }

  Widget _moreRow() {
    final ffiModel = c.ffi.ffiModel;
    final pi = ffiModel.pi;
    final isWinOrLinux = pi.platform == kPeerPlatformWindows ||
        pi.platform == kPeerPlatformLinux;
    void keyAction(String name) => c.pressKey(name);
    final actions = <(String, IconData?, VoidCallback)>[
      if (widget.onCustomize case final onCustomize?)
        (translate('Customize keys'), Icons.tune, onCustomize),
      (translate('Send text'), Icons.edit_note, c.openComposer),
      (
        translate('Autocorrect and suggestions'),
        c.rawInput ? Icons.check_box_outline_blank : Icons.check_box,
        c.toggleRawInput
      ),
      (
        translate('Send clipboard keystrokes'),
        Icons.content_paste,
        _typeClipboard
      ),
      if (ffiModel.keyboard &&
          (pi.platform == kPeerPlatformLinux || pi.sasEnabled))
        (
          translate('Insert Ctrl + Alt + Del'),
          null,
          () {
            bind.sessionCtrlAltDel(sessionId: c.ffi.sessionId);
            c.toggleMore();
          }
        ),
      ('Ins', null, () => keyAction('VK_INSERT')),
      if (isWinOrLinux) ('PrtScr', null, () => keyAction('VK_SNAPSHOT')),
      if (isWinOrLinux) ('Pause', null, () => keyAction('VK_PAUSE')),
      if (isWinOrLinux) ('ScrollLock', null, () => keyAction('VK_SCROLL')),
      if (isWinOrLinux) ('Menu', null, () => keyAction('Apps')),
    ];
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        children: [
          for (final (label, icon, onTap) in actions)
            Padding(
              padding: const EdgeInsets.all(2),
              child: ActionChip(
                avatar: icon == null
                    ? null
                    : Icon(icon, size: 18, color: Colors.white),
                label: Text(label),
                labelStyle: const TextStyle(color: Colors.white, fontSize: 13),
                backgroundColor: _Key.keyColor,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
                visualDensity: VisualDensity.compact,
                onPressed: onTap,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _typeClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final s = data?.text;
    if (!mounted || s == null || s.isEmpty) return;
    c.sendText(s);
    if (c.moreOpen) c.toggleMore();
  }

  Widget _composer() {
    final hint = translate('Send text');
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 0, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            // Keep the composer's own key events (Backspace, Enter, arrows)
            // away from the remote; they belong to this text field.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, __) => KeyEventResult.skipRemainingHandlers,
              child: TextField(
                controller: c.composerText,
                focusNode: c.composerFocus,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: hint,
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: _Key.keyColor,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: translate('Send'),
            icon: const Icon(Icons.send, color: Colors.white),
            onPressed: () => c.submitComposer(enter: false),
          ),
          IconButton(
            tooltip: '${translate('Send')} + Enter',
            icon: const Icon(Icons.keyboard_return, color: Colors.white),
            onPressed: () => c.submitComposer(enter: true),
          ),
          IconButton(
            tooltip: translate('Close'),
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: c.closeComposer,
          ),
        ],
      ),
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({
    super.key,
    this.label = '',
    this.icon,
    required this.onTap,
    this.onLongPress,
    this.repeat = false,
    this.latch = ModifierLatch.off,
    this.active = false,
  });

  static const keyColor = Color(0xFF2B2F36);
  static const pressedColor = Color(0xFF4A505A);

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool repeat;
  final ModifierLatch latch;
  final bool active;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;
  bool _longPressed = false;
  // A drag, e.g. scrolling a row too long for the screen, is not a press.
  bool _dragged = false;
  Offset _downAt = Offset.zero;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Keys act on pointer events rather than taps: no gesture-arena delay, and
  // held keys auto-repeat like on a hardware keyboard.
  void _onDown(PointerDownEvent e) {
    HapticFeedback.selectionClick();
    _longPressed = false;
    _dragged = false;
    _downAt = e.position;
    _timer?.cancel();
    setState(() => _down = true);
    if (widget.repeat) {
      widget.onTap();
      _timer = Timer(const Duration(milliseconds: 400), () {
        _timer = Timer.periodic(
            const Duration(milliseconds: 45), (_) => widget.onTap());
      });
    } else if (widget.onLongPress != null) {
      _timer = Timer(const Duration(milliseconds: 450), () {
        _longPressed = true;
        HapticFeedback.mediumImpact();
        widget.onLongPress!();
      });
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (_dragged || (e.position - _downAt).distance <= kTouchSlop) return;
    _dragged = true;
    _timer?.cancel();
    setState(() => _down = false);
  }

  void _onUp(PointerUpEvent _) {
    _timer?.cancel();
    if (!widget.repeat && !_longPressed && !_dragged) widget.onTap();
    if (mounted) setState(() => _down = false);
  }

  void _onCancel(PointerCancelEvent _) {
    _timer?.cancel();
    if (mounted) setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    const accent = MyTheme.accent;
    var color = _down ? _Key.pressedColor : _Key.keyColor;
    BoxBorder? border;
    final locked = widget.latch == ModifierLatch.locked;
    if (locked) {
      color = accent;
    } else if (widget.latch == ModifierLatch.once || widget.active) {
      color = Color.alphaBlend(accent.withOpacity(0.35), color);
      border = Border.all(color: accent, width: 1.2);
    }
    final Widget face = widget.icon != null
        ? Icon(widget.icon, size: 22, color: Colors.white)
        : FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.label,
              maxLines: 1,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          );
    return Semantics(
      button: true,
      toggled:
          widget.onLongPress != null ? widget.latch != ModifierLatch.off : null,
      label: widget.label,
      excludeSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: color,
              border: border,
              borderRadius: BorderRadius.circular(6),
            ),
            child: locked
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      face,
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        width: 14,
                        height: 2,
                        color: Colors.white,
                      ),
                    ],
                  )
                : face,
          ),
        ),
      ),
    );
  }
}

const _keyIcons = {
  'left': Icons.keyboard_arrow_left,
  'up': Icons.keyboard_arrow_up,
  'down': Icons.keyboard_arrow_down,
  'right': Icons.keyboard_arrow_right,
  'backspace': Icons.backspace_outlined,
  'enter': Icons.keyboard_return,
  'space': Icons.space_bar,
};

/// The label and the icon of the toolbar key [id].
({String label, IconData? icon}) toolbarKeyFace(String id,
        {required bool macPeer}) =>
    switch (id) {
      kToolbarMoreKey => (label: translate('More'), icon: Icons.more_horiz),
      kToolbarHideKey => (
          label: translate('Close'),
          icon: Icons.keyboard_hide_outlined
        ),
      _ => (
          label: ToolbarKey.parse(id)?.label(macPeer: macPeer) ?? id,
          icon: _keyIcons[id]
        ),
    };

const _minKeyWidth = 36.0;

// The keys share the row down to a minimum width; a row with more keys than
// fit scrolls sideways instead.
Widget _keyRow(List<Widget> keys) => LayoutBuilder(
      builder: (context, constraints) =>
          keys.length * _minKeyWidth <= constraints.maxWidth
              ? Row(children: [for (final k in keys) Expanded(child: k)])
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final k in keys)
                      SizedBox(width: _minKeyWidth, child: k)
                  ]),
                ),
    );

/// How the toolbar shows [layout], for the layout editor. The keys do
/// nothing; a row too long for the screen still scrolls.
class KeyboardToolbarPreview extends StatelessWidget {
  const KeyboardToolbarPreview({
    super.key,
    required this.layout,
    required this.macPeer,
    this.singleRow = false,
  });

  final KeyboardToolbarLayout layout;
  final bool macPeer;
  final bool singleRow;

  @override
  Widget build(BuildContext context) {
    Widget key(String id) {
      final face = toolbarKeyFace(id, macPeer: macPeer);
      return IgnorePointer(
        child: _Key(
            key: ValueKey(id),
            label: face.label,
            icon: face.icon,
            onTap: () {}),
      );
    }

    return Container(
      color: _RemoteKeyboardToolbarState._background,
      padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in layout.toolbarRows(singleRow: singleRow))
            _keyRow([for (final id in row) key(id)]),
        ],
      ),
    );
  }
}
