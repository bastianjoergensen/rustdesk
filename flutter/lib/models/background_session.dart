import 'package:flutter/foundation.dart';

import '../common.dart';
import '../consts.dart';
import 'chat_model.dart';
import 'model.dart';
import 'platform_model.dart';

/// While the mobile remote page is out of sight only the connection has to
/// stay up: the sound goes off, the other displays' streams close, the PC
/// sends at most [fps] frames a second of the main one, and the phone lets
/// them go without turning them into images. Back in sight, all of it is
/// undone and the PC sends a fresh picture.
class BackgroundSession {
  BackgroundSession(this.ffi, {this.onAway, this.onBack});

  final FFI ffi;

  /// Run when the page goes out of sight and comes back, for the streams of
  /// other displays.
  final Future<void> Function()? onAway, onBack;

  /// The lowest frame rate the client's own frame rate control keeps to:
  /// below 5 it takes the setting for unset and goes back up to 30.
  static const fps = 5;

  bool _want = false;
  bool _applied = false;
  // The peer's 'custom-fps' setting to go back to; '' when it had none.
  String? _savedFps;
  bool _muted = false;
  Future<void> _last = Future.value();

  static const _kNone = 'none';

  /// An app killed in the background cannot undo its frame rate; the next
  /// session does, before it connects and reads the setting.
  static void restoreFpsAfterKill(String peerId) {
    final saved = bind.mainGetPeerOptionSync(
        id: peerId, key: kPeerOptionBackgroundFpsRestore);
    if (saved.isEmpty) return;
    bind.mainSetPeerOptionSync(
        id: peerId, key: 'custom-fps', value: saved == _kNone ? '' : saved);
    bind.mainSetPeerOptionSync(
        id: peerId, key: kPeerOptionBackgroundFpsRestore, value: '');
  }

  /// Nor can it turn the sound back on; the next session does once it
  /// exists, as the setting is only reachable through a session.
  static void unmuteAfterKill(FFI ffi) {
    if (bind.mainGetPeerOptionSync(
            id: ffi.id, key: kPeerOptionBackgroundMuted) !=
        'Y') {
      return;
    }
    bind.mainSetPeerOptionSync(
        id: ffi.id, key: kPeerOptionBackgroundMuted, value: '');
    if (bind.sessionGetToggleOptionSync(
        sessionId: ffi.sessionId, arg: 'disable-audio')) {
      bind.sessionToggleOption(
          sessionId: ffi.sessionId, value: 'disable-audio');
    }
  }

  void setInBackground(bool background) {
    _want = background;
    ffi.imageModel.skipFrames = background;
    _last = _last
        .then((_) => _apply())
        .catchError((e) => debugPrint('Background session: $e'));
  }

  Future<void> _apply() async {
    if (_want == _applied) return;
    _applied = _want;
    if (_want) {
      await onAway?.call();
      await _mute();
      // A recording keeps its frame rate.
      if (ffi.recordingModel.start) return;
      final saved = await bind.sessionGetOption(
              sessionId: ffi.sessionId, arg: 'custom-fps') ??
          '';
      _savedFps = saved;
      await bind.mainSetPeerOption(
          id: ffi.id,
          key: kPeerOptionBackgroundFpsRestore,
          value: saved.isEmpty ? _kNone : saved);
      await bind.sessionSetCustomFps(sessionId: ffi.sessionId, fps: fps);
      return;
    }
    await _unmute();
    final saved = _savedFps;
    _savedFps = null;
    if (saved != null) {
      await bind.sessionSetCustomFps(
          sessionId: ffi.sessionId, fps: int.tryParse(saved) ?? 30);
      if (saved.isEmpty) {
        await bind.sessionPeerOption(
            sessionId: ffi.sessionId, name: 'custom-fps', value: '');
      }
      await bind.mainSetPeerOption(
          id: ffi.id, key: kPeerOptionBackgroundFpsRestore, value: '');
    }
    // Nothing was decoded meanwhile, and a screen that did not change since
    // sends nothing new.
    await sessionRefreshVideo(ffi.sessionId, ffi.ffiModel.pi);
    await onBack?.call();
  }

  // The sound is decoded and played as long as the PC sends it. A voice
  // call, or a session the user muted already, is left alone.
  Future<void> _mute() async {
    final call = ffi.chatModel.voiceCallStatus.value;
    if (call == VoiceCallStatus.connected ||
        call == VoiceCallStatus.waitingForResponse ||
        bind.sessionGetToggleOptionSync(
            sessionId: ffi.sessionId, arg: 'disable-audio')) {
      return;
    }
    await bind.mainSetPeerOption(
        id: ffi.id, key: kPeerOptionBackgroundMuted, value: 'Y');
    await bind.sessionToggleOption(
        sessionId: ffi.sessionId, value: 'disable-audio');
    _muted = true;
  }

  Future<void> _unmute() async {
    if (!_muted) return;
    _muted = false;
    if (bind.sessionGetToggleOptionSync(
        sessionId: ffi.sessionId, arg: 'disable-audio')) {
      await bind.sessionToggleOption(
          sessionId: ffi.sessionId, value: 'disable-audio');
    }
    await bind.mainSetPeerOption(
        id: ffi.id, key: kPeerOptionBackgroundMuted, value: '');
  }

  /// The page closes: a frame rate still lowered comes off the saved setting.
  /// A muted session stays marked, and the next session turns it back on.
  void dispose() {
    final saved = _savedFps;
    if (saved == null) return;
    _savedFps = null;
    bind.mainSetPeerOptionSync(id: ffi.id, key: 'custom-fps', value: saved);
    bind.mainSetPeerOptionSync(
        id: ffi.id, key: kPeerOptionBackgroundFpsRestore, value: '');
  }
}
