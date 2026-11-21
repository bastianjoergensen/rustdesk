import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/models/model.dart';

/// Keeps the spot being typed at, the remote cursor, in sight while the soft
/// keyboard covers the bottom of the remote view: the picture glides up at
/// the same zoom, just far enough to leave the spot some room above the
/// keyboard, and back down when the keyboard goes away. Nothing moves when
/// the spot stays in sight anyway, or once the user moves the view.
class TypingSpotKeeper {
  TypingSpotKeeper(this.ffi);

  final FFI ffi;
  Ticker? _ticker;
  // How far the picture is up now, and the glide it is on.
  double _lift = 0, _from = 0, _to = 0;
  Duration _duration = Duration.zero;
  // Decided on the keyboard's first height: only a spot the user could see
  // is followed.
  bool? _follow;
  int? _display;
  double? _scale;

  CanvasModel get _canvas => ffi.canvasModel;

  void keyboardShown() {
    _follow = null;
    // Set again by any pan or zoom of the user's from now on.
    _canvas.isMobileCanvasChanged = false;
    _display = ffi.ffiModel.pi.currentDisplay;
    _scale = _canvas.scale;
  }

  /// The view left above the keyboard is [height] high now.
  void viewHeightChanged(double height) {
    final c = _canvas;
    final rect = ffi.ffiModel.rect;
    if (rect == null || c.isMobileCanvasChanged || _follow == false) return;
    final cursor = ffi.cursorModel;
    // Where things end up once the glide under way is done.
    final top = c.y + c.getAdjustY() - (_to - _lift);
    final x = c.x + cursor.x * c.scale;
    final y = top + cursor.y * c.scale;
    if (_follow == null) {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView;
      final screen = view == null
          ? Size.infinite
          : view.physicalSize / view.devicePixelRatio;
      _follow =
          x >= 0 && x <= screen.width && y >= 0 && y <= screen.height;
      if (_follow == false) return;
    }
    // Room for the line typed on and what opens below it, like suggestions.
    final room = (height * 0.25).clamp(48.0, 160.0);
    // Never so far that the space below the picture shows.
    final up = min(y - (height - room), top + rect.height * c.scale - height);
    if (up > 0) _glideTo(_to + up, const Duration(milliseconds: 220));
  }

  void keyboardHidden() {
    final c = _canvas;
    _follow = false;
    if (_lift > 0 &&
        !c.isMobileCanvasChanged &&
        c.scale == _scale &&
        ffi.ffiModel.pi.currentDisplay == _display) {
      _glideTo(0, const Duration(milliseconds: 250));
    } else {
      _forget();
    }
  }

  void _glideTo(double lift, Duration duration) {
    _from = _lift;
    _to = lift;
    _duration = duration;
    final ticker = _ticker ??= Ticker(_tick);
    ticker.stop();
    ticker.start();
  }

  void _tick(Duration elapsed) {
    final c = _canvas;
    // The user took the view over.
    if (c.isMobileCanvasChanged) {
      _forget();
      return;
    }
    final t = min(1.0, elapsed.inMicroseconds / _duration.inMicroseconds);
    final lift = _from + (_to - _from) * Curves.easeOutCubic.transform(t);
    c.update(c.x, c.y - (lift - _lift), c.scale);
    _lift = lift;
    if (t >= 1) _ticker?.stop();
  }

  // The view stays where it is, as the user's now.
  void _forget() {
    _ticker?.stop();
    _lift = _from = _to = 0;
  }

  void dispose() => _ticker?.dispose();
}
