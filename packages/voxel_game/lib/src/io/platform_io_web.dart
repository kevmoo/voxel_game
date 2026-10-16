import 'dart:typed_data';

final Set<String> _dirs = <String>{'/'};
final Map<String, ({Uint8List? bytes, String? text, DateTime modified})> _files = {};

String _norm(String p) {
  var s = p.replaceAll(r'\', '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s.isEmpty ? '/' : s;
}

String _parentOf(String p) {
  final n = _norm(p);
  final i = n.lastIndexOf('/');
  if (i <= 0) return '/';
  return n.substring(0, i);
}

/// Base class for virtual web [File] and [Directory] entries.
abstract class FileSystemEntity {
  ///Normalized path.
  String get path;

  /// URI representation of [path].
  Uri get uri;

  /// Parent directory.
  Directory get parent => Directory(_parentOf(path));
}

/// Virtual in-memory [Directory] for web builds.
class Directory extends FileSystemEntity {
  /// Creates a directory handle at [path].
  Directory(String path) : path = _norm(path);

  @override
  final String path;

  @override
  Uri get uri => Uri.directory(path.startsWith('/') ? path.substring(1) : path);

  /// Whether this directory exists in the virtual store.
  bool existsSync() => _dirs.contains(path);

  /// Creates this directory (and parents when [recursive] is true).
  void createSync({bool recursive = false}) {
    if (recursive) {
      final parts = path.split('/').where((s) => s.isNotEmpty).toList();
      var cur = '';
      for (final part in parts) {
        cur = '$cur/$part';
        _dirs.add(cur);
      }
    } else {
      _dirs.add(path);
    }
  }

  /// Deletes this directory (and children when [recursive] is true).
  void deleteSync({bool recursive = false}) {
    _dirs.remove(path);
    if (recursive) {
      final prefix = '$path/';
      _dirs.removeWhere((d) => d.startsWith(prefix));
      _files.removeWhere((f, _) => f.startsWith(prefix));
    }
  }

  /// Lists immediate child [Directory] and [File] entries.
  List<FileSystemEntity> listSync() {
    final out = <FileSystemEntity>[];
    for (final d in _dirs) {
      if (d != path && _parentOf(d) == path) {
        out.add(Directory(d));
      }
    }
    for (final f in _files.keys) {
      if (_parentOf(f) == path) {
        out.add(File(f));
      }
    }
    return out;
  }
}

/// Virtual in-memory [File] for web builds.
class File extends FileSystemEntity {
  /// Creates a file handle at [path].
  File(String path) : path = _norm(path);

  @override
  final String path;

  @override
  Uri get uri => Uri.file(path.startsWith('/') ? path.substring(1) : path);

  /// Whether this file exists in the virtual store.
  bool existsSync() => _files.containsKey(path);

  /// Reads the file contents as a string.
  String readAsStringSync() {
    final entry = _files[path];
    if (entry == null || entry.text == null) {
      throw StateError('File not found: $path');
    }
    return entry.text!;
  }

  /// Writes [contents] to the file.
  void writeAsStringSync(String contents) {
    parent.createSync(recursive: true);
    _files[path] = (bytes: null, text: contents, modified: DateTime.now());
  }

  /// Reads the file contents as bytes.
  Uint8List readAsBytesSync() {
    final entry = _files[path];
    if (entry == null || entry.bytes == null) {
      throw StateError('File not found: $path');
    }
    return entry.bytes!;
  }

  /// Writes [bytes] to the file.
  void writeAsBytesSync(List<int> bytes) {
    parent.createSync(recursive: true);
    _files[path] = (bytes: Uint8List.fromList(bytes), text: null, modified: DateTime.now());
  }

  /// Renames this file to [newPath].
  File renameSync(String newPath) {
    final target = _norm(newPath);
    final entry = _files.remove(path);
    if (entry == null) {
      throw StateError('File not found: $path');
    }
    Directory(_parentOf(target)).createSync(recursive: true);
    _files[target] = entry;
    return File(target);
  }

  /// Last modification timestamp.
  DateTime lastModifiedSync() {
    final entry = _files[path];
    if (entry == null) {
      throw StateError('File not found: $path');
    }
    return entry.modified;
  }
}

/// Stub [SocketException] for web builds.
class SocketException implements Exception {
  /// Creates a [SocketException].
  const SocketException(this.message);

  /// Error message.
  final String message;

  @override
  String toString() => 'SocketException: $message';
}

/// Stub [InternetAddressType] for web builds.
enum InternetAddressType {
  /// IPv4 address family.
  IPv4,

  /// IPv6 address family.
  IPv6,

  /// Any address family.
  any,
}

/// Stub [InternetAddress] for web builds.
class InternetAddress {
  /// Creates an [InternetAddress].
  const InternetAddress(this.address);

  /// Address string.
  final String address;
}

/// Stub [NetworkInterface] for web builds.
class NetworkInterface {
  /// Creates a [NetworkInterface].
  const NetworkInterface(this.addresses);

  /// Addresses attached to this interface.
  final List<InternetAddress> addresses;

  /// Lists network interfaces (always empty on web).
  static Future<List<NetworkInterface>> list({InternetAddressType type = InternetAddressType.any}) async => const [];
}
