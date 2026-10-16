import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// A message: a JSON object whose `t` names its type.
typedef NetMessage = Map<String, Object?>;

/// A [NetMessage] encoded once for the wire: its JSON line, newline included,
/// in UTF-8.
extension type EncodedMessage._(Uint8List bytes) {
  /// Encodes [message].
  EncodedMessage(NetMessage message) : this._(utf8.encode('${jsonEncode(message)}\n'));
}

/// Web stub for [NetConnection] (raw TCP sockets are unavailable in browsers).
class NetConnection {
  /// Constructs a stub connection.
  NetConnection(this.socket);

  /// The underlying socket object.
  final Object socket;

  final Completer<void> _done = Completer<void>();

  /// Hands every message to [handler].
  void listen(void Function(NetMessage message)? handler) {}

  /// The next message.
  Future<NetMessage> next() => Completer<NetMessage>().future;

  /// Completes when the connection closes.
  Future<void> get done => _done.future;

  /// Whether the connection is closed.
  bool get isClosed => _done.isCompleted;

  /// Sends [message].
  void send(NetMessage message) => sendEncoded(EncodedMessage(message));

  /// Sends an already encoded [message].
  void sendEncoded(EncodedMessage message) {}

  /// Closes the connection.
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}
