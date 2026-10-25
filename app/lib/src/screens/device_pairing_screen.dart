import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../l10n.dart';
import '../widgets/trust_certificate.dart';
import 'pantry_screens.dart' show BarcodeScanScreen;

/// The already signed-in device approves exactly one new device.
class DevicePairingScreen extends StatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen> {
  DevicePairing? _pairing;
  var _busy = false;
  String? _error;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = await AppScope.read(
        context,
      ).engine!.api.createDevicePairing();
      if (mounted) setState(() => _pairing = pairing);
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pairing = _pairing;
    final link = pairing == null
        ? null
        : DevicePairLink(
            server: state.serverUrl!,
            secret: pairing.secret,
            pin: state.certificatePin,
          ).encode();
    return SectionPage(
      section: FamioSection.settings,
      maxBodyWidth: 640,
      title: tr.pairTitle,
      subtitle: tr.pairSubtitle,
      body: ListView(
        padding: EdgeInsets.only(bottom: listBottomPadding(context)),
        children: [
          SoftCard(child: Text(tr.pairSecurityHint)),
          const SizedBox(height: 16),
          if (pairing == null)
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(AppIcons.qrCode),
              label: Text(tr.pairCreate),
            )
          else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: QrImageView(
                  data: link!,
                  size: 260,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr.pairValidUntil(
                DateFormat.Hm(appLanguage).format(pairing.expiresAt),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(tr.pairCopied)));
                }
              },
              icon: const Icon(AppIcons.copy),
              label: Text(tr.pairCopy),
            ),
            TextButton(
              onPressed: _busy ? null : _create,
              child: Text(tr.pairReplace),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// The new device scans or pastes the approval and receives its own session.
class JoinPairedDeviceScreen extends StatefulWidget {
  const JoinPairedDeviceScreen({super.key});

  @override
  State<JoinPairedDeviceScreen> createState() => _JoinPairedDeviceScreenState();
}

class _JoinPairedDeviceScreenState extends State<JoinPairedDeviceScreen> {
  final _code = TextEditingController();
  var _busy = false;
  String? _error;

  static bool get _canScan => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => BarcodeScanScreen(qr: true, title: tr.pairScan),
      ),
    );
    if (text == null || !mounted) return;
    _code.text = text;
    await _join();
  }

  Future<void> _join() async {
    final link = DevicePairLink.parse(_code.text);
    if (link == null) {
      setState(() => _error = tr.pairInvalidCode);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String fold(String value) => value.replaceAll(':', '').toUpperCase();
    try {
      final state = AppScope.read(context);
      final resolved = await state.resolveServer(
        link.server,
        trust: (fingerprint) async =>
            (link.pin != null && fold(link.pin!) == fold(fingerprint)) ||
            await confirmCertificate(context, fingerprint),
      );
      await state.pairDevice(resolved, secret: link.secret);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FormatException {
      if (mounted) setState(() => _error = tr.settingsInvalidServerAddress);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr.pairJoinTitle)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(tr.pairJoinHint),
              const SizedBox(height: 16),
              if (_canScan) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(AppIcons.scanBarcode),
                  label: Text(tr.pairScan),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: tr.pairCode),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _join,
                child: Text(tr.pairJoin),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
