# Read by the Flutter Gradle plugin for release builds (R8).

# shared_preferences_android 2.5 calls its Kotlin code from Dart over JNI
# (package:jni). Both sides find classes and members by name: the plugin's
# suspend functions by a signature with kotlin.coroutines.Continuation, and
# package:jni the coroutine and Result classes below (lib/src/kotlin.dart).
# Renamed or removed by R8, the lookups fail at start and the app stays
# white (Famio 2.0.8 and 2.0.9 on Android).
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt* { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
