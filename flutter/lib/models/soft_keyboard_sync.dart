import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

/// One remote-side effect of an edit made by the soft keyboard (IME) in the
/// hidden text field used to capture typing on mobile.
sealed class SoftKeyOp {
  const SoftKeyOp();
}

/// Types [text] on the remote. Never contains '\n' or '\t'.
final class SoftKeyText extends SoftKeyOp {
  final String text;
  const SoftKeyText(this.text);

  @override
  bool operator ==(Object other) => other is SoftKeyText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'SoftKeyText(${text.runes.toList()})';
}

/// Presses the legacy key [key] (a `sessionInputKey` name) [count] times,
/// with Shift held when [shift] is set (used to mirror selections).
final class SoftKeyPress extends SoftKeyOp {
  final String key;
  final int count;
  final bool shift;
  const SoftKeyPress(this.key, [this.count = 1, this.shift = false]);

  @override
  bool operator ==(Object other) =>
      other is SoftKeyPress &&
      other.key == key &&
      other.count == count &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(key, count, shift);

  @override
  String toString() => 'SoftKeyPress($key x$count${shift ? ' +shift' : ''})';
}

/// Selects everything on the remote (Ctrl+A / Cmd+A).
final class SoftKeySelectAll extends SoftKeyOp {
  const SoftKeySelectAll();

  @override
  bool operator ==(Object other) => other is SoftKeySelectAll;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'SoftKeySelectAll()';
}

const kSoftKeyBackspace = 'VK_BACK';
const kSoftKeyDelete = 'VK_DELETE';
const kSoftKeyLeft = 'VK_LEFT';
const kSoftKeyRight = 'VK_RIGHT';
const kSoftKeyEnter = 'VK_RETURN';
const kSoftKeyTab = 'VK_TAB';

/// Mirrors the hidden IME buffer to the remote as key strokes.
///
/// The buffer is `lead + typed + trail`, where `lead`/`trail` are runs of
/// [sentinel] standing in for remote text we do not know. They keep the IME
/// reporting Backspace and cursor moves at the edges, and keep the caret away
/// from the start of the field so IMEs never see an empty editor.
///
/// Every IME edit is diffed against the previous buffer, anchored on the old
/// caret, and turned into the minimal Backspace/Delete/arrow/text sequence
/// that reproduces it on the remote. This handles composing text, autocorrect,
/// suggestion picks, swipe typing, word deletion and IME cursor control.
class SoftKeyboardSync {
  SoftKeyboardSync({
    this.padding = 64,
    this.lowWater = 16,
    this.keepContext = 48,
    this.maxLength = 2048,
    this.maxRepeat = 256,
  });

  /// A separator for every IME, so typed words never merge with the padding.
  static const sentinel = '\n';

  /// Ends the leading run in place of its last sentinel. With a line break
  /// right before the caret IMEs see the start of a line and capitalize the
  /// first word typed after every reset, i.e. after every Enter or click,
  /// whatever the remote text there is. A plain symbol avoids that and is
  /// never taken as part of a word; spaces and invisible characters are not
  /// enough, SwiftKey skips them.
  static const leadEnd = '|';

  /// Sentinel characters on each side after a reset.
  final int padding;

  /// Re-pad once fewer than this many characters remain on either side of
  /// the caret.
  final int lowWater;

  /// Typed characters before the caret kept as IME context when re-padding.
  final int keepContext;

  /// Trim the buffer once it grows beyond this many characters.
  final int maxLength;

  /// Upper bound for one repeated key press, so a runaway IME edit can never
  /// flood the remote.
  final int maxRepeat;

  TextEditingValue _value = TextEditingValue.empty;
  int _lead = 0;
  int _trail = 0;
  bool _remoteSelectAll = false;
  bool _needsReset = false;

  // State before the last reset, for IME edits reported before the IME saw
  // the reset, see [updateStale].
  _SyncState? _stale;

  TextEditingValue get value => _value;

  /// Length of the leading sentinel run.
  @visibleForTesting
  int get leadLength => _lead;

  /// The remote state could not be mirrored or the IME is behind; the
  /// caller should [reset] (again).
  bool get needsReset => _needsReset;

  bool get isComposing =>
      _value.composing.isValid && !_value.composing.isCollapsed;

  /// Resets the buffer to sentinels around the caret. [context] is text the
  /// remote already has right before its caret; it only feeds IME
  /// suggestions and is never sent.
  TextEditingValue reset({String context = ''}) =>
      _reset(context: context, lead: padding);

  TextEditingValue _reset({required String context, required int lead}) {
    final fresh = TextEditingValue(
      text: sentinel * (lead - 1) + leadEnd + context + sentinel * padding,
      selection: TextSelection.collapsed(offset: lead + context.length),
    );
    if (_value.text.isNotEmpty) _stale = _save();
    _lead = lead;
    _trail = padding;
    _remoteSelectAll = false;
    _needsReset = false;
    _value = fresh;
    return _value;
  }

  /// Call once no more edits based on the buffer before the last reset can
  /// arrive.
  void clearStale() => _stale = null;

  /// Returns a trimmed/re-padded buffer to push to the field, or null when
  /// the current one is still fine. Only done between words so the IME
  /// composition is never disturbed.
  TextEditingValue? maybeRepad() {
    final v = _value;
    if (isComposing || !v.selection.isValid || !v.selection.isCollapsed) {
      return null;
    }
    final caret = v.selection.baseOffset;
    final after = v.text.length - caret;
    // A Backspace over remote text took the lead end with it. The new lead
    // is far longer or shorter than the one left, so that deleting the lead
    // end again can never produce the buffer from before this reset, which
    // update() would take for a late IME edit and drop.
    if (caret == _lead &&
        caret >= lowWater &&
        after >= lowWater &&
        v.text[caret - 1] != leadEnd) {
      return _reset(
          context: '',
          lead: _lead < padding * 3 ~/ 2 ? padding * 2 : padding);
    }
    if (caret >= lowWater && after >= lowWater && v.text.length <= maxLength) {
      return null;
    }
    var start = max(_lead, caret - keepContext);
    if (start < caret &&
        start > 0 &&
        _isLowSurrogate(v.text.codeUnitAt(start))) {
      start++;
    }
    return reset(context: start < caret ? v.text.substring(start, caret) : '');
  }

  /// Diffs [next] against the last buffer and returns the remote key ops.
  List<SoftKeyOp> update(TextEditingValue next) => _diff(next);

  /// Diffs an IME edit made on the buffer from before the last reset, which
  /// the IME had not seen yet, against that buffer. The current buffer is
  /// left as it is: the IME is restarted on it.
  List<SoftKeyOp> updateStale(TextEditingValue next) {
    final stale = _stale;
    if (stale == null) return const [];
    final current = _save();
    _restore(stale);
    final ops = _diff(next);
    _stale = _save();
    _restore(current);
    return ops;
  }

  List<SoftKeyOp> _diff(TextEditingValue next) {
    final prev = _value;
    if (!next.selection.isValid) {
      final caret = min(prev.selection.baseOffset, next.text.length);
      next = next.copyWith(selection: TextSelection.collapsed(offset: caret));
    }
    _value = next;
    final ops = <SoftKeyOp>[];
    if (prev.text == next.text) {
      _selectionOps(prev.selection, next.selection, next.text, ops);
    } else {
      _editOps(prev, next, ops);
    }
    return _merge(ops);
  }

  _SyncState _save() =>
      _SyncState(_value, _lead, _trail, _remoteSelectAll, _needsReset);

  void _restore(_SyncState s) {
    _value = s.value;
    _lead = s.lead;
    _trail = s.trail;
    _remoteSelectAll = s.remoteSelectAll;
    _needsReset = s.needsReset;
  }

  void _selectionOps(
      TextSelection from, TextSelection to, String text, List<SoftKeyOp> ops) {
    if (from.baseOffset == to.baseOffset &&
        from.extentOffset == to.extentOffset) {
      return;
    }
    if (!to.isCollapsed && to.start == 0 && to.end == text.length) {
      ops.add(const SoftKeySelectAll());
      _remoteSelectAll = true;
      return;
    }
    if (from.isCollapsed) {
      _arrows(text, from.baseOffset, to.baseOffset, ops);
      _arrows(text, to.baseOffset, to.extentOffset, ops, shift: true);
      return;
    }
    if (_remoteSelectAll) {
      // Positions inside a remote Ctrl+A selection are unknown.
      _remoteSelectAll = false;
      ops.add(const SoftKeyPress(kSoftKeyRight));
      _needsReset = true;
      return;
    }
    if (to.isCollapsed) {
      if (to.baseOffset == from.start) {
        ops.add(const SoftKeyPress(kSoftKeyLeft));
      } else {
        ops.add(const SoftKeyPress(kSoftKeyRight));
        _arrows(text, from.end, to.baseOffset, ops);
      }
    } else if (to.baseOffset == from.baseOffset) {
      _arrows(text, from.extentOffset, to.extentOffset, ops, shift: true);
    } else {
      ops.add(const SoftKeyPress(kSoftKeyRight));
      _arrows(text, from.end, to.baseOffset, ops);
      _arrows(text, to.baseOffset, to.extentOffset, ops, shift: true);
    }
  }

  void _editOps(
      TextEditingValue prev, TextEditingValue next, List<SoftKeyOp> ops) {
    final o = prev.text;
    final n = next.text;
    final sel = prev.selection;

    // Anchor the edit window on the old and new carets, so runs of repeated
    // characters resolve to where the IME actually edited.
    final nextSel = next.selection;
    var p = min(_commonPrefix(o, n), min(sel.start, nextSel.start));
    if (p > 0 && _isHighSurrogate(o.codeUnitAt(p - 1))) p--;
    final maxSuffix = min(min(o.length, n.length) - p,
        min(o.length - sel.end, n.length - nextSel.end));
    var s = _commonSuffix(o, n, max(0, maxSuffix));
    if (s > 0 && _isLowSurrogate(o.codeUnitAt(o.length - s))) s--;
    final a = p;
    final b = o.length - s;
    final inserted = n.substring(p, n.length - s);

    var caret = sel.baseOffset;
    if (!sel.isCollapsed) {
      final wasSelectAll = _remoteSelectAll;
      _remoteSelectAll = false;
      if (a == sel.start && b == sel.end) {
        // Typing over or deleting the selection, which the remote mirrors.
        if (inserted.isEmpty) ops.add(const SoftKeyPress(kSoftKeyBackspace));
        _text(inserted, ops);
        _updateSentinels(o, a, b, inserted);
        _moveTo(n, a + inserted.length, next.selection, ops);
        if (wasSelectAll) _needsReset = true;
        return;
      }
      if (wasSelectAll) {
        ops.add(const SoftKeyPress(kSoftKeyRight));
        _needsReset = true;
        return;
      }
      ops.add(const SoftKeyPress(kSoftKeyRight));
      caret = sel.end;
    }

    if (b <= caret) {
      _arrows(o, caret, b, ops);
      _deleteBefore(o, a, b, ops);
    } else if (a >= caret) {
      _arrows(o, caret, a, ops);
      _deleteAfter(o, a, b, ops);
    } else {
      _deleteBefore(o, a, caret, ops);
      _deleteAfter(o, caret, b, ops);
    }
    _text(inserted, ops);
    _updateSentinels(o, a, b, inserted);
    _moveTo(n, a + inserted.length, next.selection, ops);
  }

  void _deleteBefore(String o, int a, int b, List<SoftKeyOp> ops) {
    if (a >= b) return;
    final unknownEnd = min(b, _lead);
    final unknown = max(0, unknownEnd - a);
    final known = _graphemes(o, max(a, unknownEnd), b);
    // A multi-character deletion inside the unknown run comes from IME word
    // deletion over the sentinels; the remote text there is unknown, so
    // delete one character instead of guessing a word length.
    _press(kSoftKeyBackspace, known + min(unknown, 1), ops);
  }

  void _deleteAfter(String o, int a, int b, List<SoftKeyOp> ops) {
    if (a >= b) return;
    final unknownStart = max(a, o.length - _trail);
    final unknown = max(0, b - unknownStart);
    final known = _graphemes(o, a, min(b, unknownStart));
    _press(kSoftKeyDelete, known + min(unknown, 1), ops);
  }

  void _updateSentinels(String o, int a, int b, String inserted) {
    final trailStart = o.length - _trail;
    if (inserted.isEmpty && b <= _lead) {
      _lead -= b - a;
    } else {
      _lead = min(_lead, a);
    }
    if (inserted.isEmpty && a >= trailStart) {
      _trail -= b - a;
    } else {
      _trail = min(_trail, o.length - max(b, trailStart));
    }
  }

  void _moveTo(String text, int from, TextSelection to, List<SoftKeyOp> ops) {
    _arrows(text, from, to.baseOffset, ops);
    _arrows(text, to.baseOffset, to.extentOffset, ops, shift: true);
  }

  void _arrows(String text, int from, int to, List<SoftKeyOp> ops,
      {bool shift = false}) {
    if (from == to) return;
    final lo = max(0, min(from, to));
    final hi = min(text.length, max(from, to));
    final key = to < from ? kSoftKeyLeft : kSoftKeyRight;
    _press(key, max(1, _graphemes(text, lo, hi)), ops, shift: shift);
  }

  void _text(String text, List<SoftKeyOp> ops) => ops.addAll(textOps(text));

  /// Splits [text] into typed runs and Enter/Tab presses, which most remotes
  /// do not accept as characters.
  static List<SoftKeyOp> textOps(String text) {
    final ops = <SoftKeyOp>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        ops.add(SoftKeyText(buf.toString()));
        buf.clear();
      }
    }

    for (final ch in text.characters) {
      if (ch == '\n' || ch == '\r\n' || ch == '\r') {
        flush();
        ops.add(const SoftKeyPress(kSoftKeyEnter));
      } else if (ch == '\t') {
        flush();
        ops.add(const SoftKeyPress(kSoftKeyTab));
      } else {
        buf.write(ch);
      }
    }
    flush();
    return _merge(ops);
  }

  void _press(String key, int count, List<SoftKeyOp> ops,
      {bool shift = false}) {
    if (count <= 0) return;
    ops.add(SoftKeyPress(key, min(count, maxRepeat), shift));
  }

  static List<SoftKeyOp> _merge(List<SoftKeyOp> ops) {
    final out = <SoftKeyOp>[];
    for (final op in ops) {
      final last = out.isEmpty ? null : out.last;
      if (op is SoftKeyPress &&
          last is SoftKeyPress &&
          last.key == op.key &&
          last.shift == op.shift) {
        out[out.length - 1] =
            SoftKeyPress(op.key, last.count + op.count, op.shift);
      } else {
        out.add(op);
      }
    }
    return out;
  }

  static int _graphemes(String text, int start, int end) =>
      start >= end ? 0 : text.substring(start, end).characters.length;

  static int _commonPrefix(String a, String b) {
    final n = min(a.length, b.length);
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _commonSuffix(String a, String b, int limit) {
    var i = 0;
    while (i < limit &&
        a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
      i++;
    }
    return i;
  }

  static bool _isHighSurrogate(int c) => c >= 0xD800 && c <= 0xDBFF;
  static bool _isLowSurrogate(int c) => c >= 0xDC00 && c <= 0xDFFF;
}

class _SyncState {
  final TextEditingValue value;
  final int lead;
  final int trail;
  final bool remoteSelectAll;
  final bool needsReset;
  const _SyncState(
      this.value, this.lead, this.trail, this.remoteSelectAll, this.needsReset);
}
