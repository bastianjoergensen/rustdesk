import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/quick_share.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// Lets the user pick phone files and send them to [toDir] on the PC, its
/// Downloads folder by default.
Future<List<int>> pickAndSendToPeer(QuickShare share, {String? toDir}) async {
  gFFI.ffiModel.beginAndroidDocumentPicker();
  List<dynamic>? picked;
  try {
    picked = await gFFI
        .invokeMethodWithResult<List<dynamic>>(AndroidChannel.kPickImportFiles);
  } catch (e) {
    debugPrint('QuickShare: picker failed: $e');
  } finally {
    gFFI.ffiModel.endAndroidDocumentPicker();
  }
  if (picked == null || picked.isEmpty) return [];
  final base = Directory(
      '${(await getApplicationSupportDirectory()).path}/quick_share_out/'
      '${DateTime.now().microsecondsSinceEpoch}');
  await base.create(recursive: true);
  final paths = <String>[];
  for (final p in picked) {
    final uri = (p as Map)['uri'] as String?;
    final name = (p['name'] as String?)?.replaceAll('\\', '/').split('/').last;
    if (uri == null || name == null || name.isEmpty) continue;
    final dest = '${base.path}/$name';
    try {
      final ok = await gFFI.invokeMethod(AndroidChannel.kImportFile,
          {'uri': uri, 'path': dest, 'overwrite': true});
      if (ok == true) paths.add(dest);
    } catch (e) {
      debugPrint('QuickShare: cannot read $name: $e');
    }
  }
  if (paths.isEmpty) {
    showToast(translate('Failed'));
    return [];
  }
  return sendWithToast(share, paths, toDir: toDir);
}

Future<List<int>> sendWithToast(QuickShare share, List<String> paths,
    {String? toDir}) async {
  showToast(toDir == null
      ? translate('Sending to the PC\'s Downloads folder')
      : translate('Sending to the PC'));
  try {
    return await share.sendToPeer(paths, toDir: toDir);
  } catch (e) {
    debugPrint('QuickShare: sending failed: $e');
    showToast(translate('Could not open a file connection to the PC'));
    return [];
  }
}

/// Opens the browser for the PC's files.
Future<void> showQuickShareSheet(BuildContext context, QuickShare share) async {
  // The remote page turns the phone keyboard off for the window, so the
  // filter field would never get one.
  await gFFI.invokeMethod("enable_soft_keyboard", true);
  if (!context.mounted) return;
  await Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => PcFilesPage(share: share)));
  await gFFI.invokeMethod("enable_soft_keyboard", false);
}

enum _Sort { newest, name, size }

/// The PC's files while it is being controlled: recent files, the usual
/// folders and the drives up front, folders to browse with a path bar,
/// filtering and search, and transfers both ways.
class PcFilesPage extends StatefulWidget {
  const PcFilesPage({super.key, required this.share});

  final QuickShare share;

  @override
  State<PcFilesPage> createState() => _PcFilesPageState();
}

class _PcFilesPageState extends State<PcFilesPage> {
  QuickShare get share => widget.share;

  // Null is the home view.
  String? _path;
  FileDirectory? _dir;
  List<Entry> _drives = [];
  List<Entry> _recent = [];
  bool _loading = true;
  String? _error;

  final _query = TextEditingController();
  bool _searchOpen = false;
  List<Entry>? _searchResults;
  bool _searching = false;
  _Sort _sort = _Sort.newest;
  final _selected = <String, Entry>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _searchResults = null));
    _home();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      await job();
    } catch (e) {
      debugPrint('QuickShare: $e');
      if (mounted) {
        setState(() => _error = _dir == null && _path == null
            ? translate('Could not open a file connection to the PC')
            : translate('This folder cannot be opened'));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _home() => _run(() async {
        await share.connection();
        final results =
            await Future.wait([share.drives(), share.recentFiles()]);
        if (!mounted) return;
        setState(() {
          _path = null;
          _dir = null;
          _drives = results[0];
          _recent = results[1];
        });
      });

  Future<void> _open(String path) => _run(() async {
        final dir = await share.listPeer(path);
        if (!mounted) return;
        setState(() {
          _path = path;
          _dir = dir;
          _query.clear();
          _searchOpen = false;
          _searchResults = null;
        });
      });

  // Up one folder; from a drive root or the home folder, back to home.
  Future<void> _up() {
    final path = _path;
    if (path == null) return Future.value();
    final ctx =
        share.peerIsWindows ? PathUtil.windowsContext : PathUtil.posixContext;
    final parent = ctx.dirname(path);
    if (parent == path || parent.isEmpty || parent == '.') return _home();
    return _open(parent);
  }

  Future<void> _deepSearch() async {
    final path = _path;
    final q = _query.text.trim();
    if (path == null || q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final found = await share.search(path, q);
      if (mounted) setState(() => _searchResults = found);
    } on TimeoutException {
      showToast(translate(
          'This folder is too big to search, open a subfolder first'));
    } catch (e) {
      debugPrint('QuickShare: search failed: $e');
      showToast(translate('Failed'));
    }
    if (mounted) setState(() => _searching = false);
  }

  void _download(Iterable<Entry> entries) {
    final list = entries.toList();
    if (list.isEmpty) return;
    showToast(translate('Downloading to the phone\'s Downloads folder'));
    for (final e in list) {
      share.receiveFromPeer(e).catchError((Object err) {
        debugPrint('QuickShare: receiving ${e.name} failed: $err');
        showToast(translate('Failed'));
      });
    }
    setState(() => _selected.clear());
  }

  List<Entry> _sorted(Iterable<Entry> entries) {
    int byName(Entry a, Entry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    final list = entries.toList();
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      switch (_sort) {
        case _Sort.newest:
          return b.modifiedTime.compareTo(a.modifiedTime);
        case _Sort.name:
          return byName(a, b);
        case _Sort.size:
          return a.isDirectory ? byName(a, b) : b.size.compareTo(a.size);
      }
    });
    return list;
  }

  String get _title {
    final path = _path;
    if (path == null) return translate('PC files');
    final parts = _crumbs();
    return parts.isEmpty ? path : parts.last.$1;
  }

  // (label, path) for every folder from the drive or root down to _path.
  List<(String, String)> _crumbs() {
    final path = _path;
    if (path == null) return [];
    final win = share.peerIsWindows;
    final segments = path
        .split(win ? RegExp(r'[\\/]') : RegExp('/'))
        .where((s) => s.isNotEmpty)
        .toList();
    final out = <(String, String)>[];
    var acc = win ? '' : '/';
    for (final s in segments) {
      acc = win
          ? (acc.isEmpty ? '$s\\' : PathUtil.join(acc, s, true))
          : PathUtil.join(acc, s, false);
      out.add((s, acc));
    }
    return out;
  }

  Future<void> _sendHere() async {
    final dir = _path;
    final ids = await pickAndSendToPeer(share, toDir: dir);
    if (dir == null || ids.isEmpty) return;
    await Future.wait(ids.map(share.whenDone));
    if (mounted && _path == dir) _open(dir);
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return PopScope(
      canPop: _path == null && !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selecting) {
          setState(() => _selected.clear());
        } else {
          _up();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: selecting
              ? Text('${_selected.length} ${translate('selected')}')
              : _searchOpen
                  ? TextField(
                      controller: _query,
                      autofocus: true,
                      decoration: InputDecoration(
                          hintText: translate('Filter this folder'),
                          border: InputBorder.none),
                      onSubmitted: (_) => _deepSearch(),
                    )
                  : Text(_title, overflow: TextOverflow.ellipsis),
          actions: [
            if (selecting)
              IconButton(
                tooltip: translate('Download'),
                icon: const Icon(Icons.download),
                onPressed: () => _download(_selected.values),
              )
            else ...[
              if (_path != null)
                IconButton(
                  tooltip: translate('Search'),
                  icon: Icon(_searchOpen ? Icons.close : Icons.search),
                  onPressed: () => setState(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) _query.clear();
                  }),
                ),
              if (_path != null)
                PopupMenuButton<_Sort>(
                  tooltip: translate('Sort'),
                  icon: const Icon(Icons.sort),
                  initialValue: _sort,
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: _Sort.newest,
                        child: Text(translate('Newest first'))),
                    PopupMenuItem(
                        value: _Sort.name, child: Text(translate('Name'))),
                    PopupMenuItem(
                        value: _Sort.size,
                        child: Text(translate('Largest first'))),
                  ],
                ),
              IconButton(
                tooltip: translate('Refresh'),
                icon: const Icon(Icons.refresh),
                onPressed: () => _path == null ? _home() : _open(_path!),
              ),
            ],
          ],
          bottom: _path == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(40),
                  child: _Breadcrumbs(
                    crumbs: _crumbs(),
                    onHome: _home,
                    onOpen: _open,
                  ),
                ),
        ),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton.extended(
                icon: const Icon(Icons.upload_file),
                label: Text(_path == null
                    ? translate('Send to Downloads')
                    : translate('Send here')),
                onPressed: _sendHere,
              ),
        body: Column(children: [
          if (_loading || _searching) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(child: _path == null ? _homeView() : _folderView()),
          _Transfers(share: share),
        ]),
      ),
    );
  }

  Widget _homeView() {
    final theme = Theme.of(context);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(translate(text), style: theme.textTheme.titleSmall),
        );
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (share.peerHome.isNotEmpty) ...[
          header('Folders'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (label, path) in share.places)
                ActionChip(
                  avatar: Icon(_placeIcon(label), size: 18),
                  label: Text(translate(label)),
                  onPressed: () => _open(path),
                ),
              ActionChip(
                avatar: const Icon(Icons.home_outlined, size: 18),
                label: Text(translate('Home')),
                onPressed: () => _open(share.peerHome),
              ),
            ]),
          ),
        ],
        if (_drives.isNotEmpty) ...[
          header('Drives'),
          for (final d in _drives)
            ListTile(
              leading: const Icon(Icons.storage),
              title: Text(d.name),
              onTap: () => _open(d.path),
            ),
        ],
        if (_recent.isNotEmpty) ...[
          header('Recent files'),
          for (final e in _recent) _entryTile(e, showFolder: true),
        ],
      ],
    );
  }

  Widget _folderView() {
    final dir = _dir;
    if (dir == null) return const SizedBox.shrink();
    final q = _query.text.trim().toLowerCase();
    final results = _searchResults;
    final entries = results ??
        _sorted(dir.entries.where((e) =>
            !e.isDrive && (q.isEmpty || e.name.toLowerCase().contains(q))));
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (q.isNotEmpty && results == null)
          ListTile(
            leading: const Icon(Icons.manage_search),
            title: Text(translate('Search subfolders too')),
            onTap: _searching ? null : _deepSearch,
          ),
        if (results != null && results.isEmpty)
          ListTile(title: Text(translate('No files found'))),
        if (results == null && entries.isEmpty && !_loading)
          ListTile(
              title: Text(
                  translate(q.isEmpty ? 'Empty folder' : 'No files found'))),
        for (final e in entries) _entryTile(e, showFolder: results != null),
      ],
    );
  }

  Widget _entryTile(Entry e, {bool showFolder = false}) {
    final selected = _selected.containsKey(e.path);
    final details = <String>[
      if (!e.isDirectory) readableFileSize(e.size.toDouble()),
      if (e.modifiedTime > 0) _when(e.lastModified()),
    ].join('  ·  ');
    final folder = showFolder ? _parentLabel(e.path) : null;
    return ListTile(
      selected: selected,
      leading: selected
          ? const Icon(Icons.check_circle)
          : Icon(e.isDirectory ? Icons.folder : _fileIcon(e.name),
              color: e.isDirectory ? Colors.amber.shade600 : null),
      title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(folder == null ? details : '$details\n$folder',
          maxLines: folder == null ? 1 : 2, overflow: TextOverflow.ellipsis),
      isThreeLine: folder != null,
      trailing: _selected.isEmpty
          ? IconButton(
              tooltip: translate('Download'),
              icon: const Icon(Icons.download_outlined),
              onPressed: () => _download([e]),
            )
          : null,
      onLongPress: () => setState(
          () => selected ? _selected.remove(e.path) : _selected[e.path] = e),
      onTap: () {
        if (_selected.isNotEmpty) {
          setState(() =>
              selected ? _selected.remove(e.path) : _selected[e.path] = e);
        } else if (e.isDirectory) {
          _open(e.path);
        } else {
          _download([e]);
        }
      },
    );
  }

  String _parentLabel(String path) {
    final ctx =
        share.peerIsWindows ? PathUtil.windowsContext : PathUtil.posixContext;
    final parent = ctx.dirname(path);
    final home = share.peerHome;
    return home.isNotEmpty && parent.startsWith(home)
        ? '~${parent.substring(home.length)}'
        : parent;
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}';
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(day).inDays;
    if (days == 0) return '${translate('Today')} $time';
    if (days == 1) return '${translate('Yesterday')} $time';
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  static IconData _placeIcon(String label) => switch (label) {
        'Desktop' => Icons.desktop_windows_outlined,
        'Downloads' => Icons.download_outlined,
        'Documents' => Icons.description_outlined,
        'Pictures' => Icons.image_outlined,
        'Videos' => Icons.movie_outlined,
        'Music' => Icons.music_note_outlined,
        _ => Icons.folder_outlined,
      };

  static IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'svg'};
    const videos = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'wmv'};
    const audio = {'mp3', 'wav', 'flac', 'ogg', 'm4a', 'aac'};
    const archives = {'zip', 'rar', '7z', 'tar', 'gz', 'xz'};
    const docs = {'doc', 'docx', 'odt', 'rtf', 'txt', 'md'};
    const sheets = {'xls', 'xlsx', 'csv', 'ods'};
    if (images.contains(ext)) return Icons.image_outlined;
    if (videos.contains(ext)) return Icons.movie_outlined;
    if (audio.contains(ext)) return Icons.audiotrack_outlined;
    if (archives.contains(ext)) return Icons.archive_outlined;
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (docs.contains(ext)) return Icons.description_outlined;
    if (sheets.contains(ext)) return Icons.table_chart_outlined;
    if (ext == 'exe' || ext == 'msi') return Icons.apps_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs(
      {required this.crumbs, required this.onHome, required this.onOpen});

  final List<(String, String)> crumbs;
  final VoidCallback onHome;
  final void Function(String) onOpen;

  @override
  Widget build(BuildContext context) {
    final controller = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
    return SizedBox(
      height: 40,
      child: ListView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          TextButton.icon(
            onPressed: onHome,
            icon: const Icon(Icons.computer, size: 18),
            label: Text(translate('PC')),
          ),
          for (final (label, path) in crumbs) ...[
            const Icon(Icons.chevron_right, size: 18),
            TextButton(onPressed: () => onOpen(path), child: Text(label)),
          ],
        ],
      ),
    );
  }
}

class _Transfers extends StatelessWidget {
  const _Transfers({required this.share});

  final QuickShare share;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final items = share.transfers.toList();
      share.jobTable?.length;
      if (items.isEmpty) return const SizedBox.shrink();
      return Material(
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final t in items.take(10)) _TransferTile(share: share, t: t)
            ],
          ),
        ),
      );
    });
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.share, required this.t});

  final QuickShare share;
  final QuickShareTransfer t;

  @override
  Widget build(BuildContext context) {
    final table = share.jobTable;
    return Obx(() {
      table?.length;
      final job = share.job(t.jobId);
      final state = job?.state ?? JobState.none;
      final done = state == JobState.done;
      final failed = state == JobState.error;
      final String status;
      if (failed) {
        status = translate('Failed');
      } else if (done) {
        status = t.toPeer
            ? translate('Sent to the PC')
            : t.savedUri != null
                ? translate('In Downloads, tap to open')
                : t.savedFolder != null
                    ? t.savedFolder!
                    : translate('Saving');
      } else {
        status = job?.percentText ?? '';
      }
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(t.toPeer ? Icons.north_east : Icons.south_west),
        title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: done || failed
            ? Text(status)
            : LinearProgressIndicator(value: job?.percent),
        onTap: !t.toPeer && t.savedUri != null ? () => share.open(t) : null,
      );
    });
  }
}
