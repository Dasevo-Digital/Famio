/// No database files in the browser (see `platform/storage_web.dart`).
Never openDeviceDatabase(String path, {String? hexKey}) =>
    throw UnsupportedError('No device database in the browser');
