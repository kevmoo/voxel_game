import 'dart:async';
import 'dart:io';

import 'connection.dart';

/// A peer of a [NetHost]: its number and its connection.
class NetPeer {
  /// Peer [id] on [connection].
  NetPeer(this.id, this.connection);

  /// The number the host gave it (the host itself is 1; peers start at 2).
  final int id;

  /// The connection.
  final NetConnection connection;

  /// Sends [message] to this peer.
  void send(NetMessage message) => connection.send(message);
}

/// The authoritative side: listens on a port, numbers each client that joins
/// and tells the game through [onJoin], [onMessage] and [onLeave].
class NetHost {
  NetHost._(this._server) {
    _sub = _server.listen((socket) {
      final peer = NetPeer(_nextId++, NetConnection(socket));
      peers[peer.id] = peer;
      onJoin?.call(peer);
      peer.connection.listen((m) => onMessage?.call(peer, m));
      peer.connection.done.then((_) {
        if (peers.remove(peer.id) != null) onLeave?.call(peer);
        // The client hung up: release the host's end of the socket too.
        return peer.connection.close();
      });
    });
  }

  /// Listens on [port] of every interface (0 picks a free one).
  static Future<NetHost> bind({int port = 7777}) async =>
      NetHost._(await ServerSocket.bind(InternetAddress.anyIPv4, port));

  final ServerSocket _server;
  late final StreamSubscription<Socket> _sub;
  int _nextId = 2;

  /// The port listened on.
  int get port => _server.port;

  /// The connected peers by id.
  final Map<int, NetPeer> peers = {};

  /// A client connected.
  void Function(NetPeer peer)? onJoin;

  /// A client sent a message.
  void Function(NetPeer peer, NetMessage message)? onMessage;

  /// A client left.
  void Function(NetPeer peer)? onLeave;

  /// Sends [message] to every peer but [except], encoded once for all.
  void broadcast(NetMessage message, {int? except}) {
    if (peers.isEmpty) return;
    final encoded = EncodedMessage(message);
    for (final p in peers.values) {
      if (p.id != except) p.connection.sendEncoded(encoded);
    }
  }

  /// Stops listening and drops every peer.
  Future<void> close() async {
    await _sub.cancel();
    await _server.close();
    for (final p in List.of(peers.values)) {
      await p.connection.close();
    }
    peers.clear();
  }
}

/// Connects to a host at [address]:[port].
Future<NetConnection> connectToHost(
  String address, {
  int port = 7777,
  Duration timeout = const Duration(seconds: 5),
}) async => NetConnection(await Socket.connect(address, port, timeout: timeout));
