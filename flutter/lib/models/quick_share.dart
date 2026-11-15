import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
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

  bool get peerIsWindows =>
      _ffi?.fileModel.remoteController.options.value.isWindows ?? false;

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
    final ffi = FFI(Uuid().v4obj());
    ffi.start(peerId,
        isFileTransfer: true,
        connToken: bind.sessionGetConnToken(sessionId: remoteSessionId));
    final remote = ffi.fileModel.remoteController;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (remote.homePath.isEmpty) {
      if (_closed || DateTime.now().isAfter(deadline)) {
        await _closeFfi(ffi);
        throw TimeoutException('No file connection to $peerId');
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _ffi = ffi;
    return ffi;
  }

  Future<FileDirectory> listPeer(String path) async {
    final ffi = await connection();
    final fd =
        await ffi.fileModel.fileFetcher.fetchDirectory(path, false, false);
    fd.format(peerIsWindows);
    fd.entries.sort((a, b) => b.modifiedTime.compareTo(a.modifiedTime));
    return fd;
  }

  /// Sends local files to the peer's Downloads folder, renaming any whose
  /// name is taken there so nothing is overwritten.
  Future<void> sendToPeer(List<String> localPaths) async {
    final ffi = await connection();
    final inbox = peerInbox;
    final taken = <String>[];
    try {
      taken.addAll((await listPeer(inbox)).entries.map((e) => e.name));
    } catch (e) {
      debugPrint('QuickShare: cannot list $inbox: $e');
    }
    final jobs = ffi.fileModel.jobController;
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
  }

  /// Fetches a file from the peer into the app's storage, then hands it to
  /// the phone's Downloads.
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
        isDir: false);
    await _whenDone(jobId);
    if (job(jobId)?.state != JobState.done) return;
    try {
      transfer.savedUri = await _channel.invokeMethod<String>(
          'save_to_downloads', {'path': local, 'name': entry.name});
      transfers.refresh();
    } catch (e) {
      debugPrint('QuickShare: saving ${entry.name} failed: $e');
    } finally {
      unawaited(File(local).delete().catchError((_) => File(local)));
    }
  }

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
