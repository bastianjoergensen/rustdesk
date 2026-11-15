import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/mobile_display_layout.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

// Peer options.
const _kOptionShowAllDisplays = 'mobile-show-all-displays';
const _kOptionDisplayLayout = 'mobile-display-layout';

/// Shows all displays of the peer at once on mobile, side by side as on the
/// remote or rearranged by the user, see [MobileDisplayLayout].
///
/// The soft renderer phones use sends a session the images of one display
/// only, so every other display gets a session of its own on the same
/// connection, which just takes its images. Input still goes through the
/// main session.
class MobileMultiDisplay extends ChangeNotifier {
  MobileMultiDisplay(this.ffi, this.peerId)
      : _enabled = bind.mainGetPeerOptionSync(
                id: peerId, key: _kOptionShowAllDisplays) !=
            'N' {
    ffi.ffiModel.addListener(_onFfiChanged);
  }

  final FFI ffi;
  final String peerId;
  bool _enabled;
  bool _unlocked = false;
  bool _disposed = false;
  final _streams = <int, _DisplayStream>{};
  // The display the main session shows.
  int? _main;
  String _signature = '';
  Timer? _activateTimer;
  int? _dragging;
  Offset? _draggedCursor;

  /// Ticks when the picture changes without the widgets changing: a new
  /// image of another display, a display being dragged.
  final repaint = ValueNotifier<int>(0);

  /// Show all displays when the peer has several; on unless turned off.
  bool get enabled => _enabled;

  /// The displays can be dragged around.
  bool get unlocked => _unlocked;

  MobileDisplayLayout? get layout => ffi.ffiModel.mobileDisplayLayout;
  bool get active => layout != null;
  int? get dragging => _dragging;

  ui.Image? imageOf(int display) =>
      display == _main ? ffi.imageModel.image : _streams[display]?.image;

  bool get _supported {
    final pi = ffi.ffiModel.pi;
    return pi.displays.length > 1 &&
        pi.currentDisplay != kAllDisplayValue &&
        PrivacyModeState.find(peerId).value.isEmpty;
  }

  void setEnabled(bool on) {
    _enabled = on;
    bind.mainSetPeerOption(
        id: peerId, key: _kOptionShowAllDisplays, value: on ? '' : 'N');
    if (on) {
      _activate();
    } else {
      _deactivate();
    }
    _notify();
  }

  void setUnlocked(bool on) {
    _unlocked = on && active;
    _notify();
  }

  /// Every (re)connection starts with the main display only.
  void onFirstImage() {
    if (!_enabled) return;
    // After a monitor restore the first image may trigger.
    _activateTimer?.cancel();
    _activateTimer = Timer(const Duration(milliseconds: 400), _activate);
  }

  Future<void> _activate() async {
    if (_disposed) return;
    if (!_supported) {
      await _deactivate();
      return;
    }
    final pi = ffi.ffiModel.pi;
    final main = pi.currentDisplay;
    _closeStreams();
    // With other sessions on the connection, the main one only gets the
    // images of the display it asked for. It has to be asked first: it also
    // sets what the peer captures, and the other sessions add to that.
    await bind.sessionSwitchDisplay(
        isDesktop: false,
        sessionId: ffi.sessionId,
        value: Int32List.fromList([main]));
    if (_disposed || !_enabled) return;
    _main = main;
    for (var i = 0; i < pi.displays.length; i++) {
      if (i == main) continue;
      final stream = _DisplayStream(ffi, i, _repaint);
      if (stream.start()) _streams[i] = stream;
    }
    final next = MobileDisplayLayout.restore(_remoteRects(),
        bind.mainGetPeerOptionSync(id: peerId, key: _kOptionDisplayLayout));
    _signature = next.signature;
    _setLayout(next);
  }

  Future<void> _deactivate() async {
    _activateTimer?.cancel();
    _unlocked = false;
    _dragging = null;
    final main = _main;
    final wasActive = active || _streams.isNotEmpty;
    _closeStreams();
    if (active) _setLayout(null);
    _main = null;
    if (wasActive && main != null && !_disposed) {
      // Stops capturing the other displays.
      await bind.sessionSwitchDisplay(
          isDesktop: false,
          sessionId: ffi.sessionId,
          value: Int32List.fromList([main]));
    }
    _notify();
  }

  // The cursor stays where it is on the remote.
  void _setLayout(MobileDisplayLayout? next) {
    final ffiModel = ffi.ffiModel;
    var p = ffi.cursorModel.offset;
    final prev = ffiModel.mobileDisplayLayout;
    if (prev != null) p = prev.toRemote(p);
    if (next != null) p = next.toLayout(p);
    ffiModel.mobileDisplayLayout = next;
    ffi.cursorModel.setMobileLayoutPosition(p);
    ffiModel.updateCurDisplay(ffi.sessionId);
    _notify();
  }

  List<Rect> _remoteRects() {
    // As FfiModel sizes the displays.
    final linux = ffi.ffiModel.isPeerLinux;
    return [
      for (final d in ffi.ffiModel.pi.displays)
        Rect.fromLTWH(
            d.x,
            d.y,
            (linux ? d.width.toDouble() ~/ d.scale : d.width).toDouble(),
            (linux ? d.height.toDouble() ~/ d.scale : d.height).toDouble())
    ];
  }

  // Displays plugged in or out, or resized.
  void _onFfiChanged() {
    if (!active || _disposed) return;
    final pi = ffi.ffiModel.pi;
    if (pi.currentDisplay != _main ||
        MobileDisplayLayout(_remoteRects()).signature != _signature) {
      _activateTimer?.cancel();
      _activateTimer = Timer(const Duration(milliseconds: 400), _activate);
    }
  }

  /// Rearranging: a finger went down on [layoutPoint].
  void dragStart(Offset layoutPoint) {
    final l = layout;
    if (l == null) return;
    _dragging = l.displayAt(layoutPoint);
    if (_dragging != null) {
      _draggedCursor = l.toRemote(ffi.cursorModel.offset);
    }
    _notify();
  }

  void dragUpdate(Offset layoutDelta) {
    final l = layout;
    final i = _dragging;
    if (l == null || i == null) return;
    l.move(i, layoutDelta);
    _repaint();
  }

  /// Drops the display, lined up with the others within [snap].
  void dragEnd(double snap) {
    final l = layout;
    final i = _dragging;
    _dragging = null;
    if (l == null || i == null) return;
    l.settle(i, snap);
    _layoutChanged(l, _draggedCursor);
  }

  void resetLayout() {
    final l = layout;
    if (l == null) return;
    final cursor = l.toRemote(ffi.cursorModel.offset);
    for (var i = 0; i < l.length; i++) {
      l.offsets[i] = l.remote[i].topLeft;
    }
    _layoutChanged(l, cursor);
  }

  void _layoutChanged(MobileDisplayLayout l, Offset? cursor) {
    bind.mainSetPeerOption(
        id: peerId,
        key: _kOptionDisplayLayout,
        value: l.isIdentity ? '' : l.encode());
    if (cursor != null) ffi.cursorModel.setMobileLayoutPosition(l.toLayout(cursor));
    ffi.ffiModel.updateCurDisplay(ffi.sessionId);
    _notify();
  }

  void _closeStreams() {
    for (final s in _streams.values) {
      s.close();
    }
    _streams.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _repaint() {
    if (!_disposed) repaint.value++;
  }

  /// Closes the extra sessions. Must run before the main session closes: the
  /// connection stays up while any session on it is left.
  @override
  void dispose() {
    _disposed = true;
    _activateTimer?.cancel();
    ffi.ffiModel.removeListener(_onFfiChanged);
    _closeStreams();
    ffi.ffiModel.mobileDisplayLayout = null;
    repaint.dispose();
    super.dispose();
  }
}

/// The images of one display, from a session that shares the connection of
/// the main one.
class _DisplayStream {
  _DisplayStream(this.ffi, this.display, this.onImage);

  final FFI ffi;
  final int display;
  final VoidCallback onImage;
  final SessionID sessionId = Uuid().v4obj();
  ui.Image? image;
  StreamSubscription<EventToUI>? _subscription;
  bool _closed = false;

  bool start() {
    final displays = Int32List.fromList([display]);
    final error = bind.sessionAddExistedSync(
        id: ffi.id,
        sessionId: sessionId,
        displays: displays,
        isViewCamera: false);
    if (error.isNotEmpty) {
      debugPrint('Failed to show display $display: $error');
      return false;
    }
    _subscription = bind
        .sessionStartWithDisplays(
            sessionId: sessionId, id: ffi.id, displays: displays)
        .listen(_onEvent);
    return true;
  }

  Future<void> _onEvent(EventToUI message) async {
    if (_closed || message is! EventToUI_Rgba) return;
    final d = message.field0;
    final size = platformFFI.getRgbaSize(sessionId, d);
    final rgba = size == 0 ? null : platformFFI.getRgba(sessionId, d, size);
    final rect = ffi.ffiModel.pi.getDisplayRect(d);
    ui.Image? next;
    if (rgba != null && rect != null) {
      try {
        next = await img.decodeImageFromPixels(
            rgba,
            rect.width.toInt(),
            rect.height.toInt(),
            isWeb | isWindows | isLinux
                ? ui.PixelFormat.rgba8888
                : ui.PixelFormat.bgra8888);
      } catch (e) {
        debugPrint('Failed to decode display $d: $e');
      }
    }
    if (!_closed) platformFFI.nextRgba(sessionId, d);
    if (next == null) return;
    if (_closed) {
      next.dispose();
      return;
    }
    image?.dispose();
    image = next;
    onImage();
  }

  void close() {
    _closed = true;
    _subscription?.cancel();
    bind.sessionClose(sessionId: sessionId);
    image?.dispose();
    image = null;
  }
}

/// Paints every display where the layout puts it, instead of ImagePaint.
class MultiDisplayPaint extends StatelessWidget {
  const MultiDisplayPaint({super.key, required this.controller});

  final MobileMultiDisplay controller;

  @override
  Widget build(BuildContext context) {
    final canvas = Provider.of<CanvasModel>(context);
    // The main display's image.
    Provider.of<ImageModel>(context);
    final layout = controller.layout;
    final origin = controller.ffi.ffiModel.rect?.topLeft;
    if (layout == null || origin == null) return const SizedBox.shrink();
    return CustomPaint(
      painter: _MultiDisplayPainter(
        repaint: controller.repaint,
        controller: controller,
        layout: layout,
        topLeft: Offset(canvas.x, canvas.y + canvas.getAdjustY()) -
            origin * canvas.scale,
        scale: canvas.scale,
      ),
    );
  }
}

class _MultiDisplayPainter extends CustomPainter {
  _MultiDisplayPainter({
    required Listenable repaint,
    required this.controller,
    required this.layout,
    required this.topLeft,
    required this.scale,
  }) : super(repaint: repaint);

  final MobileMultiDisplay controller;
  final MobileDisplayLayout layout;
  // Where the layout origin is on the screen.
  final Offset topLeft;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final unlocked = controller.unlocked;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (var i = 0; i < layout.length; i++) {
      final r = layout.layoutRect(i);
      final dst = Rect.fromLTWH(topLeft.dx + r.left * scale,
          topLeft.dy + r.top * scale, r.width * scale, r.height * scale);
      final image = controller.imageOf(i);
      if (image != null) {
        canvas.drawImageRect(
            image,
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            dst,
            paint);
      } else {
        canvas.drawRect(dst, Paint()..color = const Color(0xFF2C2F33));
      }
      if (unlocked || image == null) _label(canvas, dst, i);
      if (unlocked) {
        canvas.drawRect(
            dst.deflate(1),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = controller.dragging == i ? 3 : 2
              ..color = controller.dragging == i
                  ? MyTheme.accent
                  : Colors.white.withOpacity(0.7));
      }
    }
  }

  void _label(Canvas canvas, Rect dst, int i) {
    final radius = (dst.shortestSide / 6).clamp(10.0, 28.0);
    canvas.drawCircle(
        dst.center, radius, Paint()..color = const Color(0xCC000000));
    final text = TextPainter(
      text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
              color: Colors.white,
              fontSize: radius,
              fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, dst.center - Offset(text.width / 2, text.height / 2));
  }

  // The layout is changed in place while a display is dragged.
  @override
  bool shouldRepaint(_MultiDisplayPainter oldDelegate) => true;
}

/// Takes the touches while the displays are unlocked: one finger moves a
/// display, two fingers still zoom and pan the view. Nothing goes to the
/// remote meanwhile.
class DisplayRearrangeLayer extends StatefulWidget {
  const DisplayRearrangeLayer({super.key, required this.controller});

  final MobileMultiDisplay controller;

  @override
  State<DisplayRearrangeLayer> createState() => _DisplayRearrangeLayerState();
}

class _DisplayRearrangeLayerState extends State<DisplayRearrangeLayer> {
  double _lastScale = 1;
  bool _moving = false;

  MobileMultiDisplay get c => widget.controller;
  CanvasModel get _canvas => c.ffi.canvasModel;

  Offset _toLayout(Offset local) {
    final origin = c.ffi.ffiModel.rect?.topLeft ?? Offset.zero;
    final canvas = _canvas;
    return origin +
        (local - Offset(canvas.x, canvas.y + canvas.getAdjustY())) /
            canvas.scale;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (d) {
        _lastScale = 1;
        _moving = d.pointerCount == 1;
        if (_moving) {
          c.dragStart(_toLayout(d.localFocalPoint));
          // Off the displays one finger pans the view.
          _moving = c.dragging != null;
        }
      },
      onScaleUpdate: (d) {
        if (_moving) {
          c.dragUpdate(d.focalPointDelta / _canvas.scale);
        } else {
          _canvas.updateScale(d.scale / _lastScale, d.localFocalPoint);
          _lastScale = d.scale;
          _canvas.panX(d.focalPointDelta.dx);
          _canvas.panY(d.focalPointDelta.dy);
        }
      },
      onScaleEnd: (_) {
        // Edges this close on the screen snap together.
        if (_moving) c.dragEnd(24 / _canvas.scale);
        _moving = false;
      },
    );
  }
}

/// The bar shown while the displays are unlocked.
class DisplayRearrangeBar extends StatelessWidget {
  const DisplayRearrangeBar({super.key, required this.controller});

  final MobileMultiDisplay controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE6202225),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 0, 6, 0),
              child: Icon(Icons.open_with, color: Colors.white, size: 20),
            ),
            Text(translate('Rearrange displays'),
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            TextButton(
              onPressed: controller.resetLayout,
              child: Text(translate('Reset to default')),
            ),
            TextButton(
              onPressed: () => controller.setUnlocked(false),
              child: Text(translate('OK')),
            ),
          ],
        ),
      ),
    );
  }
}
