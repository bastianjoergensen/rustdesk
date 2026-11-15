import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/wake_on_lan.dart';
import 'package:path_provider/path_provider.dart';

// The MACs LAN discovery recorded for peer [id]. Only mobile keeps the lan
// peers file in a directory Flutter knows.
Future<List<String>> _discoveredMacs(String id) async {
  if (!isAndroid && !isIOS) return [];
  try {
    final dir = await getApplicationDocumentsDirectory();
    final macs = <String>[];
    await for (final f in dir.list()) {
      if (f is File && f.path.endsWith('_lan_peers.toml')) {
        macs.addAll(macsFromLanPeers(await f.readAsString(), id));
      }
    }
    return macs;
  } catch (e) {
    debugPrint('Wake: cannot read LAN discovery results: $e');
    return [];
  }
}

/// Wakes peer [id] from sleep with a magic packet, on this network and over
/// the internet through a port the peer's router forwards to it.
///
/// [onClosed] runs once the dialog is gone, whether it woke the peer or not.
Future<void> showWakeDialog(String id, {VoidCallback? onClosed}) async {
  final mac = TextEditingController(
      text: bind.mainGetPeerOptionSync(id: id, key: kPeerOptionWakeMac));
  final address = TextEditingController(
      text: bind.mainGetPeerOptionSync(id: id, key: kPeerOptionWakeAddress));
  if (mac.text.isEmpty) {
    final found = await _discoveredMacs(id);
    if (found.isNotEmpty) mac.text = found.first;
  }
  String? note;
  var busy = false;

  gFFI.dialogManager.show((setState, closeDialog, context) {
    void close() {
      closeDialog();
      onClosed?.call();
    }

    Future<void> run(Future<void> Function() job) async {
      if (busy) return;
      setState(() {
        busy = true;
        note = null;
      });
      try {
        await job();
      } finally {
        busy = false;
        setState(() {});
      }
    }

    Future<void> findMac() => run(() async {
          await bind.mainDiscover();
          await Future.delayed(const Duration(seconds: 3));
          final found = await _discoveredMacs(id);
          if (found.isEmpty) {
            note = translate(
                'This device did not find the PC on this network. Open RustDesk on the PC and try again, or type its MAC address.');
          } else {
            mac.text = found.first;
          }
        });

    Future<void> findAddress() => run(() async {
          final ip = await routerPublicIp();
          if (ip == null) {
            note = translate(
                'The router did not answer. Type the address of your home network instead.');
          } else if (isUnreachableIPv4(ip)) {
            note = translate(
                'Your internet provider shares this address with other customers, so the PC can only be woken from this network.');
          } else {
            address.text = ip;
          }
        });

    Future<void> wake() => run(() async {
          final m = parseMac(mac.text);
          if (m == null) {
            note =
                translate("Enter the MAC address of the PC's network adapter.");
            return;
          }
          final a = address.text.trim();
          if (a.isNotEmpty && parseWakeAddress(a) == null) {
            note = translate(
                'Enter a host name or IP address, optionally with a port.');
            return;
          }
          await bind.mainSetPeerOption(
              id: id, key: kPeerOptionWakeMac, value: formatMac(m));
          await bind.mainSetPeerOption(
              id: id, key: kPeerOptionWakeAddress, value: a);
          await sendWake(m, address: a.isEmpty ? null : a);
          // RustDesk's own sender also tries every local network adapter.
          bind.mainWol(id: id);
          showToast(translate('Wake-up sent'));
          close();
        });

    return CustomAlertDialog(
      title: Text(translate('Wake up')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: mac,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: translate('MAC address'),
              hintText: 'aa:bb:cc:dd:ee:ff',
              suffixIcon: IconButton(
                tooltip: translate('Find on this network'),
                icon: const Icon(Icons.search),
                onPressed: busy ? null : findMac,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: address,
            enabled: !busy,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: translate('Address from the internet'),
              hintText: 'home.example.net:9',
              suffixIcon: IconButton(
                tooltip: translate('Use the address of this network'),
                icon: const Icon(Icons.router_outlined),
                onPressed: busy ? null : findAddress,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
              translate(
                  'To wake the PC from anywhere, forward UDP port 9 on your router to the PC, and allow its network adapter to wake it.'),
              style: Theme.of(context).textTheme.bodySmall),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(note!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        dialogButton('Wake up', onPressed: busy ? null : wake),
      ],
      onSubmit: wake,
      onCancel: close,
    );
  });
}

/// For "Remote desktop is offline" on mobile: the peer may only be asleep.
Widget wakeOfflinePeerButton(OverlayDialogManager dialogManager) {
  final id = gFFI.id;
  return dialogButton('Wake up', isOutline: true, onPressed: () {
    dialogManager.dismissAll();
    // The session page stays behind the dialog, so nothing tears it down
    // while it is open.
    showWakeDialog(id, onClosed: closeConnection);
  });
}
