import 'dart:ffi';

/// Whether this app runs as 64-bit ARM code (Android: the phone can take
/// the smaller arm64 package).
bool get runsOnArm64 => Abi.current() == Abi.androidArm64;
