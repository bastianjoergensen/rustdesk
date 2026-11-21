import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/mobile/widgets/typing_spot.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

class _Canvas extends ChangeNotifier implements CanvasModel {
  @override
  double x = 0, y = 0, scale = 1;
  @override
  bool isMobileCanvasChanged = false;
  @override
  double getAdjustY() => 0;
  @override
  void update(double x, double y, double scale) {
    this.x = x;
    this.y = y;
    this.scale = scale;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cursor extends Fake implements CursorModel {
  _Cursor(this.y);
  @override
  final double x = 100;
  @override
  final double y;
}

class _FfiModel extends Fake implements FfiModel {
  @override
  Rect? get rect => const Rect.fromLTWH(0, 0, 1600, 1000);
  @override
  final pi = PeerInfo();
}

class _FFI extends Fake implements FFI {
  _FFI(double cursorY) : cursorModel = _Cursor(cursorY);
  @override
  final _Canvas canvasModel = _Canvas();
  @override
  final CursorModel cursorModel;
  @override
  final ffiModel = _FfiModel();
}

// The test view is 800 x 600 and the keyboard leaves the remote view 300 high.
void main() {
  testWidgets('a spot the keyboard covers glides above it and back after',
      (tester) async {
    final ffi = _FFI(550);
    final spot = TypingSpotKeeper(ffi)..keyboardShown();
    spot.viewHeightChanged(300);
    await tester.pumpAndSettle();
    // A quarter of the view is left below it.
    expect(ffi.canvasModel.y + 550, closeTo(225, 0.001));
    spot.keyboardHidden();
    await tester.pumpAndSettle();
    expect(ffi.canvasModel.y, closeTo(0, 0.001));
    spot.dispose();
  });

  testWidgets('a spot in sight above the keyboard moves nothing',
      (tester) async {
    final ffi = _FFI(150);
    final spot = TypingSpotKeeper(ffi)..keyboardShown();
    spot.viewHeightChanged(300);
    await tester.pumpAndSettle();
    expect(ffi.canvasModel.y, 0);
    spot.dispose();
  });

  testWidgets('a view the user moved while typing stays put after',
      (tester) async {
    final ffi = _FFI(550);
    final spot = TypingSpotKeeper(ffi)..keyboardShown();
    spot.viewHeightChanged(300);
    await tester.pumpAndSettle();
    final c = ffi.canvasModel;
    c.y -= 40;
    c.isMobileCanvasChanged = true;
    spot.keyboardHidden();
    await tester.pumpAndSettle();
    expect(c.y, closeTo(-365, 0.001));
    spot.dispose();
  });
}
