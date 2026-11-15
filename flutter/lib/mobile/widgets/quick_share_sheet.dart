import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/quick_share.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// Lets the user pick phone files and send them to the PC's Downloads.
Future<void> pickAndSendToPeer(QuickShare share) async {
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
  if (picked == null || picked.isEmpty) return;
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
    return;
  }
  await sendWithToast(share, paths);
}

Future<void> sendWithToast(QuickShare share, List<String> paths) async {
  showToast(translate('Sending to the PC\'s Downloads folder'));
  try {
    await share.sendToPeer(paths);
  } catch (e) {
    debugPrint('QuickShare: sending failed: $e');
    showToast(translate('Could not open a file connection to the PC'));
  }
}

/// Files between this phone and the PC being controlled: send phone files to
/// the PC, take files from the PC, and follow the transfers.
void showQuickShareSheet(BuildContext context, QuickShare share) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) =>
          _QuickShareSheet(share: share, scroll: scroll),
    ),
  );
}

class _QuickShareSheet extends StatefulWidget {
  const _QuickShareSheet({required this.share, required this.scroll});

  final QuickShare share;
  final ScrollController scroll;

  @override
  State<_QuickShareSheet> createState() => _QuickShareSheetState();
}

class _QuickShareSheetState extends State<_QuickShareSheet> {
  QuickShare get share => widget.share;
  FileDirectory? _dir;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _open(null);
  }

  Future<void> _open(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await share.connection();
      final dir = await share.listPeer(path ?? share.peerInbox);
      if (!mounted) return;
      setState(() => _dir = dir);
    } catch (e) {
      debugPrint('QuickShare: cannot list ${path ?? 'Downloads'}: $e');
      if (!mounted) return;
      setState(() => _error = path == null
          ? translate('Could not open a file connection to the PC')
          : translate('This folder cannot be opened'));
      // Downloads may not exist; home always does.
      if (path == null && share.peerHome.isNotEmpty) {
        await _open(share.peerHome);
        return;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _join(String name) =>
      PathUtil.join(share.peerHome, name, share.peerIsWindows);

  String _parent(String path) {
    final ctx =
        share.peerIsWindows ? PathUtil.windowsContext : PathUtil.posixContext;
    return ctx.dirname(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = _dir;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2)),
          ),
        ),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            icon: const Icon(Icons.upload_file),
            label: Text(translate('Send files to the PC')),
            onPressed: () => pickAndSendToPeer(share),
          ),
        ),
        _Transfers(share: share),
        const SizedBox(height: 16),
        Text(translate('Take files from the PC'),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (share.peerHome.isNotEmpty)
          Wrap(spacing: 8, children: [
            for (final (label, path) in [
              ('Downloads', share.peerInbox),
              ('Desktop', _join('Desktop')),
              ('Documents', _join('Documents')),
              ('Home', share.peerHome),
            ])
              ActionChip(
                label: Text(translate(label)),
                onPressed: _loading ? null : () => _open(path),
              ),
          ]),
        if (dir != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.arrow_upward),
            title: Text(dir.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
            onTap: _loading || _parent(dir.path) == dir.path
                ? null
                : () => _open(_parent(dir.path)),
          ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child:
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (dir != null && !_loading)
          for (final e in dir.entries.where((e) => !e.isDrive))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(e.isDirectory
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: e.isDirectory
                  ? null
                  : Text('${readableFileSize(e.size.toDouble())}  ·  '
                      '${e.lastModified().toString().substring(0, 16)}'),
              trailing: e.isDirectory ? null : const Icon(Icons.download),
              onTap: () {
                if (e.isDirectory) {
                  _open(e.path);
                } else {
                  share.receiveFromPeer(e).catchError((Object err) {
                    debugPrint('QuickShare: receiving failed: $err');
                    showToast(translate('Failed'));
                  });
                }
              },
            ),
      ],
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
      // Rebuild on progress, which the job table carries.
      share.jobTable?.length;
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(children: [
        const SizedBox(height: 8),
        for (final t in items.take(8)) _TransferTile(share: share, t: t),
      ]);
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
            ? translate('In the PC\'s Downloads folder')
            : (t.savedUri != null
                ? translate('In Downloads, tap to open')
                : translate('Saving'));
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
