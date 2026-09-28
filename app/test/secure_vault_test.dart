import 'dart:convert';

import 'package:famio/src/secure_vault.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('moves separate entries into one and keeps it current', () async {
    FlutterSecureStorage.setMockInitialValues({
      'token': 't1',
      'deviceKey': 'k1',
      'certPin': 'p1',
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = await SecureVault.open(prefs);
    expect(vault.secure, isTrue);
    expect(await vault.read('token'), 't1');
    expect(await vault.deviceKey(), 'k1');

    const storage = FlutterSecureStorage();
    final all = await storage.readAll();
    expect(all.keys, ['famio']);

    await vault.write('token', null);
    await vault.write('certPin', 'p2');
    final again = await SecureVault.open(prefs);
    expect(await again.read('token'), isNull);
    expect(await again.read('certPin'), 'p2');
    expect(jsonDecode((await storage.read(key: 'famio'))!), {
      'deviceKey': 'k1',
      'certPin': 'p2',
    });
  });
}
