import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n.dart';

/// Opens the phone app with [number] (desktop: FaceTime, Teams & co.).
Future<void> callNumber(BuildContext context, String number) async {
  final messenger = ScaffoldMessenger.of(context);
  final digits = number.replaceAll(RegExp(r'[^0-9+]'), '');
  if (digits.isEmpty) return;
  final ok = await launchUrl(Uri(scheme: 'tel', path: digits));
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr.phoneCallingNotPossibleNumber(number))),
    );
  }
}

Future<void> writeMail(BuildContext context, String address) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await launchUrl(Uri(scheme: 'mailto', path: address.trim()));
  if (!ok) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr.phoneNoEmailAppFound(address))),
    );
  }
}
