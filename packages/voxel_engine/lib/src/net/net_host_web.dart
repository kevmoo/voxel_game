import 'dart:async';

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

/// Web stub for [NetHost] (raw TCP server sockets are unavailable in browsers).
class NetHost {
  NetHost._();

  /// Listens on [port]; throws [UnsupportedError] on web.
  static Future<NetHost> bind({int port = 7777}) =>
      Future.error(UnsupportedError('Raw TCP sockets are not supported on the web'));

  /// The port listened on.
  int get port => 0;

  /// The connected peers by id.
  final Map<int, NetPeer> peers = {};

  /// A client connected.
  void Function(NetPeer peer)? onJoin;

  /// A client sent a message.
  void Function(NetPeer peer, NetMessage message)? onMessage;

  /// A client left.
  void Function(NetPeer peer)? onLeave;

  /// Sends [message] to every peer but [except].
  void broadcast(NetMessage message, {int? except}) {}

  /// Stops listening and drops every peer.
  Future<void> close() async {
    peers.clear();
  }
}

/// Connects to a host at [address]:[port]; throws [UnsupportedError] on web.
Future<NetConnection> connectToHost(String address, {int port = 7777, Duration timeout = const Duration(seconds: 5)}) =>
    Future.error(UnsupportedError('Raw TCP sockets are not supported on the web'));
