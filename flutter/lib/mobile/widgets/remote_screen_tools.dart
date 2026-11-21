import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:zxing2/qrcode.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/quick_share.dart';
import '../../models/remote_qr.dart';
import 'multi_display.dart';

/// Looks for QR codes on the remote screen while its frames come in, so the
/// remote page can offer them without being asked. It looks once the screen
/// settles, and no more than every few seconds while it keeps changing.
class RemoteQrWatcher extends ChangeNotifier {
  RemoteQrWatcher(this._ffi, [this._multiDisplay]) {
    _enabled = bind.mainGetLocalOption(key: kOptionDetectRemoteQr) != 'N';
    _ffi.imageModel.addListener(_onFrame);
    _multiDisplay?.repaint.addListener(_onFrame);
  }

  final FFI _ffi;
  final MobileMultiDisplay? _multiDisplay;
  late bool _enabled;
  bool _busy = false;
  bool _dirty = false;
  bool _disposed = false;
  bool _dismissed = false;
  Timer? _timer;
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);
  List<QrHit> _hits = const [];

  static const _settle = Duration(milliseconds: 700);
  static const _minGap = Duration(seconds: 3);

  bool get enabled => _enabled;

  /// The codes on the screen at the last look, unless dismissed.
  List<QrHit> get hits => _dismissed ? const [] : _hits;

  /// The codes on the screen at the last look.
  List<QrHit> get latest => _hits;

  set enabled(bool on) {
    if (_enabled == on) return;
    _enabled = on;
    bind.mainSetLocalOption(key: kOptionDetectRemoteQr, value: on ? '' : 'N');
    _timer?.cancel();
    _timer = null;
    _hits = const [];
    if (on) _onFrame();
    notifyListeners();
  }

  /// Hides the codes on the screen; codes show again after a look finds none.
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  void _onFrame() {
    _dirty = true;
    _schedule();
  }

  void _schedule([Duration? wait]) {
    if (!_enabled || _busy || _timer != null || _disposed) return;
    if (wait == null) {
      wait = _settle;
      final gap = _lastScan.add(_minGap).difference(DateTime.now());
      if (gap > wait) wait = gap;
    }
    _timer = Timer(wait, _scan);
  }

  Future<void> _scan() async {
    _timer = null;
    if (!_enabled || !_dirty || _disposed) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _schedule(_minGap);
      return;
    }
    final images = _shownImages(_ffi, _multiDisplay);
    if (images.isEmpty) return;
    _dirty = false;
    _busy = true;
    _lastScan = DateTime.now();
    final found = <QrHit>[];
    try {
      for (final image in images) {
        _addNew(found, await scanImage(image));
      }
    } catch (e) {
      debugPrint('QR scan failed: $e');
    } finally {
      for (final image in images) {
        image.dispose();
      }
      _busy = false;
    }
    if (_disposed || !_enabled) return;
    if (found.isEmpty) _dismissed = false;
    if (!sameQrTexts(found, _hits)) {
      _hits = found;
      notifyListeners();
    }
    if (_dirty) _schedule();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _ffi.imageModel.removeListener(_onFrame);
    _multiDisplay?.repaint.removeListener(_onFrame);
    super.dispose();
  }
}

/// Copies of the frames the remote page shows: the main display's, and in
/// the all-displays view the others'. The caller disposes them.
List<ui.Image> _shownImages(FFI ffi, MobileMultiDisplay? multiDisplay) {
  final main = ffi.imageModel.image;
  return [
    if (main != null) main.clone(),
    if (multiDisplay != null && multiDisplay.active)
      for (var i = 0; i < ffi.ffiModel.pi.displays.length; i++)
        if (multiDisplay.imageOf(i) case final im? when im != main) im.clone(),
  ];
}

void _addNew(List<QrHit> to, List<QrHit> hits) {
  for (final hit in hits) {
    if (!to.any((h) => h.text == hit.text)) to.add(hit);
  }
}

/// Lossless captures of the PC's screen, for the mobile remote page.
class RemoteScreenshots {
  RemoteScreenshots(this.ffi);

  final FFI ffi;
  Completer<String>? _pending;

  bool get supported =>
      bind.sessionGetCommonSync(
              sessionId: ffi.sessionId,
              key: 'is_screenshot_supported',
              param: '') ==
          'true' &&
      ffi.ffiModel.pi.currentDisplay != kAllDisplayValue;

  /// Asks the PC for a capture of the display being shown. Completes with a
  /// PNG file for the caller to delete, or fails with the PC's reason.
  Future<String> capture() {
    final pending = _pending;
    if (pending != null) return pending.future;
    final c = Completer<String>();
    _pending = c;
    bind.sessionTakeScreenshot(
        sessionId: ffi.sessionId, display: ffi.ffiModel.pi.currentDisplay);
    ffi.ffiModel.timerScreenshot?.cancel();
    ffi.ffiModel.timerScreenshot = Timer(const Duration(seconds: 30), () {
      ffi.ffiModel.timerScreenshot = null;
      _finish(error: translate('Timeout'));
    });
    return c.future;
  }

  /// The PC's answer: an error, or a capture the session holds until told
  /// where to write it.
  Future<void> onResponse(String msg) async {
    if (_pending == null) {
      await bind.sessionHandleScreenshot(sessionId: ffi.sessionId, action: '2');
      return;
    }
    if (msg.isNotEmpty) {
      _finish(error: msg);
      return;
    }
    try {
      final path = '${(await getTemporaryDirectory()).path}/'
          'screenshot_${DateTime.now().microsecondsSinceEpoch}.png';
      final res = await bind.sessionHandleScreenshot(
          sessionId: ffi.sessionId, action: '0:$path');
      if (res.isEmpty) {
        _finish(path: path);
      } else {
        _finish(error: res);
      }
    } catch (e) {
      _finish(error: '$e');
    }
  }

  void _finish({String? path, String? error}) {
    final c = _pending;
    _pending = null;
    if (c == null || c.isCompleted) return;
    if (path != null) {
      c.complete(path);
    } else {
      c.completeError(error ?? '');
    }
  }

  void dispose() => _finish(error: '');
}

/// Shows the QR codes the watcher sees on the remote screen, in the top left
/// corner.
class RemoteQrChip extends StatefulWidget {
  const RemoteQrChip(
      {super.key,
      required this.ffi,
      required this.watcher,
      required this.onOpen});

  final FFI ffi;
  final RemoteQrWatcher watcher;
  final VoidCallback onOpen;

  @override
  State<RemoteQrChip> createState() => _RemoteQrChipState();
}

class _RemoteQrChipState extends State<RemoteQrChip> {
  final _key = GlobalKey();
  Rect? _blockedRect;

  @override
  void dispose() {
    _clearBlockedRect();
    super.dispose();
  }

  // Taps on the chip must not reach the remote screen below it.
  void _updateBlockedRect() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject();
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    if (box is! RenderBox || !box.hasSize || stack == null) return;
    final rect = stack.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
    if (rect == _blockedRect) return;
    _clearBlockedRect();
    widget.ffi.cursorModel.addBlockedRect(rect);
    _blockedRect = rect;
  }

  void _clearBlockedRect() {
    final rect = _blockedRect;
    if (rect != null) widget.ffi.cursorModel.removeBlockedRect(rect);
    _blockedRect = null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.watcher,
      builder: (context, _) {
        final hits = widget.watcher.hits;
        if (hits.isEmpty) {
          _clearBlockedRect();
          return const SizedBox.shrink();
        }
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _updateBlockedRect());
        final label = hits.length == 1
            ? qrLabel(QrContent.parse(hits.first.text))
            : '${hits.length} ${translate('QR codes')}';
        return Material(
          key: _key,
          color: MyTheme.accent,
          elevation: 4,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.qr_code_2, color: Colors.white, size: 20),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white)),
                ),
                Semantics(
                  button: true,
                  label: translate('Close'),
                  child: InkResponse(
                    onTap: widget.watcher.dismiss,
                    radius: 18,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.close, color: Colors.white70, size: 16),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      });
}

String qrLabel(QrContent c) => switch (c.kind) {
      QrKind.passkey => translate('Passkey sign-in'),
      QrKind.whatsapp => translate('WhatsApp login'),
      _ => c.label,
    };

String _title(QrKind kind) => translate(switch (kind) {
      QrKind.link => 'Link',
      QrKind.app => 'App link',
      QrKind.wifi => 'Wi-Fi network',
      QrKind.otp => '2FA setup key',
      QrKind.passkey => 'Passkey sign-in',
      QrKind.whatsapp => 'WhatsApp login',
      QrKind.email => 'Email',
      QrKind.phone => 'Phone number',
      QrKind.sms => 'SMS',
      QrKind.location => 'Location',
      QrKind.text => 'Text',
    });

String? _tip(QrKind kind) => switch (kind) {
      QrKind.passkey => translate(
          'A passkey from a phone needs Bluetooth next to the PC, so this only works when you are there. Pick another way to sign in on the PC.'),
      QrKind.whatsapp => translate(
          'WhatsApp reads this code only with its own camera. On the PC, choose "Log in with phone number" and enter the code it shows in WhatsApp under Linked devices.'),
      _ => null,
    };

/// The QR codes, with what the phone can do with each. With a [watcher], a
/// code that changes on the screen meanwhile, like a login code that renews,
/// shows its new content.
Future<void> showQrCodes(BuildContext context, List<QrHit> hits,
        {RemoteQrWatcher? watcher}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _QrSheet(hits: hits, watcher: watcher),
    );

class _QrSheet extends StatefulWidget {
  const _QrSheet({required this.hits, this.watcher});

  final List<QrHit> hits;
  final RemoteQrWatcher? watcher;

  @override
  State<_QrSheet> createState() => _QrSheetState();
}

class _QrSheetState extends State<_QrSheet> {
  late List<QrHit> _hits = widget.hits;

  @override
  void initState() {
    super.initState();
    widget.watcher?.addListener(_onWatcher);
  }

  @override
  void dispose() {
    widget.watcher?.removeListener(_onWatcher);
    super.dispose();
  }

  void _onWatcher() {
    final latest = widget.watcher!.latest;
    if (latest.isNotEmpty && !sameQrTexts(latest, _hits)) {
      setState(() => _hits = latest);
    }
  }

  @override
  Widget build(BuildContext context) {
    final watcher = widget.watcher;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.qr_code_2),
                title: Text(_hits.length == 1
                    ? translate('QR code')
                    : '${_hits.length} ${translate('QR codes')}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              for (final hit in _hits) _QrCard(hit: hit),
              if (watcher != null)
                SwitchListTile(
                  value: watcher.enabled,
                  onChanged: (on) => setState(() => watcher.enabled = on),
                  title: Text(
                      translate('Find QR codes on the screen automatically')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({required this.hit});

  final QrHit hit;

  @override
  Widget build(BuildContext context) {
    final c = QrContent.parse(hit.text);
    final theme = Theme.of(context);
    final tip = _tip(c.kind);
    final thumbnail = hit.thumbnail;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (thumbnail != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(thumbnail,
                        width: 64,
                        height: 64,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_title(c.kind),
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: MyTheme.accent)),
                    const SizedBox(height: 4),
                    SelectableText(c.text, maxLines: 5, minLines: 1),
                  ],
                ),
              ),
            ]),
            if (c.kind == QrKind.wifi) ...[
              _field(context, 'Network', c.wifiName),
              _field(context, 'Password', c.wifiPassword),
            ],
            if (c.kind == QrKind.otp) ...[
              _field(context, 'Account',
                  [c.otpIssuer, c.otpAccount].whereType<String>().join(': ')),
              _field(context, 'Setup key', c.otpSecret),
            ],
            if (tip != null)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tip)),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (c.canOpen)
                ElevatedButton.icon(
                  onPressed: () => _open(context, c.text),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(translate('Open')),
                ),
              OutlinedButton.icon(
                onPressed: () => _copy(c.text),
                icon: const Icon(Icons.copy, size: 18),
                label: Text(translate('Copy')),
              ),
              OutlinedButton.icon(
                onPressed: () => QuickShare.shareOut(text: c.text),
                icon: const Icon(Icons.share, size: 18),
                label: Text(translate('Share')),
              ),
              OutlinedButton.icon(
                onPressed: () => _saveQrImage(c.text),
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(translate('Save as image')),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _field(BuildContext context, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        SizedBox(
            width: 88,
            child: Text(translate(label),
                style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: SelectableText(value)),
        IconButton(
          onPressed: () => _copy(value),
          tooltip: translate('Copy'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy, size: 18),
        ),
      ]),
    );
  }
}

void _copy(String text) {
  Clipboard.setData(ClipboardData(text: text));
  showToast(translate('Copied'));
}

// What the phone camera does with a code: Android hands it to the app that
// takes it, the browser for web links. The raw text keeps the scheme's case,
// which Android matches exactly (FIDO:/ for one).
Future<void> _open(BuildContext context, String text) async {
  var ok = false;
  try {
    ok = await launchUrlString(text, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Cannot open $text: $e');
  }
  if (!ok) {
    showToast(translate('No app on this phone can open it'));
  } else if (context.mounted) {
    Navigator.of(context).pop();
  }
}

// A clean copy of the code, for apps that scan from a photo.
Future<void> _saveQrImage(String text) async {
  File? file;
  try {
    final png = await _qrPng(text);
    file = File('${(await getTemporaryDirectory()).path}/'
        'qr_${DateTime.now().microsecondsSinceEpoch}.png');
    await file.writeAsBytes(png);
    await QuickShare.saveToPictures(file.path, 'QR code ${_stamp()}.png');
    showToast(translate('Saved to Pictures/RustDesk'));
  } catch (e) {
    debugPrint('Saving the QR code failed: $e');
    showToast(_saveError(e));
  } finally {
    file?.delete().ignore();
  }
}

Future<Uint8List> _qrPng(String text) async {
  final m = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  const px = 16.0, quiet = 4;
  final side = (m.width + 2 * quiet) * px;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = Colors.white);
  final dark = Paint()..color = Colors.black;
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (m.get(x, y) == 1) {
        canvas.drawRect(
            Rect.fromLTWH((x + quiet) * px, (y + quiet) * px, px, px), dark);
      }
    }
  }
  final image =
      await recorder.endRecording().toImage(side.toInt(), side.toInt());
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

String _stamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
}

String _saveError(Object e) => e is PlatformException && e.code == 'unsupported'
    ? translate('Saving to the gallery needs Android 10 or newer')
    : translate('Failed');

/// Looks for QR codes on all the remote page shows. If there are none, a
/// lossless capture from the PC gets a second look, for a code the video
/// compression blurred.
Future<void> scanRemoteScreenForQr(BuildContext context, FFI ffi,
    {MobileMultiDisplay? multiDisplay,
    RemoteQrWatcher? watcher,
    RemoteScreenshots? screenshots}) async {
  final images = _shownImages(ffi, multiDisplay);
  var cancelled = false;
  final dialogs = ffi.dialogManager;
  var tag = dialogs.showLoading(translate('Looking for QR codes...'),
      onCancel: () => cancelled = true);
  final hits = <QrHit>[];
  try {
    for (final im in images) {
      if (cancelled) break;
      _addNew(hits, await scanImage(im, thorough: true));
    }
    if (hits.isEmpty &&
        !cancelled &&
        screenshots != null &&
        screenshots.supported) {
      dialogs.dismissByTag(tag);
      tag = dialogs.showLoading(
          translate('Getting a sharper picture from the PC...'),
          onCancel: () => cancelled = true);
      final file = File(await screenshots.capture());
      try {
        hits.addAll(await scanPng(await file.readAsBytes()));
      } finally {
        file.delete().ignore();
      }
    }
  } catch (e) {
    debugPrint('QR scan failed: $e');
  } finally {
    for (final im in images) {
      im.dispose();
    }
    dialogs.dismissByTag(tag);
  }
  if (cancelled || !context.mounted) return;
  if (hits.isEmpty) {
    showToast(translate('No QR code found on the screen'));
    return;
  }
  await showQrCodes(context, hits, watcher: watcher);
}

/// Saves a lossless capture of the PC's screen to the phone's pictures, then
/// offers to share or open it, for example in Google Lens to copy its text.
Future<void> takeRemoteScreenshot(
    BuildContext context, RemoteScreenshots screenshots) async {
  showToast('${translate('Taking screenshot')} ...');
  final String path;
  try {
    path = await screenshots.capture();
  } catch (e) {
    if ('$e'.isNotEmpty) showToast(translate('$e'));
    return;
  }
  final file = File(path);
  try {
    final png = await file.readAsBytes();
    final uri =
        await QuickShare.saveToPictures(path, 'RustDesk ${_stamp()}.png');
    if (uri == null || !context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ScreenshotSheet(png: png, uri: uri),
    );
  } catch (e) {
    debugPrint('Saving the screenshot failed: $e');
    showToast(_saveError(e));
  } finally {
    file.delete().ignore();
  }
}

class _ScreenshotSheet extends StatelessWidget {
  const _ScreenshotSheet({required this.png, required this.uri});

  final Uint8List png;
  final String uri;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height * 0.45),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(png,
                    fit: BoxFit.contain,
                    cacheWidth:
                        (size.width * MediaQuery.of(context).devicePixelRatio)
                            .round()),
              ),
            ),
            const SizedBox(height: 12),
            Text(translate('Saved to Pictures/RustDesk'),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ElevatedButton.icon(
                onPressed: () =>
                    QuickShare.shareOut(uri: uri, mime: 'image/png'),
                icon: const Icon(Icons.share, size: 18),
                label: Text(translate('Share')),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => QuickShare.openUri(uri),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(translate('Open')),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(translate('Close')),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Text another app shared with RustDesk goes to the PC's clipboard, through
/// the clipboard sync that runs when RustDesk comes back to the front. With
/// the clipboard off it can be typed instead.
Future<bool> sendSharedTextToPeer(FFI ffi, String text) async {
  final sessionId = ffi.sessionId;
  final m = ffi.ffiModel;
  final clipboardOff = m.viewOnly ||
      m.permissions['clipboard'] == false ||
      bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'disable-clipboard');
  if (!clipboardOff) {
    await Clipboard.setData(ClipboardData(text: text));
    // In case the sync on resume ran before the text was there.
    Future.delayed(const Duration(milliseconds: 600),
        () => ffi.invokeMethod('try_sync_clipboard'));
    showToast(translate("Sent to the PC's clipboard"));
    return true;
  }
  if (m.viewOnly || !m.keyboard) {
    showToast(translate('Clipboard is off for this session'));
    return true;
  }
  final type = await ffi.dialogManager
      .show<bool>((setState, close, context) => CustomAlertDialog(
            title: Text(translate('Clipboard is off for this session')),
            content: Text(translate('Type the text on the PC instead?')),
            actions: [
              dialogButton('Cancel',
                  onPressed: () => close(false), isOutline: true),
              dialogButton('Type it', onPressed: () => close(true)),
            ],
            onCancel: () => close(false),
          ));
  if (type == true) bind.sessionInputString(sessionId: sessionId, value: text);
  return true;
}
