import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// [name], or `name (2).ext`, `name (3).ext`, ... if [taken] has it already
/// (compared case-insensitively, as on Windows).
String uniqueFileName(String name, Iterable<String> taken) {
  final used = {for (final t in taken) t.toLowerCase()};
  if (!used.contains(name.toLowerCase())) return name;
  final dot = name.lastIndexOf('.');
  final hasExt = dot > 0;
  final stem = hasExt ? name.substring(0, dot) : name;
  final ext = hasExt ? name.substring(dot) : '';
  for (var i = 2;; i++) {
    final candidate = '$stem ($i)$ext';
    if (!used.contains(candidate.toLowerCase())) return candidate;
  }
}

/// One file going one way.
class QuickShareTransfer {
  QuickShareTransfer(
      {required this.jobId,
      required this.name,
      required this.toPeer,
      this.localPath});

  final int jobId;
  final String name;
  final bool toPeer;

  /// Where a file from the peer lands before it is handed to Android.
  final String? localPath;

  /// Set once a received file is in the phone's Downloads.
  String? savedUri;

  /// Set once a received folder is in the phone's Downloads.
  String? savedFolder;
}

/// Moves files between this phone and the peer of a remote session while it
/// is being controlled, over a second, hidden file transfer connection that
/// logs in with the session's connection token, so no password is asked.
///
/// The peer only takes file commands on a file transfer connection, which is
/// why the remote session itself cannot carry them.
class QuickShare {
  QuickShare(this.peerId, this.remoteSessionId);

  final String peerId;
  final SessionID remoteSessionId;

  static const _channel = MethodChannel('rustdesk/quick_share');

  final transfers = RxList<QuickShareTransfer>();

  /// Files other apps shared with RustDesk (see ShareReceiverActivity) go to
  /// [onFiles], which returns whether a session took them.
  static void setIncomingHandler(Future<bool> Function(List<String>)? onFiles) {
    _channel.setMethodCallHandler(onFiles == null
        ? null
        : (call) async {
            if (call.method != 'incoming') return false;
            return onFiles(List<String>.from(call.arguments as List));
          });
  }

  FFI? _ffi;
  Future<FFI>? _connecting;
  bool _closed = false;

  /// The peer's folder files from the phone go to.
  String get peerInbox {
    final remote = _ffi?.fileModel.remoteController;
    if (remote == null) return '';
    return PathUtil.join(
        remote.homePath, 'Downloads', remote.options.value.isWindows);
  }

  // Not the file model's own flag: that is only set some time after the
  // home folder arrives.
  bool get peerIsWindows =>
      _ffi?.ffiModel.pi.platform == kPeerPlatformWindows;

  String get peerHome => _ffi?.fileModel.remoteController.homePath ?? '';

  /// Transfer progress of [jobId], or null before the connection exists.
  JobProgress? job(int jobId) {
    final table = _ffi?.fileModel.jobController.jobTable;
    return table?.firstWhereOrNull((j) => j.id == jobId);
  }

  RxList<JobProgress>? get jobTable => _ffi?.fileModel.jobController.jobTable;

  Future<FFI> connection() {
    if (_closed) return Future.error(StateError('closed'));
    return _connecting ??= _connect().catchError((Object e) {
      _connecting = null;
      throw e;
    });
  }

  Future<FFI> _connect() async {
    final ffi = await _openConnection();
    _ffi = ffi;
    return ffi;
  }

  Future<FFI> _openConnection() async {
    final ffi = FFI(Uuid().v4obj());
    ffi.start(peerId,
        isFileTransfer: true,
        connToken: bind.sessionGetConnToken(sessionId: remoteSessionId));
    final remote = ffi.fileModel.remoteController;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (remote.homePath.isEmpty || ffi.ffiModel.pi.platform.isEmpty) {
      if (_closed || DateTime.now().isAfter(deadline)) {
        await _closeFfi(ffi);
        throw TimeoutException('No file connection to $peerId');
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return ffi;
  }

  Future<FileDirectory> listPeer(String path) async {
    final ffi = await connection();
    final fd =
        await ffi.fileModel.fileFetcher.fetchDirectory(path, false, false);
    fd.format(peerIsWindows);
    return fd;
  }

  /// The peer's drives (Windows only), each with its root as [Entry.path].
  Future<List<Entry>> drives() async {
    await connection();
    if (!peerIsWindows) return [];
    final fd = await listPeer('/');
    return [
      for (final e in fd.entries.where((e) => e.isDrive))
        e..path = e.name.endsWith(r'\') ? e.name : '${e.name}\\'
    ];
  }

  /// The usual folders in the peer's home, as (label, path).
  List<(String, String)> get places => [
        for (final name in const [
          'Desktop',
          'Downloads',
          'Documents',
          'Pictures',
          'Videos',
          'Music',
        ])
          (name, PathUtil.join(peerHome, name, peerIsWindows)),
      ];

  /// The newest files directly inside the usual folders.
  Future<List<Entry>> recentFiles({int limit = 30}) async {
    await connection();
    final lists = await Future.wait(places.map((p) => listPeer(p.$2)
        .then((fd) => fd.entries.where((e) => e.isFile).toList())
        .catchError((Object _) => <Entry>[])));
    final files = lists.expand((l) => l).toList()
      ..sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return files.take(limit).toList();
  }

  /// Files and folders under [dir], at any depth, whose name contains
  /// [query]. The peer lists the whole tree first, so a large folder takes
  /// a while; past [timeout] the search gives up. It runs on a connection
  /// of its own, closed afterwards: the peer keeps listing a huge tree after
  /// the search gives up, and browsing on a shared connection would stall.
  Future<List<Entry>> search(String dir, String query,
      {Duration timeout = const Duration(seconds: 45), int max = 300}) async {
    await connection();
    final ffi = await _openConnection();
    try {
      return await _search(ffi, dir, query, timeout, max);
    } finally {
      unawaited(_closeFfi(ffi));
    }
  }

  Future<List<Entry>> _search(FFI ffi, String dir, String query,
      Duration timeout, int max) async {
    final fetcher = ffi.fileModel.fileFetcher;
    final id = JobController.jobID.next();
    final completer = Completer<FileDirectory>();
    fetcher.readRecursiveTasks[id] = completer;
    await bind.sessionReadDirToRemoveRecursive(
        sessionId: ffi.sessionId,
        actId: id,
        path: dir,
        isRemote: true,
        showHidden: false);
    final FileDirectory fd;
    try {
      fd = await completer.future.timeout(timeout);
    } finally {
      fetcher.readRecursiveTasks.remove(id);
    }
    final q = query.toLowerCase();
    final found = <Entry>[];
    for (final e in fd.entries) {
      final rel = e.name.replaceAll(r'\', '/');
      if (!rel.split('/').last.toLowerCase().contains(q)) continue;
      found.add(e
        ..path = PathUtil.join(dir, e.name, peerIsWindows)
        ..name = rel.split('/').last);
    }
    found.sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return found.take(max).toList();
  }

  /// Sends local files to [toDir] on the peer (its Downloads folder by
  /// default), renaming any whose name is taken there so nothing is
  /// overwritten.
  Future<List<int>> sendToPeer(List<String> localPaths, {String? toDir}) async {
    final ffi = await connection();
    final inbox = toDir ?? peerInbox;
    final taken = <String>[];
    try {
      taken.addAll((await listPeer(inbox)).entries.map((e) => e.name));
    } catch (e) {
      debugPrint('QuickShare: cannot list $inbox: $e');
    }
    final jobs = ffi.fileModel.jobController;
    final ids = <int>[];
    for (final path in localPaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final name =
          uniqueFileName(path.replaceAll('\\', '/').split('/').last, taken);
      taken.add(name);
      final entry = Entry()
        ..name = name
        ..path = path
        ..size = await file.length();
      final jobId = jobs.addTransferJob(entry, false);
      ids.add(jobId);
      transfers.insert(
          0, QuickShareTransfer(jobId: jobId, name: name, toPeer: true));
      await bind.sessionSendFiles(
          sessionId: ffi.sessionId,
          actId: jobId,
          path: path,
          to: PathUtil.join(inbox, name, peerIsWindows),
          fileNum: 0,
          includeHidden: false,
          isRemote: false,
          isDir: false);
    }
    return ids;
  }

  /// Fetches a file or folder from the peer into the app's storage, then
  /// hands it to the phone's Downloads.
  Future<void> receiveFromPeer(Entry entry) async {
    final ffi = await connection();
    final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/quick_share');
    await dir.create(recursive: true);
    final taken = await dir.list().map((e) => e.path.split('/').last).toList();
    final name = uniqueFileName(entry.name, taken);
    final local = '${dir.path}/$name';
    final jobId = ffi.fileModel.jobController.addTransferJob(entry, true);
    final transfer = QuickShareTransfer(
        jobId: jobId, name: entry.name, toPeer: false, localPath: local);
    transfers.insert(0, transfer);
    await bind.sessionSendFiles(
        sessionId: ffi.sessionId,
        actId: jobId,
        path: entry.path,
        to: local,
        fileNum: 0,
        includeHidden: false,
        isRemote: true,
        isDir: entry.isDirectory);
    await _whenDone(jobId);
    if (job(jobId)?.state != JobState.done) return;
    try {
      if (entry.isDirectory) {
        await _saveFolder(Directory(local), entry.name);
        transfer.savedFolder = 'Download/${entry.name}';
      } else {
        transfer.savedUri = await _channel.invokeMethod<String>(
            'save_to_downloads', {'path': local, 'name': entry.name});
      }
      transfers.refresh();
    } catch (e) {
      debugPrint('QuickShare: saving ${entry.name} failed: $e');
    } finally {
      unawaited(FileSystemEntity.isDirectory(local)
          .then((isDir) => isDir
              ? Directory(local).delete(recursive: true)
              : File(local).delete())
          .catchError((_) => File(local)));
    }
  }

  Future<void> _saveFolder(Directory dir, String name) async {
    await for (final f in dir.list(recursive: true)) {
      if (f is! File) continue;
      final rel = f.path.substring(dir.path.length + 1).split('/');
      final sub = [name, ...rel.sublist(0, rel.length - 1)].join('/');
      await _channel.invokeMethod<String>('save_to_downloads',
          {'path': f.path, 'name': rel.last, 'subdir': sub});
    }
  }

  Future<void> whenDone(int jobId) => _whenDone(jobId);

  Future<void> _whenDone(int jobId) async {
    while (!_closed) {
      final state = job(jobId)?.state;
      if (state == JobState.done || state == JobState.error) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Opens a received file with the app Android picks for it.
  Future<void> open(QuickShareTransfer t) async {
    final uri = t.savedUri;
    if (uri != null) await _channel.invokeMethod('open', {'uri': uri});
  }

  Future<void> close() async {
    _closed = true;
    final ffi = _ffi;
    _ffi = null;
    _connecting = null;
    if (ffi != null) await _closeFfi(ffi);
  }

  static Future<void> _closeFfi(FFI ffi) async {
    try {
      await ffi.fileModel.close();
    } catch (e) {
      debugPrint('QuickShare: closing the file model failed: $e');
    }
    await ffi.close();
  }
}
