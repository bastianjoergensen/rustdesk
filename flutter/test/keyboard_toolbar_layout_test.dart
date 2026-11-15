import 'package:flutter_hbb/models/keyboard_toolbar_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolbarKey', () {
    test('built-in keys carry their key name and repeat', () {
      final left = ToolbarKey.parse('left')!;
      expect(left.kind, ToolbarKeyKind.key);
      expect(left.name, 'VK_LEFT');
      expect(left.repeat, isTrue);
      expect(ToolbarKey.parse('f5')!.name, 'VK_F5');
      expect(ToolbarKey.parse('esc')!.repeat, isFalse);
      expect(ToolbarKey.parse('ctrl')!.modifier, RemoteModifier.ctrl);
      expect(ToolbarKey.parse('fn')!.kind, ToolbarKeyKind.fn);
    });

    test('the Win key is Cmd on macOS peers', () {
      expect(ToolbarKey.parse('meta')!.label(macPeer: false), 'Win');
      expect(ToolbarKey.parse('meta')!.label(macPeer: true), 'Cmd');
    });

    test('shortcuts hold their modifiers and label them in order', () {
      final key = ToolbarKey.parse('combo:shift+ctrl+t')!;
      expect(key.id, 'combo:ctrl+shift+t');
      expect(key.name, 'VK_T');
      expect(key.heldModifiers(macPeer: false),
          {RemoteModifier.ctrl, RemoteModifier.shift});
      expect(key.label(macPeer: false), 'Ctrl+Shift+T');
    });

    test('the primary modifier is Ctrl, or Cmd on macOS peers', () {
      final copy = ToolbarKey.parse('combo:primary+c')!;
      expect(copy.label(macPeer: false), 'Ctrl+C');
      expect(copy.label(macPeer: true), 'Cmd+C');
      expect(copy.heldModifiers(macPeer: true), {RemoteModifier.meta});
    });

    test('a shortcut may be a plain key', () {
      final key = ToolbarKey.parse('combo:period')!;
      expect(key.name, '.');
      expect(key.heldModifiers(macPeer: false), isEmpty);
      expect(key.label(macPeer: false), '.');
    });

    test('malformed ids are rejected', () {
      for (final id in [
        '',
        'more',
        'hide',
        'nope',
        'combo:',
        'combo:ctrl',
        'combo:ctrl+nope',
        'combo:ctrl+ctrl+c',
        'combo:primary+primary+c',
        'combo:hyper+c',
      ]) {
        expect(ToolbarKey.parse(id), isNull, reason: id);
      }
    });

    test('every offered key parses, and so does every shortcut key', () {
      for (final (_, ids) in kToolbarKeyGroups) {
        for (final id in ids) {
          expect(ToolbarKey.parse(id), isNotNull, reason: id);
        }
      }
      for (final keyId in ToolbarKey.shortcutKeyIds) {
        final id = ToolbarKey.comboId({RemoteModifier.alt}, keyId);
        expect(ToolbarKey.parse(id)?.id, id, reason: id);
      }
    });
  });

  group('KeyboardToolbarLayout', () {
    test('an empty or unreadable option is the default layout', () {
      for (final option in ['', 'x', '{"rows": 3}', '[]']) {
        expect(KeyboardToolbarLayout.parse(option).isDefault, isTrue,
            reason: option);
      }
    });

    test('round-trips through the option', () {
      final layout = KeyboardToolbarLayout([
        ['esc', 'combo:ctrl+shift+t'],
        [],
        ['f5'],
      ]);
      final back = KeyboardToolbarLayout.parse(layout.toOption());
      expect(back.rows, layout.rows);
      expect(back.isDefault, isFalse);
    });

    test('keeps known keys once, in at most three rows', () {
      final layout = KeyboardToolbarLayout([
        ['esc', 'nope', 'esc', 'combo:shift+ctrl+t'],
        ['combo:ctrl+shift+t', 'tab', 'more'],
        ['f1'],
        ['f2'],
      ]);
      expect(layout.rows, [
        ['esc', 'combo:ctrl+shift+t'],
        ['tab'],
        ['f1'],
      ]);
    });

    test('More ends the first row and Hide the last one', () {
      final layout = KeyboardToolbarLayout([
        ['esc'],
        ['tab'],
        ['del'],
      ]);
      expect(layout.toolbarRows(singleRow: false), [
        ['esc', kToolbarMoreKey],
        ['tab'],
        ['del', kToolbarHideKey],
      ]);
      expect(KeyboardToolbarLayout([[]]).toolbarRows(singleRow: false), [
        [kToolbarMoreKey, kToolbarHideKey],
      ]);
    });

    test('empty rows are not shown', () {
      final layout = KeyboardToolbarLayout([
        [],
        ['esc'],
        [],
      ]);
      expect(layout.toolbarRows(singleRow: false), [
        ['esc', kToolbarMoreKey, kToolbarHideKey],
      ]);
    });

    test('landscape joins a changed layout into one row', () {
      final layout = KeyboardToolbarLayout([
        ['esc', 'ctrl'],
        ['tab', 'fn'],
      ]);
      expect(layout.toolbarRows(singleRow: true), [
        ['esc', 'ctrl', 'tab', 'fn', kToolbarMoreKey, kToolbarHideKey],
      ]);
    });

    test('landscape keeps its own order for the default layout', () {
      final row =
          KeyboardToolbarLayout.defaults().toolbarRows(singleRow: true).single;
      expect(row.take(8),
          ['esc', 'tab', 'ctrl', 'alt', 'shift', 'meta', 'fn', 'del']);
      expect(row.length, 18);
    });

    test('the Fn page keeps modifiers and spreads F1 to F12 evenly', () {
      final rows = KeyboardToolbarLayout.defaults()
          .toolbarRows(singleRow: false, fnPage: true);
      expect(rows, [
        ['ctrl', 'alt', 'meta', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'more'],
        ['shift', 'fn', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12', 'hide'],
      ]);
    });

    test('the Fn page keeps the number of rows', () {
      final layout = KeyboardToolbarLayout([
        ['esc', 'tab', 'ctrl', 'alt', 'shift', 'meta', 'fn', 'del'],
        ['home', 'end', 'pgup', 'pgdn'],
      ]);
      final rows = layout.toolbarRows(singleRow: false, fnPage: true);
      expect(rows.length, 2);
      expect(rows.expand((r) => r).where((id) => id.startsWith('f')).length,
          13); // F1 to F12, and Fn
      expect((rows[0].length - rows[1].length).abs(), lessThanOrEqualTo(1));
    });

    test('the Fn page in landscape is one row', () {
      final row = KeyboardToolbarLayout.defaults()
          .toolbarRows(singleRow: true, fnPage: true)
          .single;
      expect(row.first, 'ctrl');
      expect(row.sublist(row.length - 2), [kToolbarMoreKey, kToolbarHideKey]);
      expect(row.where((id) => RegExp(r'^f\d+$').hasMatch(id)).length, 12);
    });
  });
}
