import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/soft_keyboard_sync.dart';

/// Minimal IME: edits the buffer the way Android input methods do through an
/// InputConnection (composing text, commits, surrounding-text deletes).
class FakeIme {
  FakeIme(this.value);

  TextEditingValue value;

  int get caret => value.selection.baseOffset;

  TextRange get _target {
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return value.composing;
    }
    return TextRange(start: value.selection.start, end: value.selection.end);
  }

  TextEditingValue _replace(TextRange r, String s, {bool compose = false}) {
    final text = value.text.replaceRange(r.start, r.end, s);
    final end = r.start + s.length;
    return value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: end),
      composing:
          compose ? TextRange(start: r.start, end: end) : TextRange.empty,
    );
  }

  TextEditingValue compose(String s) => _replace(_target, s, compose: true);

  TextEditingValue commit(String s) => _replace(_target, s);

  TextEditingValue composeRegion(int start, int end) =>
      value = value.copyWith(composing: TextRange(start: start, end: end));

  TextEditingValue deleteBefore(int n) =>
      _replace(TextRange(start: caret - n, end: caret), '');

  TextEditingValue deleteAfter(int n) =>
      _replace(TextRange(start: caret, end: caret + n), '');

  TextEditingValue moveBy(int d) => value = value.copyWith(
      selection: TextSelection.collapsed(offset: caret + d),
      composing: TextRange.empty);

  TextEditingValue select(int base, int extent) => value = value.copyWith(
      selection: TextSelection(baseOffset: base, extentOffset: extent),
      composing: TextRange.empty);
}

/// A remote text box that applies the ops like a desktop editor would.
class FakeRemote {
  FakeRemote(String before, String after)
      : chars = [...before.characters, ...after.characters],
        caret = before.characters.length;

  final List<String> chars;
  int caret;
  int? anchor;

  String get text => chars.join();

  bool _deleteSelection() {
    final a = anchor;
    anchor = null;
    if (a == null || a == caret) return false;
    final lo = a < caret ? a : caret;
    final hi = a < caret ? caret : a;
    chars.removeRange(lo, hi);
    caret = lo;
    return true;
  }

  void _insert(String s) {
    _deleteSelection();
    final c = s.characters.toList();
    chars.insertAll(caret, c);
    caret += c.length;
  }

  void _move(int d, bool shift) {
    if (!shift && anchor != null && anchor != caret) {
      final a = anchor!;
      caret = d < 0 ? (a < caret ? a : caret) : (a > caret ? a : caret);
      anchor = null;
      return;
    }
    if (shift) {
      anchor ??= caret;
    } else {
      anchor = null;
    }
    caret = (caret + d).clamp(0, chars.length);
  }

  void apply(List<SoftKeyOp> ops) {
    for (final op in ops) {
      switch (op) {
        case SoftKeyText(:final text):
          _insert(text);
        case SoftKeySelectAll():
          anchor = 0;
          caret = chars.length;
        case SoftKeyPress(:final key, :final count, :final shift):
          for (var i = 0; i < count; i++) {
            switch (key) {
              case kSoftKeyBackspace:
                if (!_deleteSelection() && caret > 0) {
                  chars.removeAt(--caret);
                }
              case kSoftKeyDelete:
                if (!_deleteSelection() && caret < chars.length) {
                  chars.removeAt(caret);
                }
              case kSoftKeyLeft:
                _move(-1, shift);
              case kSoftKeyRight:
                _move(1, shift);
              case kSoftKeyEnter:
                _insert('\n');
              case kSoftKeyTab:
                _insert('\t');
              default:
                fail('unexpected key $key');
            }
          }
      }
    }
  }
}

class Harness {
  Harness({String before = 'PRE', String after = 'POST'})
      : remote = FakeRemote(before, after) {
    ime = FakeIme(sync.reset());
  }

  final sync = SoftKeyboardSync();
  final FakeRemote remote;
  late final FakeIme ime;
  final log = <SoftKeyOp>[];

  List<SoftKeyOp> edit(TextEditingValue v) {
    final ops = sync.update(v);
    log.addAll(ops);
    remote.apply(ops);
    final padded = sync.maybeRepad();
    if (sync.needsReset) {
      ime.value = sync.reset();
    } else if (padded != null) {
      ime.value = padded;
    }
    return ops;
  }

  List<SoftKeyOp> editStale(TextEditingValue v) {
    final ops = sync.updateStale(v);
    log.addAll(ops);
    remote.apply(ops);
    return ops;
  }

  void typeWord(String word) {
    for (var i = 1; i <= word.length; i++) {
      edit(ime.compose(word.substring(0, i)));
    }
  }
}

void main() {
  test('typing with composing text goes out as characters', () {
    final h = Harness();
    h.typeWord('hello');
    h.edit(h.ime.commit('hello '));
    h.typeWord('world');
    expect(h.remote.text, 'PREhello worldPOST');
    expect(h.log.whereType<SoftKeyPress>(), isEmpty);
  });

  test('picking a suggestion replaces only the difference', () {
    final h = Harness();
    h.typeWord('helo');
    final ops = h.edit(h.ime.commit('hello '));
    expect(ops, [
      const SoftKeyPress(kSoftKeyBackspace),
      const SoftKeyText('lo '),
    ]);
    expect(h.remote.text, 'PREhello POST');
  });

  test('autocorrect after space rewrites the previous word', () {
    final h = Harness(before: '', after: '');
    h.typeWord('teh');
    h.edit(h.ime.commit('teh '));
    final start = h.ime.caret - 4;
    h.edit(h.ime.composeRegion(start, start + 4));
    h.edit(h.ime.commit('the '));
    expect(h.remote.text, 'the ');
  });

  test('same-length replacement is not dropped', () {
    final h = Harness(before: '', after: '');
    h.typeWord('abc');
    h.edit(h.ime.compose('abd'));
    expect(h.remote.text, 'abd');
  });

  test('backspace past typed text deletes remote text one by one', () {
    final h = Harness();
    h.edit(h.ime.commit('ab'));
    for (var i = 0; i < 4; i++) {
      h.edit(h.ime.deleteBefore(1));
    }
    expect(h.remote.text, 'PPOST');
  });

  test('word delete over unknown text deletes a single character', () {
    final h = Harness();
    h.edit(h.ime.commit('hi '));
    final ops = h.edit(h.ime.deleteBefore(3 + 20));
    expect(ops, [const SoftKeyPress(kSoftKeyBackspace, 4)]);
    expect(h.remote.text, 'PRPOST');
  });

  test('word delete inside typed text deletes exactly that word', () {
    final h = Harness();
    h.edit(h.ime.commit('one two'));
    h.edit(h.ime.deleteBefore(3));
    expect(h.remote.text, 'PREone POST');
  });

  test('backspace keeps working after many deletes (re-padding)', () {
    final h = Harness(before: 'x' * 300, after: '');
    for (var i = 0; i < 200; i++) {
      h.edit(h.ime.deleteBefore(1));
    }
    expect(h.remote.text, 'x' * 100);
    expect(h.ime.caret, greaterThanOrEqualTo(h.sync.lowWater));
  });

  test('IME cursor control moves the remote caret', () {
    final h = Harness();
    h.edit(h.ime.commit('abc'));
    h.edit(h.ime.moveBy(-2));
    h.edit(h.ime.commit('X'));
    expect(h.remote.text, 'PREaXbcPOST');
    h.edit(h.ime.moveBy(4));
    h.edit(h.ime.commit('Z'));
    expect(h.remote.text, 'PREaXbcPOZST');
  });

  test('moving left into unknown text and typing', () {
    final h = Harness();
    h.edit(h.ime.moveBy(-2));
    h.edit(h.ime.commit('_'));
    expect(h.remote.text, 'P_REPOST');
  });

  test('forward delete maps to Delete', () {
    final h = Harness(before: '', after: '');
    h.edit(h.ime.commit('abc'));
    h.edit(h.ime.moveBy(-1));
    final ops = h.edit(h.ime.deleteAfter(1));
    expect(ops, [const SoftKeyPress(kSoftKeyDelete)]);
    expect(h.remote.text, 'ab');
  });

  test('repeated characters resolve at the caret', () {
    final h = Harness(before: '', after: '');
    h.edit(h.ime.commit('aa'));
    h.edit(h.ime.moveBy(-1));
    final ops = h.edit(h.ime.commit('a'));
    expect(ops, [const SoftKeyText('a')]);
    expect(h.remote.text, 'aaa');
  });

  test('emoji is typed and deleted as one character', () {
    final h = Harness();
    h.edit(h.ime.commit('😀'));
    expect(h.remote.text, 'PRE😀POST');
    final ops = h.edit(h.ime.deleteBefore(2));
    expect(ops, [const SoftKeyPress(kSoftKeyBackspace)]);
    expect(h.remote.text, 'PREPOST');
  });

  test('newlines and tabs become key presses', () {
    final h = Harness(before: '', after: '');
    final ops = h.edit(h.ime.commit('a\nb\tc'));
    expect(ops, [
      const SoftKeyText('a'),
      const SoftKeyPress(kSoftKeyEnter),
      const SoftKeyText('b'),
      const SoftKeyPress(kSoftKeyTab),
      const SoftKeyText('c'),
    ]);
  });

  test('japanese composition converts in place', () {
    final h = Harness(before: '', after: '');
    h.typeWord('にほん');
    h.edit(h.ime.commit('日本'));
    expect(h.remote.text, '日本');
  });

  test('korean syllable composition', () {
    final h = Harness(before: '', after: '');
    h.edit(h.ime.compose('ㅎ'));
    h.edit(h.ime.compose('하'));
    h.edit(h.ime.compose('한'));
    h.edit(h.ime.commit('한'));
    expect(h.remote.text, '한');
  });

  test('select then type replaces the selection', () {
    final h = Harness();
    h.edit(h.ime.commit('hello'));
    final end = h.ime.caret;
    h.edit(h.ime.select(end, end - 2));
    h.edit(h.ime.commit('p'));
    expect(h.remote.text, 'PREhelpPOST');
  });

  test('select all then delete clears the remote with one backspace', () {
    final h = Harness();
    h.edit(h.ime.commit('abc'));
    h.edit(h.ime.select(0, h.ime.value.text.length));
    expect(h.log.last, const SoftKeySelectAll());
    final ops = h.edit(h.ime.commit(''));
    expect(ops, [const SoftKeyPress(kSoftKeyBackspace)]);
    expect(h.remote.text, '');
    // The buffer is reset so typing keeps working.
    h.edit(h.ime.commit('x'));
    expect(h.remote.text, 'x');
  });

  test('long typing trims the buffer and keeps context', () {
    final h = Harness(before: '', after: '');
    final words = List.filled(400, 'word ').join();
    for (final w in words.split(' ').where((w) => w.isNotEmpty)) {
      h.edit(h.ime.commit('$w '));
    }
    expect(h.remote.text, words);
    expect(h.ime.value.text.length, lessThanOrEqualTo(h.sync.maxLength + 8));
    expect(h.ime.value.text, contains('word word'));
  });

  test('random IME edits keep the remote identical to the buffer', () {
    const alphabet = ['a', 'b', 'a', 'é', 'Ω', '😀', ' '];
    for (var seed = 0; seed < 200; seed++) {
      final rnd = Random(seed);
      final h = Harness(before: '', after: '');
      String word() => List.generate(
              1 + rnd.nextInt(4), (_) => alphabet[rnd.nextInt(alphabet.length)])
          .join();
      // The typed text never contains the sentinels, so the buffer minus its
      // sentinel runs is exactly what the remote must hold.
      String known() => h.ime.value.text
          .replaceAll(SoftKeyboardSync.sentinel, '')
          .replaceAll(SoftKeyboardSync.leadEnd, '');
      int lead() => h.sync.leadLength;
      List<int> stops() {
        final t = known();
        final out = [0];
        var i = 0;
        for (final ch in t.characters) {
          i += ch.length;
          out.add(i);
        }
        return out;
      }

      for (var step = 0; step < 60; step++) {
        final composing =
            h.ime.value.composing.isValid && !h.ime.value.composing.isCollapsed;
        final caret = h.ime.caret - lead();
        final s = stops();
        switch (rnd.nextInt(6)) {
          case 0:
            h.edit(h.ime.compose(word()));
          case 1:
            h.edit(h.ime.commit('${word()} '));
          case 2:
            final before = s.where((x) => x < caret).toList();
            if (before.isEmpty || composing) break;
            h.edit(
                h.ime.deleteBefore(caret - before[rnd.nextInt(before.length)]));
          case 3:
            if (composing) break;
            final to = s[rnd.nextInt(s.length)];
            h.edit(h.ime.moveBy(to - caret));
          case 4:
            if (composing || s.length < 2) break;
            final a = s[rnd.nextInt(s.length)];
            final b = s[rnd.nextInt(s.length)];
            if (a == b) break;
            h.edit(h.ime.select(a + lead(), b + lead()));
            h.edit(h.ime.commit(rnd.nextBool() ? word() : ''));
          case 5:
            if (composing) {
              h.edit(h.ime
                  .commit(h.ime.value.composing.textInside(h.ime.value.text)));
            }
        }
        expect(h.remote.text, known(), reason: 'seed $seed step $step');
        final remoteCaret = h.remote.chars.take(h.remote.caret).join().length;
        expect(remoteCaret, h.ime.caret - lead(),
            reason: 'seed $seed step $step');
      }
    }
  });

  test('an edit made before the IME saw a reset is diffed against the old buffer',
      () {
    final h = Harness(before: '', after: '');
    h.edit(h.ime.commit('abc '));
    final old = h.ime.value;
    h.sync.reset(context: 'abc ');
    h.ime.value = old;
    h.editStale(h.ime.commit('d'));
    expect(h.remote.text, 'abc d');
    // The restarted IME continues on the new buffer.
    h.ime.value = h.sync.value;
    h.edit(h.ime.commit('e'));
    expect(h.remote.text, 'abc de');
  });

  test('an autocorrection made before a reset fixes the right word', () {
    final h = Harness(before: '', after: '');
    h.typeWord('teh');
    final old = h.ime.value;
    h.sync.reset();
    h.ime.value = old;
    h.editStale(h.ime.commit('the '));
    expect(h.remote.text, 'the ');
    h.sync.clearStale();
    expect(h.sync.updateStale(h.ime.commit('x')), isEmpty);
  });

  test('typing right after a reset is not mistaken for a stale edit', () {
    final h = Harness(before: '', after: '');
    h.edit(h.ime.commit('ls'));
    h.remote.apply(const [SoftKeyPress(kSoftKeyEnter)]);
    h.ime.value = h.sync.reset();
    h.typeWord('l');
    h.typeWord('ls');
    expect(h.remote.text, 'ls\nls');
  });

  test('the caret never looks like the start of a line after a reset', () {
    String beforeCaret(Harness h) =>
        h.ime.value.text.substring(h.ime.caret - 1, h.ime.caret);
    final h = Harness();
    expect(beforeCaret(h), SoftKeyboardSync.leadEnd);
    h.edit(h.ime.commit('ls\n'));
    h.ime.value = h.sync.reset();
    expect(beforeCaret(h), SoftKeyboardSync.leadEnd);
    h.edit(h.ime.commit('cd '));
    expect(h.remote.text, 'PREls\ncd POST');
  });

  test('backspace over remote text puts the lead end back', () {
    final h = Harness();
    h.edit(h.ime.deleteBefore(1));
    h.edit(h.ime.deleteBefore(1));
    expect(h.remote.text, 'PPOST');
    expect(h.ime.value.text.substring(h.ime.caret - 1, h.ime.caret),
        SoftKeyboardSync.leadEnd);
    h.typeWord('ok');
    expect(h.remote.text, 'PokPOST');
  });

  test('an edit racing the lead end coming back is applied once', () {
    final h = Harness();
    final old = h.ime.deleteBefore(1);
    h.edit(old);
    expect(h.sync.value, isNot(old));
    // The IME types on the buffer it had before it is restarted.
    h.ime.value = old;
    h.editStale(h.ime.commit('a'));
    expect(h.remote.text, 'PRaPOST');
  });

  test('textOps splits text for sending', () {
    expect(SoftKeyboardSync.textOps('a\r\n\nb'), [
      const SoftKeyText('a'),
      const SoftKeyPress(kSoftKeyEnter, 2),
      const SoftKeyText('b'),
    ]);
  });
}
