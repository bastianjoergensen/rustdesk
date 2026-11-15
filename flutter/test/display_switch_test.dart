import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/display_switch.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

PeerInfo _peer({
  required int displays,
  int current = 0,
  String platform = kPeerPlatformWindows,
}) =>
    PeerInfo()
      ..platform = platform
      ..currentDisplay = current
      ..displays = List.generate(displays, (_) => Display()).obs;

void main() {
  group('canSwitchDisplays', () {
    test('needs more than one display', () {
      expect(canSwitchDisplays(_peer(displays: 1), ''), isFalse);
      expect(canSwitchDisplays(_peer(displays: 2), ''), isTrue);
    });

    test('is off while every display is shown as one', () {
      expect(
        canSwitchDisplays(_peer(displays: 3, current: kAllDisplayValue), ''),
        isFalse,
      );
    });

    test('does not depend on which display is current', () {
      expect(canSwitchDisplays(_peer(displays: 3, current: 2), ''), isTrue);
    });

    test('privacy mode of a peer that forbids the switch blocks it', () {
      // macOS blacks out every display, so switching cannot weaken it.
      expect(
        canSwitchDisplays(
            _peer(displays: 2, platform: kPeerPlatformMacOS), 'privacy_mode'),
        isTrue,
      );
      expect(
        canSwitchDisplays(
            _peer(displays: 2, platform: kPeerPlatformLinux), 'privacy_mode'),
        isFalse,
      );
      // Windows mode 1 covers every local monitor as well, but only from 1.4.8
      // on and only for its own privacy impls. Telling those apart needs the
      // native version compare, so it stays out of this test.
      expect(canSwitchDisplays(_peer(displays: 2), 'privacy_mode'), isFalse);
    });

    test('an empty privacy mode lets the switch through', () {
      expect(
        canSwitchDisplays(_peer(displays: 2, platform: kPeerPlatformLinux), ''),
        isTrue,
      );
    });
  });

  group('shouldRestoreDisplay', () {
    bool restore(int display, PeerInfo pi,
            {String privacyMode = '', bool useAllMyDisplays = false}) =>
        shouldRestoreDisplay(display, pi, privacyMode,
            useAllMyDisplays: useAllMyDisplays);

    test('switches to another display the peer still has', () {
      expect(restore(1, _peer(displays: 2)), isTrue);
      expect(restore(0, _peer(displays: 3, current: 2)), isTrue);
    });

    test('stays on the display that is already shown', () {
      expect(restore(1, _peer(displays: 2, current: 1)), isFalse);
    });

    test('ignores a display the peer no longer has', () {
      expect(restore(2, _peer(displays: 2)), isFalse);
      expect(restore(-1, _peer(displays: 2)), isFalse);
      expect(restore(1, _peer(displays: 1)), isFalse);
    });

    test('leaves a session showing every display alone', () {
      expect(restore(1, _peer(displays: 2), useAllMyDisplays: true), isFalse);
      expect(
          restore(1, _peer(displays: 2, current: kAllDisplayValue)), isFalse);
    });

    test('does not switch while privacy mode forbids it', () {
      expect(
        restore(1, _peer(displays: 2, platform: kPeerPlatformLinux),
            privacyMode: 'privacy_mode'),
        isFalse,
      );
    });
  });
}
