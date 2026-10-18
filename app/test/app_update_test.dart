import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:famio/src/data/app_update.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late SimpleKeyPair keyPair;
  late String releaseKey;
  late Directory dir;
  late List<int> apk;
  late Map<String, Object?> offerJson;
  var served = <int>[];

  FamioApiClient api() => FamioApiClient(
    'https://famio.test',
    token: 't',
    httpClient: MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer t');
      expect(request.url.queryParameters['platform'], 'android');
      if (request.url.path == '/api/app-update') {
        return http.Response(jsonEncode(offerJson), 200);
      }
      if (request.url.path == '/api/app-update/download') {
        return http.Response.bytes(served, 200);
      }
      return http.Response('{}', 404);
    }),
  );

  Future<Map<String, Object?>> signedOffer(
    String version, {
    SimpleKeyPair? signer,
    String? file,
  }) async {
    final name = AppPlatform.android.fileName(version);
    final hash = await sha256Hex(Stream.value(apk));
    final sums = '$hash  $name\n${'c' * 64}  Famio-$version-macOS.zip\n';
    final signature = await Ed25519().sign(
      utf8.encode(sums),
      keyPair: signer ?? keyPair,
    );
    return {
      'version': version,
      'file': file ?? name,
      'size': apk.length,
      'sha256': hash,
      'sums': sums,
      'signature': base64Encode(signature.bytes),
    };
  }

  setUp(() async {
    keyPair = await Ed25519().newKeyPair();
    releaseKey = base64Encode((await keyPair.extractPublicKey()).bytes);
    dir = Directory.systemTemp.createTempSync('famio_update_');
    apk = utf8.encode('neues Famio');
    served = apk;
    offerJson = await signedOffer('2.1.0');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<File> download(AppUpdateOffer offer) => downloadUpdate(
    api(),
    offer,
    AppPlatform.android,
    into: dir,
    publicKey: releaseKey,
  );

  test('only a newer version is offered', () async {
    final newer = await availableUpdate(
      api(),
      platform: AppPlatform.android,
      appVersion: '2.0.0',
    );
    expect(newer?.version, '2.1.0');
    expect(
      await availableUpdate(
        api(),
        platform: AppPlatform.android,
        appVersion: '2.1.0',
      ),
      isNull,
    );
  });

  test(
    '64-bit phones take the smaller package, else the one for all',
    () async {
      var arm64 = false;
      final client = FamioApiClient(
        'https://famio.test',
        token: 't',
        httpClient: MockClient((request) async {
          final platform = request.url.queryParameters['platform'];
          if (platform == 'androidArm64' && !arm64) {
            // An older server or release: only the package for all phones.
            return http.Response('{"error":"not_found"}', 404);
          }
          final file = AppPlatform.byName(platform)!.fileName('2.1.0');
          return http.Response(jsonEncode({...offerJson, 'file': file}), 200);
        }),
      );
      final fallback = await availableUpdate(
        client,
        platform: AppPlatform.androidArm64,
        appVersion: '2.0.0',
      );
      expect(updatePlatformOf(fallback!), AppPlatform.android);
      arm64 = true;
      final smaller = await availableUpdate(
        client,
        platform: AppPlatform.androidArm64,
        appVersion: '2.0.0',
      );
      expect(smaller!.file, 'Famio-2.1.0-android-arm64.apk');
      expect(updatePlatformOf(smaller), AppPlatform.androidArm64);
    },
  );

  test('built-in recognition keeps a 64-bit phone on the big package', () {
    expect(
      androidUpdatePlatform(arm64: true, builtInModels: false),
      AppPlatform.androidArm64,
    );
    expect(
      androidUpdatePlatform(arm64: true, builtInModels: true),
      AppPlatform.android,
    );
    expect(
      androidUpdatePlatform(arm64: false, builtInModels: false),
      AppPlatform.android,
    );
  });

  test('a signed package is downloaded and checked', () async {
    final progress = <double>[];
    final file = await downloadUpdate(
      api(),
      AppUpdateOffer.fromJson(offerJson),
      AppPlatform.android,
      into: dir,
      publicKey: releaseKey,
      onProgress: progress.add,
    );
    expect(file.readAsBytesSync(), apk);
    expect(file.path, endsWith('Famio-2.1.0-android.apk'));
    expect(progress.last, 1);
  });

  test('without the release signature nothing is downloaded', () async {
    offerJson = await signedOffer(
      '2.1.0',
      signer: await Ed25519().newKeyPair(),
    );
    await expectLater(
      download(AppUpdateOffer.fromJson(offerJson)),
      throwsA(isA<AppUpdateError>()),
    );
    expect(dir.listSync(), isEmpty);
    // The real release key does not sign test packages either.
    await expectLater(
      downloadUpdate(
        api(),
        AppUpdateOffer.fromJson(await signedOffer('2.1.0')),
        AppPlatform.android,
        into: dir,
      ),
      throwsA(isA<AppUpdateError>()),
    );
  });

  test('a file name from the server cannot point elsewhere', () async {
    offerJson = await signedOffer('2.1.0', file: '../../famio');
    await expectLater(
      download(AppUpdateOffer.fromJson(offerJson)),
      throwsA(isA<AppUpdateError>()),
    );
  });

  test('a package changed on the way is thrown away', () async {
    served = utf8.encode('anderes Famio');
    await expectLater(
      download(AppUpdateOffer.fromJson(offerJson)),
      throwsA(isA<AppUpdateError>()),
    );
    expect(dir.listSync(), isEmpty);
  });
}
