import 'dart:io' show Platform;

/// Returns the current Dart runtime version token.
String get dartRuntimeVersion => Platform.version.split(' ').first;
