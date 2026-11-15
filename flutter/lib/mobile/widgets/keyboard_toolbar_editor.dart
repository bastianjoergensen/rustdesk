import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/remote_keyboard.dart';
import 'package:flutter_hbb/models/keyboard_toolbar_layout.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Picks the keys of the soft keyboard toolbar, their order and their rows.
/// Every change is saved right away.
class KeyboardToolbarEditor extends StatefulWidget {
  const KeyboardToolbarEditor({super.key, required this.macPeer});

  /// Labels the keys for a macOS peer, e.g. Cmd instead of Win.
  final bool macPeer;

  @override
  State<KeyboardToolbarEditor> createState() => _KeyboardToolbarEditorState();
}

// A row header (row set) or a key (id set) of the editor's list.
typedef _Item = ({int? row, String? id});

class _KeyboardToolbarEditorState extends State<KeyboardToolbarEditor> {
  late List<List<String>> _rows;

  @override
  void initState() {
    super.initState();
    _rows = _editable(KeyboardToolbarLayout.parse(
        bind.mainGetLocalOption(key: kOptionSoftKeyboardToolbar)));
  }

  static List<List<String>> _editable(KeyboardToolbarLayout layout) {
    final rows = [
      for (final row in layout.rows) [...row]
    ];
    if (rows.isEmpty) rows.add([]);
    return rows;
  }

  void _save(List<List<String>> rows) {
    setState(() => _rows = rows);
    bind.mainSetLocalOption(
        key: kOptionSoftKeyboardToolbar,
        value: KeyboardToolbarLayout(rows).toOption());
  }

  List<List<String>> _copy() => [
        for (final row in _rows) [...row]
      ];

  // Row headers and keys in one list, so keys can be dragged between rows.
  List<_Item> get _items => [
        for (var row = 0; row < _rows.length; row++) ...[
          (row: row, id: null),
          for (final id in _rows[row]) (row: null, id: id),
        ],
      ];

  void _onReorder(int from, int to) {
    final items = _items;
    if (to > from) to--;
    final moved = items.removeAt(from);
    // Nothing goes above the first row's header.
    items.insert(max(1, to), moved);
    final rows = <List<String>>[];
    for (final item in items) {
      final id = item.id;
      if (id == null) {
        rows.add([]);
      } else {
        rows.last.add(id);
      }
    }
    _save(rows);
  }

  Future<void> _addKey(int row) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _KeyPicker(
        macPeer: widget.macPeer,
        used: {for (final row in _rows) ...row},
      ),
    );
    if (id == null || !mounted) return;
    final rows = _copy();
    // A custom shortcut may already be in another row; a key is there once.
    for (final keys in rows) {
      keys.remove(id);
    }
    rows[row].add(id);
    _save(rows);
  }

  void _removeKey(String id) => _save([
        for (final row in _rows) [...row.where((k) => k != id)]
      ]);

  // The keys of a deleted row move to the row above, or below for the first.
  void _deleteRow(int row) {
    final rows = _copy();
    final keys = rows.removeAt(row);
    if (row == 0) {
      rows.first.insertAll(0, keys);
    } else {
      rows[row - 1].addAll(keys);
    }
    _save(rows);
  }

  Future<void> _reset() async {
    final reset = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(translate('Reset to default')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(translate('Cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(translate('OK'))),
        ],
      ),
    );
    if (reset != true || !mounted) return;
    bind.mainSetLocalOption(key: kOptionSoftKeyboardToolbar, value: '');
    setState(() => _rows = _editable(KeyboardToolbarLayout.defaults()));
  }

  @override
  Widget build(BuildContext context) {
    final layout = KeyboardToolbarLayout(_rows);
    final items = _items;
    Widget preview(IconData icon, {required bool singleRow}) => Row(
          children: [
            SizedBox(width: 32, child: Icon(icon, size: 18)),
            Expanded(
              child: KeyboardToolbarPreview(
                  layout: layout,
                  macPeer: widget.macPeer,
                  singleRow: singleRow),
            ),
          ],
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(translate('Customize keys')),
        actions: [
          IconButton(
            tooltip: translate('Reset to default'),
            icon: const Icon(Icons.restart_alt),
            onPressed: _reset,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            preview(Icons.stay_current_portrait, singleRow: false),
            const SizedBox(height: 6),
            preview(Icons.stay_current_landscape, singleRow: true),
            const SizedBox(height: 4),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorder: _onReorder,
                itemBuilder: (context, i) {
                  final item = items[i];
                  final row = item.row;
                  return row != null ? _header(row) : _keyTile(item.id!, i);
                },
                footer: _rows.length < KeyboardToolbarLayout.maxRows
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => _save([..._copy(), []]),
                            icon: const Icon(Icons.add),
                            label: Text(translate('Add row')),
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(int row) => ListTile(
        key: ValueKey('row-$row'),
        title: Text('${translate('Row')} ${row + 1}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_rows.length > 1)
              IconButton(
                tooltip: translate('Delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteRow(row),
              ),
            IconButton(
              tooltip: translate('Add'),
              icon: const Icon(Icons.add),
              onPressed: () => _addKey(row),
            ),
          ],
        ),
      );

  Widget _keyTile(String id, int index) {
    final face = toolbarKeyFace(id, macPeer: widget.macPeer);
    return ListTile(
      key: ValueKey(id),
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_handle),
      ),
      title: Row(
        children: [
          if (face.icon != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(face.icon, size: 20),
            ),
          Flexible(child: Text(face.label)),
        ],
      ),
      trailing: IconButton(
        tooltip: translate('Remove'),
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: () => _removeKey(id),
      ),
    );
  }
}

/// The keys that can be added, by group; keys already in the layout are
/// greyed out. Pops with the picked key's id.
class _KeyPicker extends StatelessWidget {
  const _KeyPicker({required this.macPeer, required this.used});

  final bool macPeer;
  final Set<String> used;

  @override
  Widget build(BuildContext context) {
    Widget chip(String id) {
      final face = toolbarKeyFace(id, macPeer: macPeer);
      return ActionChip(
        avatar: face.icon == null ? null : Icon(face.icon, size: 18),
        label: Text(face.label),
        onPressed: used.contains(id) ? null : () => Navigator.pop(context, id),
      );
    }

    final custom = ActionChip(
      avatar: const Icon(Icons.add, size: 18),
      label: Text(translate('Custom shortcut')),
      onPressed: () async {
        final id = await _pickShortcut(context, macPeer);
        if (id != null && context.mounted) Navigator.pop(context, id);
      },
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (title, ids) in kToolbarKeyGroups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(translate(title),
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in ids) chip(id),
                    if (title == 'Shortcuts') custom,
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets the user put together a shortcut from modifiers and one key; pops
/// with its id.
Future<String?> _pickShortcut(BuildContext context, bool macPeer) {
  final held = <RemoteModifier>{};
  String? keyId;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final picked = keyId;
      final label = [
        for (final m in RemoteModifier.values)
          if (held.contains(m)) ToolbarKey.modifierLabel(m, macPeer: macPeer),
        picked == null ? '…' : ToolbarKey.shortcutKeyLabel(picked),
      ].join('+');
      return AlertDialog(
        title: Text(translate('Custom shortcut')),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in RemoteModifier.values)
                      FilterChip(
                        label:
                            Text(ToolbarKey.modifierLabel(m, macPeer: macPeer)),
                        selected: held.contains(m),
                        onSelected: (on) => setState(() {
                          if (on) {
                            held.add(m);
                          } else {
                            held.remove(m);
                          }
                        }),
                      ),
                  ],
                ),
                const Divider(height: 24),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final k in ToolbarKey.shortcutKeyIds)
                      ChoiceChip(
                        label: Text(ToolbarKey.shortcutKeyLabel(k)),
                        selected: picked == k,
                        onSelected: (_) => setState(() => keyId = k),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(translate('Cancel')),
          ),
          TextButton(
            onPressed: picked == null
                ? null
                : () =>
                    Navigator.pop(context, ToolbarKey.comboId(held, picked)),
            child: Text(translate('OK')),
          ),
        ],
      );
    }),
  );
}
