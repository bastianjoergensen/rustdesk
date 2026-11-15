import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A modifier the soft keyboard toolbar latches, or holds for a shortcut.
enum RemoteModifier { ctrl, alt, shift, meta }

/// What pressing a [ToolbarKey] does.
enum ToolbarKeyKind { modifier, fn, key, combo, ctrlAltDel }

/// The two keys every toolbar ends with; they are not part of a layout.
const kToolbarMoreKey = 'more';
const kToolbarHideKey = 'hide';

const _comboPrefix = 'combo:';
const _primary = 'primary';

class _BaseKey {
  const _BaseKey(this.name, this.label, {this.repeat = false});

  /// Legacy key name for `InputModel.inputKey`.
  final String name;
  final String label;
  final bool repeat;
}

final Map<String, _BaseKey> _namedKeys = {
  'esc': const _BaseKey('VK_ESCAPE', 'Esc'),
  'tab': const _BaseKey('VK_TAB', 'Tab'),
  'enter': const _BaseKey('VK_RETURN', 'Enter'),
  'backspace': const _BaseKey('VK_BACK', 'Backspace', repeat: true),
  'del': const _BaseKey('VK_DELETE', 'Del', repeat: true),
  'ins': const _BaseKey('VK_INSERT', 'Ins'),
  'space': const _BaseKey('VK_SPACE', 'Space', repeat: true),
  'home': const _BaseKey('VK_HOME', 'Home'),
  'end': const _BaseKey('VK_END', 'End'),
  'pgup': const _BaseKey('VK_PRIOR', 'PgUp', repeat: true),
  'pgdn': const _BaseKey('VK_NEXT', 'PgDn', repeat: true),
  'left': const _BaseKey('VK_LEFT', 'Left', repeat: true),
  'up': const _BaseKey('VK_UP', 'Up', repeat: true),
  'down': const _BaseKey('VK_DOWN', 'Down', repeat: true),
  'right': const _BaseKey('VK_RIGHT', 'Right', repeat: true),
  for (var i = 1; i <= 12; i++) 'f$i': _BaseKey('VK_F$i', 'F$i'),
  'prtscr': const _BaseKey('VK_SNAPSHOT', 'PrtScr'),
  'pause': const _BaseKey('VK_PAUSE', 'Pause'),
  'scrolllock': const _BaseKey('VK_SCROLL', 'ScrollLock'),
  'menu': const _BaseKey('Apps', 'Menu'),
};

// Keys only offered inside a custom shortcut.
final Map<String, _BaseKey> _charKeys = {
  for (var c = 'a'.codeUnitAt(0); c <= 'z'.codeUnitAt(0); c++)
    String.fromCharCode(c): _BaseKey(
        'VK_${String.fromCharCode(c).toUpperCase()}',
        String.fromCharCode(c).toUpperCase()),
  for (var d = 0; d <= 9; d++) '$d': _BaseKey('VK_$d', '$d'),
  'minus': const _BaseKey('VK_MINUS', '-'),
  'equal': const _BaseKey('VK_PLUS', '='),
  'lbracket': const _BaseKey('VK_LBRACKET', '['),
  'rbracket': const _BaseKey('VK_RBRACKET', ']'),
  'backslash': const _BaseKey('VK_BACKSLASH', '\\'),
  'semicolon': const _BaseKey('VK_SEMICOLON', ';'),
  'quote': const _BaseKey('VK_QUOTE', "'"),
  'comma': const _BaseKey('VK_COMMA', ','),
  'period': const _BaseKey('.', '.'),
  'slash': const _BaseKey('VK_SLASH', '/'),
  'backquote': const _BaseKey('`', '`'),
};

final Map<String, ToolbarKey> _builtIns = {
  for (final m in RemoteModifier.values)
    m.name: ToolbarKey._(m.name, ToolbarKeyKind.modifier, modifier: m),
  'fn': const ToolbarKey._('fn', ToolbarKeyKind.fn, label: 'Fn'),
  for (final e in _namedKeys.entries)
    e.key: ToolbarKey._(e.key, ToolbarKeyKind.key,
        name: e.value.name, label: e.value.label, repeat: e.value.repeat),
  'ctrlaltdel': const ToolbarKey._('ctrlaltdel', ToolbarKeyKind.ctrlAltDel,
      label: 'Ctrl+Alt+Del'),
};

/// A key of the soft keyboard toolbar, stored in a layout by its [id].
///
/// Shortcuts are stored as `combo:` followed by their modifiers and key,
/// joined by `+`, e.g. `combo:ctrl+shift+t`. The `primary` modifier is Ctrl,
/// or Cmd on macOS peers.
class ToolbarKey {
  const ToolbarKey._(
    this.id,
    this.kind, {
    this.name = '',
    this.modifier,
    this.modifiers = const {},
    this.primary = false,
    this.repeat = false,
    String label = '',
  }) : _label = label;

  final String id;
  final ToolbarKeyKind kind;

  /// Legacy key name a [ToolbarKeyKind.key] or [ToolbarKeyKind.combo] sends.
  final String name;

  /// The modifier a [ToolbarKeyKind.modifier] key latches.
  final RemoteModifier? modifier;

  /// Held while a [ToolbarKeyKind.combo] is sent, with [primary].
  final Set<RemoteModifier> modifiers;
  final bool primary;

  /// Held down, the key auto-repeats.
  final bool repeat;
  final String _label;

  static ToolbarKey? parse(String id) {
    final builtIn = _builtIns[id];
    if (builtIn != null) return builtIn;
    if (!id.startsWith(_comboPrefix)) return null;
    final parts = id.substring(_comboPrefix.length).split('+');
    final keyId = parts.removeLast();
    final base = _namedKeys[keyId] ?? _charKeys[keyId];
    if (base == null) return null;
    var primary = false;
    final modifiers = <RemoteModifier>{};
    for (final part in parts) {
      if (part == _primary && !primary) {
        primary = true;
        continue;
      }
      final m = RemoteModifier.values.asNameMap()[part];
      if (m == null || !modifiers.add(m)) return null;
    }
    return ToolbarKey._(
        comboId(modifiers, keyId, primary: primary), ToolbarKeyKind.combo,
        name: base.name,
        modifiers: modifiers,
        primary: primary,
        label: base.label);
  }

  /// The id of the shortcut [keyId] with [modifiers] (and [primary]) held.
  static String comboId(Iterable<RemoteModifier> modifiers, String keyId,
          {bool primary = false}) =>
      _comboPrefix +
      [
        if (primary) _primary,
        for (final m in RemoteModifier.values)
          if (modifiers.contains(m)) m.name,
        keyId,
      ].join('+');

  /// Keys a custom shortcut can end with.
  static List<String> get shortcutKeyIds =>
      [..._charKeys.keys, ..._namedKeys.keys];

  static String shortcutKeyLabel(String keyId) =>
      (_charKeys[keyId] ?? _namedKeys[keyId])?.label ?? keyId;

  static String modifierLabel(RemoteModifier m, {required bool macPeer}) =>
      switch (m) {
        RemoteModifier.ctrl => 'Ctrl',
        RemoteModifier.alt => 'Alt',
        RemoteModifier.shift => 'Shift',
        RemoteModifier.meta => macPeer ? 'Cmd' : 'Win',
      };

  /// The modifiers a [ToolbarKeyKind.combo] holds on the peer.
  Set<RemoteModifier> heldModifiers({required bool macPeer}) {
    final held = {
      ...modifiers,
      if (primary) macPeer ? RemoteModifier.meta : RemoteModifier.ctrl,
    };
    return {
      for (final m in RemoteModifier.values)
        if (held.contains(m)) m
    };
  }

  String label({required bool macPeer}) => switch (kind) {
        ToolbarKeyKind.modifier => modifierLabel(modifier!, macPeer: macPeer),
        ToolbarKeyKind.combo => [
            for (final m in heldModifiers(macPeer: macPeer))
              modifierLabel(m, macPeer: macPeer),
            _label,
          ].join('+'),
        _ => _label,
      };
}

/// Keys the layout editor offers, grouped under a translation key.
final List<(String, List<String>)> kToolbarKeyGroups = [
  ('Modifier keys', ['ctrl', 'alt', 'shift', 'meta', 'fn']),
  (
    'Navigation keys',
    ['left', 'up', 'down', 'right', 'home', 'end', 'pgup', 'pgdn']
  ),
  ('Function keys', [for (var i = 1; i <= 12; i++) 'f$i']),
  (
    'Shortcuts',
    [
      for (final k in ['c', 'v', 'x', 'z', 'y', 'a', 's', 'f'])
        ToolbarKey.comboId(const {}, k, primary: true),
      ToolbarKey.comboId(const {RemoteModifier.alt}, 'tab'),
      ToolbarKey.comboId(const {RemoteModifier.alt}, 'f4'),
      'ctrlaltdel',
    ]
  ),
  (
    'Other',
    [
      'esc',
      'tab',
      'enter',
      'backspace',
      'del',
      'ins',
      'space',
      'prtscr',
      'pause',
      'scrolllock',
      'menu'
    ]
  ),
];

/// Which keys the soft keyboard toolbar shows, row by row, as picked by the
/// user. More and Hide are always added by [toolbarRows].
class KeyboardToolbarLayout {
  /// Keeps known keys only, each once, in at most [maxRows] rows.
  KeyboardToolbarLayout(Iterable<Iterable<String>> rows)
      : rows = _normalize(rows);

  factory KeyboardToolbarLayout.defaults() =>
      KeyboardToolbarLayout(_defaultRows);

  /// Reads the layout option; an empty or unreadable one is the default.
  factory KeyboardToolbarLayout.parse(String option) {
    if (option.isNotEmpty) {
      try {
        final rows = (jsonDecode(option) as Map<String, dynamic>)['rows'];
        return KeyboardToolbarLayout([
          for (final row in rows as List<dynamic>)
            [
              for (final id in row as List<dynamic>)
                if (id is String) id
            ],
        ]);
      } catch (e) {
        debugPrint('Ignoring the soft keyboard toolbar layout: $e');
      }
    }
    return KeyboardToolbarLayout.defaults();
  }

  static const maxRows = 3;

  static const _defaultRows = [
    ['esc', 'ctrl', 'alt', 'meta', 'home', 'up', 'end', 'pgup'],
    ['tab', 'shift', 'fn', 'del', 'left', 'down', 'right', 'pgdn'],
  ];

  // The default rows read oddly as one line, so until the layout is changed,
  // landscape gets this order instead of the rows joined.
  static const _defaultSingleRow = [
    'esc',
    'tab',
    'ctrl',
    'alt',
    'shift',
    'meta',
    'fn',
    'del',
    'home',
    'end',
    'pgup',
    'pgdn',
    'left',
    'up',
    'down',
    'right',
  ];

  final List<List<String>> rows;

  bool get isDefault =>
      rows.length == _defaultRows.length &&
      Iterable<int>.generate(rows.length)
          .every((i) => listEquals(rows[i], _defaultRows[i]));

  bool contains(String id) => rows.any((row) => row.contains(id));

  String toOption() => jsonEncode({'rows': rows});

  /// The keys the toolbar shows, row by row: one row holds everything when
  /// [singleRow], the Fn page swaps all but the modifiers and Fn for F1 to
  /// F12, and More and Hide end the first and the last row.
  List<List<String>> toolbarRows(
      {required bool singleRow, bool fnPage = false}) {
    var shown = singleRow && isDefault
        ? [
            [..._defaultSingleRow]
          ]
        : [
            for (final row in rows)
              if (row.isNotEmpty) [...row]
          ];
    if (fnPage) {
      shown = [
        for (final row in shown) [...row.where(_keptOnFnPage)]
      ];
    }
    if (shown.isEmpty) shown.add([]);
    if (singleRow) shown = [shown.expand((row) => row).toList()];
    if (fnPage) _addFunctionKeys(shown);
    shown.first.add(kToolbarMoreKey);
    shown.last.add(kToolbarHideKey);
    return shown;
  }

  static bool _keptOnFnPage(String id) {
    final kind = ToolbarKey.parse(id)?.kind;
    return kind == ToolbarKeyKind.modifier || kind == ToolbarKeyKind.fn;
  }

  // Fills the rows up with F1 to F12, top first, so that they come out as
  // even as they can, More and Hide included.
  static void _addFunctionKeys(List<List<String>> rows) {
    final total = rows.fold<int>(0, (n, row) => n + row.length) + 12 + 2;
    final perRow = (total / rows.length).ceil();
    var f = 1;
    for (var i = 0; i < rows.length; i++) {
      final last = i == rows.length - 1;
      final fixed = (i == 0 ? 1 : 0) + (last ? 1 : 0);
      while (f <= 12 && (last || rows[i].length + fixed < perRow)) {
        rows[i].add('f${f++}');
      }
    }
  }

  static List<List<String>> _normalize(Iterable<Iterable<String>> rows) {
    final seen = <String>{};
    final out = <List<String>>[];
    for (final row in rows.take(maxRows)) {
      final keys = <String>[];
      for (final id in row) {
        final key = ToolbarKey.parse(id);
        if (key != null && seen.add(key.id)) keys.add(key.id);
      }
      out.add(keys);
    }
    return out;
  }
}
