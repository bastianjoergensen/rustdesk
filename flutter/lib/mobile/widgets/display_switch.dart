import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

/// Whether the peer offers a display the user may switch to right now.
bool canSwitchDisplays(PeerInfo pi, String privacyModeImpl) =>
    pi.displays.length > 1 &&
    pi.currentDisplay != kAllDisplayValue &&
    (privacyModeImpl.isEmpty ||
        allowDisplaySwitchInPrivacyMode(pi, privacyModeImpl));

/// Whether a new connection should switch to [display], the one saved by
/// [saveLastDisplay]: not when it is already shown, the peer no longer has it,
/// or it cannot be switched to right now.
bool shouldRestoreDisplay(int display, PeerInfo pi, String privacyModeImpl,
        {required bool useAllMyDisplays}) =>
    display != pi.currentDisplay &&
    display >= 0 &&
    display < pi.displays.length &&
    !useAllMyDisplays &&
    canSwitchDisplays(pi, privacyModeImpl);

/// Remembers the display of [peerId], so the next connection starts on it.
void saveLastDisplay(String peerId, int display) {
  bind
      .mainSetPeerOption(
          id: peerId, key: kKeyLastDisplay, value: display.toString())
      .catchError(
          (e) => debugPrint('Failed to save the last display of $peerId: $e'));
}

/// Floating control that switches the remote display. It sits in the top right
/// corner, far from the soft keyboard, so it stays reachable while typing and
/// picking a display does not have to close the keyboard. With two displays a
/// tap goes straight to the other one; with more it opens a picker.
class DisplaySwitcher extends StatefulWidget {
  const DisplaySwitcher({super.key, required this.ffi, required this.peerId});

  final FFI ffi;
  final String peerId;

  @override
  State<DisplaySwitcher> createState() => _DisplaySwitcherState();
}

class _DisplaySwitcherState extends State<DisplaySwitcher> {
  static const _buttonSize = 40.0;
  static const _displaySize = 36.0;

  final _key = GlobalKey();
  Rect? _blockedRect;
  bool _open = false;
  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);

  CursorModel get _cursor => widget.ffi.cursorModel;

  @override
  void dispose() {
    _clearBlockedRect();
    super.dispose();
  }

  // Taps on the switcher must not reach the remote screen below it.
  void _updateBlockedRect() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject();
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    if (box is! RenderBox || !box.hasSize || stack == null) return;
    final rect = stack.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
    if (rect == _blockedRect) return;
    _clearBlockedRect();
    _cursor.addBlockedRect(rect);
    _blockedRect = rect;
  }

  void _clearBlockedRect() {
    final rect = _blockedRect;
    if (rect != null) _cursor.removeBlockedRect(rect);
    _blockedRect = null;
  }

  void _select(int display) {
    final ffi = widget.ffi;
    final pi = ffi.ffiModel.pi;
    setState(() => _open = false);
    if (display == pi.currentDisplay) return;
    // A double tap would switch there and straight back.
    final now = DateTime.now();
    if (now.difference(_lastSwitch) < const Duration(milliseconds: 500)) return;
    _lastSwitch = now;
    openMonitorInTheSameTab(display, ffi, pi);
    saveLastDisplay(widget.peerId, display);
  }

  void _onTap(PeerInfo pi) {
    if (pi.displays.length == 2) {
      _select(pi.currentDisplay == 0 ? 1 : 0);
    } else {
      setState(() => _open = !_open);
    }
  }

  Widget _button(PeerInfo pi) {
    final current = pi.currentDisplay;
    final toggle = pi.displays.length == 2;
    return Semantics(
      button: true,
      expanded: toggle ? null : _open,
      label: toggle
          ? '${translate('Switch display')} (${current + 1}/2)'
          : translate('Display'),
      excludeSemantics: true,
      child: Material(
        color: const Color(0xB3000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _onTap(pi),
          child: SizedBox(
            width: _buttonSize,
            height: _buttonSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(Icons.desktop_windows,
                      size: 20, color: Colors.white),
                ),
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                        color: MyTheme.accent,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text('${current + 1}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 9, height: 1.4)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(PeerInfo pi) {
    final cur = pi.currentDisplay;
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    return Material(
      color: MyTheme.canvasColor.withAlpha(220),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < pi.displays.length; ++i)
              _displayButton(i, cur, numColorUnselected, numBgSelected),
          ],
        ),
      ),
    );
  }

  Widget _displayButton(
      int display, int current, Color numColorUnselected, Color numBgSelected) {
    final selected = display == current;
    return Semantics(
      button: true,
      selected: selected,
      label: '${translate('Display')} ${display + 1}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _select(display),
        child: Ink(
          width: _displaySize,
          height: _displaySize,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).hintColor),
            borderRadius: BorderRadius.circular(4),
            color: selected ? numBgSelected : null,
          ),
          child: Center(
            child: Text('${display + 1}',
                style: TextStyle(
                    color: selected ? Colors.white : numColorUnselected,
                    fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ffiModel = widget.ffi.ffiModel;
    // The current display and the display list change on their own, both are
    // tracked below: the former notifies [FfiModel], the latter is an RxList.
    return ListenableBuilder(
      listenable: ffiModel,
      builder: (context, _) => Obx(() {
        final pi = ffiModel.pi;
        if (!canSwitchDisplays(
            pi, PrivacyModeState.find(widget.peerId).value)) {
          _clearBlockedRect();
          return const SizedBox.shrink();
        }
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _updateBlockedRect());
        return TapRegion(
          onTapOutside: _open ? (_) => setState(() => _open = false) : null,
          child: Column(
            key: _key,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _button(pi),
              if (_open && pi.displays.length > 2)
                Padding(
                    padding: const EdgeInsets.only(top: 4), child: _panel(pi)),
            ],
          ),
        );
      }),
    );
  }
}
