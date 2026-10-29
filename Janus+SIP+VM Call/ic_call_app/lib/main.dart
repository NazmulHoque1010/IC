// IC Call app
//
// Audio and video calls through the IC Janus servers, over the Janus
// WebSocket API. No FreeSWITCH and no SIP.
//
// No registration screen: the username is set when the app is built, and on
// start the app finds the Janus servers in two ways at the same time:
//   - LAN: broadcasts {"type":"discover"} (UDP 7088) and collects the answers;
//   - internet: connects to each SEED server (IC_SEEDS) over its WebSocket and
//     sends the AudioCall "list" request, which returns every server the seed
//     knows, with its public address (public_host) and its users.
// Then it joins the server with the FEWEST users (random pick on a tie) and
// registers the username on both plugins. A server found on the LAN is reached
// at its LAN address; the others at their public_host.
// The online users of every server are pushed by the plugin ("online" events).
//
//   flutter run -d <phone>  --dart-define=IC_USER=Nazmul
//   flutter run -d linux    --dart-define=IC_USER=Sazid
// Servers on the internet (one is enough, more are tried in case one is down):
//   --dart-define=IC_SEEDS=203.0.113.10,203.0.113.11   (host or host:port)
//
//   Audio calls: custom janus.plugin.audiocall plugin. Audio only (no camera).
//   Video calls: custom janus.plugin.customvideocall plugin (built from the
//                same source), with camera on/off and front/back switch.
//   Both work between users on the same OR the other Janus server.
//
// One Janus session holds two plugin handles (audio + video); the username is
// registered on both. Only one call (audio or video) can be active at a time.
//
// Runs on Android (flutter run on a phone) and on Linux (flutter run -d linux).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ignore_for_file: avoid_print

void main() {
  runApp(const ICCallApp());
}

/// This app's username, set at build time: --dart-define=IC_USER=Nazmul
const String kUsername = String.fromEnvironment('IC_USER');

/// Optional: Janus servers to ask over their WebSocket which servers exist,
/// for servers on the internet: --dart-define=IC_SEEDS=203.0.113.10,203.0.113.11
/// (host or host:port, comma-separated; the port defaults to 8188).
/// IC_SEED (one server) is still accepted as well.
const String kSeeds = String.fromEnvironment('IC_SEEDS');
const String kSeedServer = String.fromEnvironment('IC_SEED');

/// The seed servers from IC_SEEDS and IC_SEED, as (host, port).
List<(String, int)> parseSeeds() {
  final seeds = <(String, int)>[];
  for (final entry in '$kSeeds,$kSeedServer'.split(',')) {
    final text = entry.trim();
    if (text.isEmpty) continue;
    final colon = text.lastIndexOf(':');
    final port = colon > 0 ? int.tryParse(text.substring(colon + 1)) : null;
    final host = port != null ? text.substring(0, colon) : text;
    final seed = (host, port ?? 8188);
    if (!seeds.contains(seed)) seeds.add(seed);
  }
  return seeds;
}

/// UDP port the AudioCall plugin answers "discover" on (its link port).
const int kDiscoveryPort = 7088;

/// A Janus server found on the LAN or through a seed server.
class FoundServer {
  const FoundServer(this.name, this.host, this.port, this.users);

  final String name;
  final String host;
  final int port;
  final int users;
}
const String kAudioPlugin = 'janus.plugin.audiocall';
const String kVideoPlugin = 'janus.plugin.customvideocall';

/// Which plugin a call uses.
enum CallKind { audio, video }

/// Where the app is in a call.
enum CallPhase {
  idle, // no call
  calling, // we called someone, waiting for them to answer
  ringing, // someone is calling us, the Accept/Decline dialog is open
  connecting, // call answered, media connection being set up
  inCall, // media is flowing
}

class ICCallApp extends StatelessWidget {
  const ICCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IC Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const CallPage(),
    );
  }
}

class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  final TextEditingController _destinationController = TextEditingController();

  /// The Janus server we were placed on (found by discovery).
  String? _janusHost;
  int _janusPort = 8188;
  String? _assignedServer;
  String _serversSummary = '';
  Timer? _reconnectTimer;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Registration and call state
  // ---------------------------------------------------------------------------

  String _status = 'Starting...';
  bool _isRegistering = false;
  bool _isRegistered = false;
  bool _videoAvailable = false; // registered on the CustomVideoCall plugin too
  String? _registeredAs;

  CallPhase _phase = CallPhase.idle;
  CallKind _callKind = CallKind.audio;
  String _peerName = '';
  bool _peerIsRemote = false;

  DateTime? _callStartedAt;
  Timer? _callTimer;
  Duration _callDuration = Duration.zero;

  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isCameraOff = false;
  bool _isFrontCamera = true;
  bool _hasRemoteVideo = false;

  BuildContext? _incomingDialogContext;
  bool _incomingCancelledByCaller = false;

  // Online users, from the AudioCall plugin's "list" request
  String? _thisServerName;
  List<String> _localUsers = [];
  List<String> _peerUsers = []; // users on all the other servers
  List<MapEntry<String, List<String>>> _otherServers = []; // server -> users

  // ---------------------------------------------------------------------------
  // Janus WebSocket transport
  // ---------------------------------------------------------------------------

  int? _sessionId;
  int? _audioHandleId; // janus.plugin.audiocall
  int? _videoHandleId; // janus.plugin.customvideocall
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _keepAliveTimer;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, Completer<void>> _registrationCompleters = {};
  Future<void> _eventChain = Future<void>.value();
  int _transactionCounter = 0;

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCPeerConnection? _peerConnection;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  String get _janusWsUrl =>
      _janusHost == null ? '-' : 'ws://$_janusHost:$_janusPort';

  String get _platformName => Platform.isAndroid
      ? 'Android'
      : (Platform.isLinux ? 'Linux' : Platform.operatingSystem);

  /// The plugin handle the current call runs on.
  int? get _callHandleId =>
      _callKind == CallKind.audio ? _audioHandleId : _videoHandleId;

  String _kindName(CallKind kind) => kind == CallKind.audio ? 'audio' : 'video';

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
    // Register automatically as soon as the app is open
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoStart());
  }

  @override
  void dispose() {
    _disposed = true;
    _callTimer?.cancel();
    _keepAliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _destinationController.dispose();
    unawaited(_disposeWebRtc().then((_) {
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    }));
    unawaited(_closeWebSocket());
    super.dispose();
  }

  void _setStatus(String message) {
    print('STATUS: $message');
    if (!mounted) return;
    setState(() => _status = message);
  }

  String _newTransaction() {
    _transactionCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_transactionCounter';
  }

  // ---------------------------------------------------------------------------
  // WebSocket connection
  // ---------------------------------------------------------------------------

  Future<void> _connectWebSocket() async {
    await _closeWebSocket();
    final url = _janusWsUrl;
    _setStatus('Connecting to $url ...');

    final socket = await WebSocket.connect(
      url,
      protocols: ['janus-protocol'],
    ).timeout(const Duration(seconds: 10));
    socket.pingInterval = const Duration(seconds: 20);
    _socket = socket;

    _socketSub = socket.listen(
      _onSocketData,
      onError: (Object error) => print('DEBUG: WebSocket error: $error'),
      onDone: () => _onSocketDone(socket),
      cancelOnError: false,
    );
  }

  Future<void> _closeWebSocket() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    final subscription = _socketSub;
    final socket = _socket;
    _socketSub = null;
    _socket = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('WebSocket closed'));
      }
    }
    _pending.clear();

    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await socket?.close();
    } catch (_) {}
  }

  void _onSocketDone(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    _handleConnectionLost(
      'Connection to Janus closed (code ${socket.closeCode}).',
    );
  }

  void _handleConnectionLost(String reason) {
    print('CONNECTION LOST: $reason');
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(Exception(reason));
    }
    _pending.clear();
    _failRegistrations(reason);

    _closeIncomingDialog();
    unawaited(_disposeWebRtc());
    _stopCallTimer();

    if (!mounted) return;
    setState(() {
      _isRegistered = false;
      _videoAvailable = false;
      _registeredAs = null;
      _sessionId = null;
      _audioHandleId = null;
      _videoHandleId = null;
      _phase = CallPhase.idle;
      _status = '$reason Reconnecting...';
    });
    _scheduleReconnect(3);
  }

  void _failRegistrations(String reason) {
    for (final completer in _registrationCompleters.values) {
      if (!completer.isCompleted) completer.completeError(Exception(reason));
    }
  }

  void _onSocketData(dynamic data) {
    if (data is! String) return;
    print('DEBUG: WS <- $data');

    Map<String, dynamic> message;
    try {
      message = jsonDecode(data) as Map<String, dynamic>;
    } catch (error) {
      print('DEBUG: Invalid JSON from Janus: $error');
      return;
    }

    final type = message['janus'] as String?;
    final transaction = message['transaction'] as String?;

    // Replies to our requests (success / error / ack) complete the waiting request
    if (transaction != null &&
        (type == 'success' || type == 'error' || type == 'ack')) {
      final pending = _pending.remove(transaction);
      if (pending != null && !pending.isCompleted) {
        pending.complete(message);
        return;
      }
    }

    // Everything else (plugin events, timeouts) is handled in order
    _eventChain = _eventChain
        .then((_) => _handleJanusMessage(message))
        .catchError((Object error, StackTrace stackTrace) {
      print('EVENT HANDLER ERROR: $error');
      print(stackTrace);
    });
  }

  /// Sends a request and waits for Janus's success / ack / error reply.
  /// [handleId] addresses one of the plugin handles.
  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> payload, {
    bool needSession = true,
    int? handleId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = _socket;
    if (socket == null) throw Exception('Not connected to Janus');

    final transaction = _newTransaction();
    final message = <String, dynamic>{...payload, 'transaction': transaction};

    if (needSession) {
      final sessionId = _sessionId;
      if (sessionId == null) throw Exception('No Janus session');
      message['session_id'] = sessionId;
    }
    if (handleId != null) message['handle_id'] = handleId;

    final completer = Completer<Map<String, dynamic>>();
    _pending[transaction] = completer;

    final body = message['body'];
    print('DEBUG: WS -> ${message['janus']} '
        '${body is Map ? body['request'] ?? '' : ''} (handle ${handleId ?? '-'})');
    socket.add(jsonEncode(message));

    try {
      final response = await completer.future.timeout(timeout);
      if (response['janus'] == 'error') {
        final error = response['error'];
        final code = error is Map ? error['code'] : '';
        final reason = error is Map ? error['reason'] : error;
        throw Exception('Janus error $code: $reason');
      }
      return response;
    } on TimeoutException {
      _pending.remove(transaction);
      throw Exception('Janus did not answer "${payload['janus']}" '
          'within ${timeout.inSeconds}s');
    }
  }

  /// Sends a message without waiting for a reply (keepalive, trickle).
  void _sendNoWait(Map<String, dynamic> payload, {int? handleId}) {
    final socket = _socket;
    final sessionId = _sessionId;
    if (socket == null || sessionId == null) return;

    final message = <String, dynamic>{
      ...payload,
      'transaction': _newTransaction(),
      'session_id': sessionId,
    };
    if (handleId != null) message['handle_id'] = handleId;
    socket.add(jsonEncode(message));
  }

  /// Sends a request to one plugin handle (optionally with an SDP).
  Future<void> _pluginRequest(
    int? handleId,
    Map<String, dynamic> body, {
    Map<String, dynamic>? jsep,
  }) async {
    if (handleId == null) throw Exception('Plugin handle not attached');
    await _request(
      {
        'janus': 'message',
        'body': body,
        'jsep': ?jsep,
      },
      handleId: handleId,
      timeout: const Duration(seconds: 15),
    );
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _sendNoWait({'janus': 'keepalive'});
    });
  }

  // ---------------------------------------------------------------------------
  // Register / disconnect
  // ---------------------------------------------------------------------------

  /// Attaches a plugin and registers [username] on it.
  Future<int> _attachAndRegister(String plugin, String username) async {
    final attached = await _request({'janus': 'attach', 'plugin': plugin});
    final handleId = (attached['data'] as Map)['id'] as int;
    if (plugin == kAudioPlugin) {
      _audioHandleId = handleId;
    } else {
      _videoHandleId = handleId;
    }

    final registration = Completer<void>();
    registration.future.ignore();
    _registrationCompleters[handleId] = registration;
    try {
      await _pluginRequest(handleId, {'request': 'register', 'username': username});
      await registration.future.timeout(const Duration(seconds: 10));
    } finally {
      _registrationCompleters.remove(handleId);
    }
    return handleId;
  }

  /// Called once when the app opens.
  Future<void> _autoStart() async {
    if (kUsername.isEmpty) {
      _setStatus('No username set. Build the app with '
          '--dart-define=IC_USER=<name>, for example: '
          'flutter run --dart-define=IC_USER=Nazmul');
      return;
    }
    await _discoverAndRegister();
  }

  /// Asks the LAN which Janus servers exist: broadcasts {"type":"discover"}
  /// and collects the {"type":"here"} answers for about 1.5 seconds.
  Future<List<FoundServer>> _discoverLan() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final found = <String, FoundServer>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final m = jsonDecode(utf8.decode(datagram.data));
        if (m is Map && m['type'] == 'here') {
          final host = datagram.address.address;
          final name = (m['server'] ?? host).toString();
          found[name] = FoundServer(
            name,
            host,
            (m['ws_port'] as num?)?.toInt() ?? 8188,
            (m['users'] as num?)?.toInt() ?? 0,
          );
        }
      } catch (_) {}
    });

    final request = utf8.encode(jsonEncode({'type': 'discover'}));
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    // Sent twice: Wi-Fi can lose a broadcast
    for (var i = 0; i < 2; i++) {
      for (final target in targets) {
        try {
          socket.send(request, target, kDiscoveryPort);
        } catch (error) {
          print('DISCOVER SEND ERROR ($target): $error');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await subscription.cancel();
    socket.close();
    print('DISCOVER LAN: ${found.values.map((s) => '${s.name}@${s.host}=${s.users}').join(', ')}');
    return found.values.toList();
  }

  /// Asks one seed server, over its WebSocket, which servers exist: a short
  /// Janus session, the AudioCall "list" request (it works without
  /// registering), then the session is destroyed.
  Future<List<FoundServer>> _probeSeed(String host, int port) async {
    final socket = await WebSocket.connect(
      'ws://$host:$port',
      protocols: ['janus-protocol'],
    ).timeout(const Duration(seconds: 5));
    final waiting = <String, Completer<Map<String, dynamic>>>{};
    final listResult = Completer<Map<String, dynamic>>();
    final subscription = socket.listen(
      (dynamic data) {
        if (data is! String) return;
        Map<String, dynamic> m;
        try {
          m = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final type = m['janus'];
        if (type == 'event') {
          final pluginData = m['plugindata'];
          final pdata = pluginData is Map ? pluginData['data'] : null;
          final result = pdata is Map ? pdata['result'] : null;
          if (result is Map && result['list'] is List && !listResult.isCompleted) {
            listResult.complete(Map<String, dynamic>.from(result));
          }
          return;
        }
        final transaction = m['transaction'] as String?;
        if (transaction != null && (type == 'success' || type == 'error')) {
          final completer = waiting.remove(transaction);
          if (completer != null && !completer.isCompleted) completer.complete(m);
        }
      },
      onError: (Object error) => print('SEED $host:$port WebSocket error: $error'),
      cancelOnError: false,
    );

    Future<Map<String, dynamic>> send(Map<String, dynamic> message) async {
      final transaction = _newTransaction();
      final completer = Completer<Map<String, dynamic>>();
      waiting[transaction] = completer;
      socket.add(jsonEncode({...message, 'transaction': transaction}));
      final reply = await completer.future.timeout(const Duration(seconds: 5));
      if (reply['janus'] != 'success') {
        throw Exception('seed $host:$port refused "${message['janus']}": ${reply['error']}');
      }
      return reply;
    }

    int? sessionId;
    try {
      final created = await send({'janus': 'create'});
      sessionId = (created['data'] as Map)['id'] as int;
      final attached = await send({
        'janus': 'attach',
        'plugin': kAudioPlugin,
        'session_id': sessionId,
      });
      final handleId = (attached['data'] as Map)['id'] as int;
      socket.add(jsonEncode({
        'janus': 'message',
        'body': {'request': 'list'},
        'session_id': sessionId,
        'handle_id': handleId,
        'transaction': _newTransaction(),
      }));
      final result = await listResult.future.timeout(const Duration(seconds: 5));
      final servers = _serversFromList(result, host, port);
      print('SEED $host:$port: ${servers.map((s) => '${s.name}@${s.host}=${s.users}').join(', ')}');
      return servers;
    } finally {
      if (sessionId != null) {
        try {
          socket.add(jsonEncode({
            'janus': 'destroy',
            'session_id': sessionId,
            'transaction': _newTransaction(),
          }));
        } catch (_) {}
      }
      await subscription.cancel();
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  /// The servers in a "list" result: the server that answered (reached at its
  /// public_host, or at the seed address) and every server it knows (reached at
  /// their public_host, or their LAN address if they have none).
  List<FoundServer> _serversFromList(
    Map<String, dynamic> r,
    String seedHost,
    int seedPort,
  ) {
    int count(dynamic users) => users is List ? users.length : 0;
    final servers = <FoundServer>[];
    final self = r['server']?.toString();
    if (self != null) {
      servers.add(FoundServer(
        self,
        (r['public_host'] ?? seedHost).toString(),
        (r['ws_port'] as num?)?.toInt() ?? seedPort,
        count(r['list']),
      ));
    }
    if (r['servers'] is List) {
      for (final s in r['servers'] as List) {
        if (s is! Map || s['server'] == null) continue;
        final host = (s['public_host'] ?? s['ip'])?.toString();
        if (host == null || host.isEmpty || host == '?') continue;
        servers.add(FoundServer(
          s['server'].toString(),
          host,
          (s['ws_port'] as num?)?.toInt() ?? 8188,
          count(s['users']),
        ));
      }
    }
    return servers;
  }

  /// All the servers we can find: from the seed servers (internet) and the
  /// LAN broadcast, at the same time. A server found on the LAN keeps its LAN
  /// address (always reachable from here); the others use their public_host.
  Future<List<FoundServer>> _findServers() async {
    final seeds = parseSeeds();
    final results = await Future.wait<List<FoundServer>>([
      for (final (host, port) in seeds)
        _probeSeed(host, port).catchError((Object error) {
          print('SEED $host:$port failed: $error');
          return <FoundServer>[];
        }),
      _discoverLan().catchError((Object error) {
        print('DISCOVER LAN failed: $error');
        return <FoundServer>[];
      }),
    ]);
    final found = <String, FoundServer>{};
    for (final list in results) {
      for (final server in list) {
        found[server.name] = server; // the LAN answers come last and win
      }
    }
    return found.values.toList();
  }

  /// The server with the fewest users; a random one of them on a tie.
  FoundServer _pickServer(List<FoundServer> servers) {
    final fewest = servers.map((s) => s.users).reduce(min);
    final candidates = servers.where((s) => s.users == fewest).toList();
    return candidates[Random().nextInt(candidates.length)];
  }

  void _scheduleReconnect(int seconds) {
    _reconnectTimer?.cancel();
    if (_disposed || kUsername.isEmpty) return;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_discoverAndRegister());
    });
  }

  /// Find the servers, join the least busy one and register on both plugins.
  /// Retries every 5 seconds until it works.
  Future<void> _discoverAndRegister() async {
    if (_isRegistering || _isRegistered || _disposed || !mounted) return;
    _reconnectTimer?.cancel();
    final username = kUsername;

    setState(() {
      _isRegistering = true;
      _videoAvailable = false;
      _registeredAs = null;
      _phase = CallPhase.idle;
      _status = 'Looking for Janus servers...';
    });

    try {
      await _disposeWebRtc();
      await _closeWebSocket();
      _sessionId = null;
      _audioHandleId = null;
      _videoHandleId = null;

      final servers = await _findServers();
      if (servers.isEmpty) {
        final seeds = parseSeeds();
        throw Exception(seeds.isEmpty
            ? 'no Janus server answered on the LAN (no IC_SEEDS set)'
            : 'no Janus server answered (LAN, or seeds '
                '${seeds.map((s) => '${s.$1}:${s.$2}').join(', ')})');
      }
      final pick = _pickServer(servers);
      _serversSummary = servers
          .map((s) => '${s.name}: ${s.users} user${s.users == 1 ? '' : 's'}')
          .join(', ');
      _janusHost = pick.host;
      _janusPort = pick.port;
      _assignedServer = pick.name;
      _setStatus('Found $_serversSummary. Joining ${pick.name}...');

      await _connectWebSocket();

      _setStatus('Creating Janus session on ${pick.name}...');
      final created = await _request({'janus': 'create'}, needSession: false);
      _sessionId = (created['data'] as Map)['id'] as int;
      _startKeepAlive();

      // Audio (required): the custom AudioCall plugin
      _setStatus('Registering $username for audio calls...');
      await _attachAndRegister(kAudioPlugin, username);

      // Video (best effort): the CustomVideoCall plugin
      String videoNote = '';
      try {
        _setStatus('Registering $username for video calls...');
        await _attachAndRegister(kVideoPlugin, username);
        _videoAvailable = true;
      } catch (error) {
        print('VIDEO REGISTER ERROR: $error');
        videoNote = ' Video calls unavailable: $error';
      }

      if (!mounted) return;
      setState(() {
        _isRegistered = true;
        _registeredAs = username;
        _status = 'Registered as $username on ${pick.name} '
            '(servers found: $_serversSummary). '
            'Ready for audio${_videoAvailable ? ' and video' : ''} calls.'
            '$videoNote';
      });
      unawaited(_refreshUsers());
    } catch (error) {
      print('REGISTER ERROR: $error');
      _setStatus('Could not register as $username: $error. Retrying in 5 s...');
      await _closeWebSocket();
      _sessionId = null;
      _scheduleReconnect(5);
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  Future<void> _refreshUsers() async {
    if (!_isRegistered) return;
    try {
      // The AudioCall plugin lists users on this server AND the other server
      await _pluginRequest(_audioHandleId, {'request': 'list'});
    } catch (error) {
      print('LIST ERROR: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Plugin events
  // ---------------------------------------------------------------------------

  Future<void> _handleJanusMessage(Map<String, dynamic> message) async {
    final type = message['janus'] as String?;

    if (type == 'timeout') {
      unawaited(_closeWebSocket());
      _handleConnectionLost('Janus session timed out.');
      return;
    }
    if (type == 'hangup') {
      // Janus says a PeerConnection is gone; the plugin event follows
      print('DEBUG: Janus PeerConnection hangup: ${message['reason']}');
      return;
    }
    if (type != 'event') return;

    // Which plugin is this event from?
    final sender = message['sender'];
    final senderId = sender is num ? sender.toInt() : null;
    final CallKind? kind = senderId == null
        ? null
        : (senderId == _audioHandleId
            ? CallKind.audio
            : (senderId == _videoHandleId ? CallKind.video : null));
    if (kind == null) return;

    final pluginData = message['plugindata'];
    if (pluginData is! Map) return;
    final data = pluginData['data'];
    if (data is! Map) return;

    final jsepRaw = message['jsep'];
    final jsep = jsepRaw is Map ? Map<String, dynamic>.from(jsepRaw) : null;

    // Plugin errors, e.g. 476 username taken, 478 no such user, 484 audio only
    if (data['error'] != null) {
      final text = '${_kindName(kind)} error ${data['error_code'] ?? ''}: '
          '${data['error']}';
      print('PLUGIN ERROR: $text');
      final registration = _registrationCompleters[senderId];
      if (registration != null && !registration.isCompleted) {
        registration.completeError(Exception(text));
        return;
      }
      if (_phase != CallPhase.idle && kind == _callKind) {
        await _endCall(text);
      } else {
        _setStatus(text);
      }
      return;
    }

    final result = data['result'];
    if (result is! Map) return;
    final r = Map<String, dynamic>.from(result);

    // Reply to "list" (only requested from the AudioCall plugin)
    if (r['list'] is List) {
      if (kind == CallKind.audio) _updateUserLists(r);
      return;
    }

    final event = r['event'] as String?;
    print('DEBUG: ${_kindName(kind)} event: $event');

    // An incoming call on one plugin while we are busy on the other
    if (event == 'incomingcall' && _phase != CallPhase.idle) {
      await _sendHangup(senderId, 'Busy');
      return;
    }
    // Ignore events of the plugin that has no call right now
    if (event != 'registered' &&
        event != 'incomingcall' &&
        _phase != CallPhase.idle &&
        kind != _callKind) {
      return;
    }

    switch (event) {
      case 'registered':
        final registration = _registrationCompleters[senderId];
        if (registration != null && !registration.isCompleted) {
          registration.complete();
        }
        return;

      case 'calling':
        if (_phase == CallPhase.calling) {
          _peerIsRemote = r['remote'] == true;
          _setStatus('Ringing $_peerName'
              '${_peerIsRemote ? ' on the other server' : ''}...');
        }
        return;

      case 'incomingcall':
        final caller = (r['username'] ?? 'unknown').toString();
        final remote = r['remote'] == true;
        unawaited(_handleIncomingCall(kind, caller, remote, jsep));
        return;

      case 'accepted':
        // Caller side: carries the callee's answer. Callee side: no SDP.
        if (jsep != null && _phase == CallPhase.calling) {
          await _applyRemoteAnswer(jsep);
        }
        if (_phase == CallPhase.calling) {
          if (mounted) setState(() => _phase = CallPhase.connecting);
          _setStatus('$_peerName answered. Connecting...');
        }
        return;

      case 'hangup':
        await _handleHangupEvent(r);
        return;

      default:
        return; // 'set', 'update', 'simulcast', ...
    }
  }

  void _updateUserLists(Map<String, dynamic> r) {
    final me = _registeredAs;
    List<String> toList(dynamic value) => value is List
        ? value.map((e) => e.toString()).where((u) => u != me).toList()
        : <String>[];
    if (!mounted) return;
    setState(() {
      _thisServerName = r['server']?.toString();
      _localUsers = toList(r['list']);
      _peerUsers = toList(r['peer_list']);
      _otherServers = [
        if (r['servers'] is List)
          for (final s in r['servers'] as List)
            if (s is Map) MapEntry(s['server'].toString(), toList(s['users'])),
      ];
    });
  }

  Future<void> _handleHangupEvent(Map<String, dynamic> r) async {
    final reason = (r['reason'] ?? 'unknown').toString();

    // The caller gave up while our Accept/Decline dialog was open
    if (_phase == CallPhase.ringing) {
      _incomingCancelledByCaller = true;
      _closeIncomingDialog();
      return;
    }
    // Ignore the plugin's confirmation of a hangup we already handled
    if (_phase == CallPhase.idle) return;

    await _endCall('Call with $_peerName ended ($reason).');
  }

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  Future<RTCPeerConnection> _createMediaAndPeerConnection(CallKind kind) async {
    await _disposeWebRtc();
    final handleId = _callHandleId;

    // Audio calls never touch the camera
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': kind == CallKind.video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24},
            }
          : false,
    });
    if (stream.getAudioTracks().isEmpty) {
      throw Exception('No microphone found.');
    }
    _localStream = stream;
    _isFrontCamera = true;
    if (kind == CallKind.video) _localRenderer.srcObject = stream;
    _applyMute();
    _applyCamera();

    // LAN only: host candidates are enough, no STUN/TURN server needed
    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _peerConnection = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _sendNoWait({
        'janus': 'trickle',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      }, handleId: handleId);
    };

    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        _sendNoWait({
          'janus': 'trickle',
          'candidate': {'completed': true},
        }, handleId: handleId);
      }
    };

    pc.onTrack = (event) async {
      print('DEBUG: remote ${event.track.kind} track');
      if (event.track.kind != 'video') return; // remote audio plays by itself
      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      } else {
        _remoteStream ??= await createLocalMediaStream('remote');
        await _remoteStream!.addTrack(event.track);
        _remoteRenderer.srcObject = _remoteStream;
      }
      if (mounted) setState(() => _hasRemoteVideo = true);
    };

    pc.onConnectionState = (state) {
      print('DEBUG: PeerConnection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (_phase == CallPhase.connecting || _phase == CallPhase.calling) {
          if (mounted) setState(() => _phase = CallPhase.inCall);
          _startCallTimer();
          _setStatus('In ${_kindName(_callKind)} call with $_peerName'
              '${_peerIsRemote ? ' (other server)' : ''}.');
          unawaited(_applySpeaker());
        }
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_hangup(reason: 'Media connection failed'));
        _setStatus('Call failed: the media connection could not be set up.');
      }
    };

    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    await _applySpeaker();
    return pc;
  }

  Future<void> _applyRemoteAnswer(Map<String, dynamic> jsep) async {
    final pc = _peerConnection;
    final sdp = jsep['sdp'] as String?;
    final type = jsep['type'] as String?;
    if (pc == null || sdp == null || type == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
  }

  Future<void> _disposeWebRtc() async {
    final stream = _localStream;
    final remote = _remoteStream;
    final pc = _peerConnection;
    _localStream = null;
    _remoteStream = null;
    _peerConnection = null;
    _hasRemoteVideo = false;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    try {
      if (stream != null) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      }
      await remote?.dispose();
    } catch (error) {
      print('Stream cleanup warning: $error');
    }
    try {
      await pc?.close();
    } catch (error) {
      print('PeerConnection cleanup warning: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // In-call controls
  // ---------------------------------------------------------------------------

  void _applyMute() {
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !_isMuted;
    }
  }

  /// Camera off = the video track is disabled (the other side sees black).
  void _applyCamera() {
    for (final track
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !_isCameraOff;
    }
  }

  Future<void> _applySpeaker() async {
    if (!_isMobile) return; // the desktop always plays through its speakers
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
    } catch (error) {
      print('Speakerphone warning: $error');
    }
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    _applyMute();
  }

  void _toggleCamera() {
    setState(() => _isCameraOff = !_isCameraOff);
    _applyCamera();
  }

  Future<void> _switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      if (mounted) setState(() => _isFrontCamera = !_isFrontCamera);
    } catch (error) {
      print('Switch camera failed: $error');
    }
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    await _applySpeaker();
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callStartedAt = DateTime.now();
    _callDuration = Duration.zero;
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = _callStartedAt;
      if (start == null || !mounted) return;
      setState(() => _callDuration = DateTime.now().difference(start));
    });
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
    _callStartedAt = null;
  }

  // ---------------------------------------------------------------------------
  // Outgoing call
  // ---------------------------------------------------------------------------

  Future<void> _startCall(CallKind kind) async {
    final destination = _destinationController.text.trim();
    if (!_isRegistered) {
      _setStatus('Register first.');
      return;
    }
    if (destination.isEmpty) {
      _setStatus('Enter the username to call.');
      return;
    }
    if (destination == _registeredAs) {
      _setStatus("You can't call yourself.");
      return;
    }
    if (_phase != CallPhase.idle) return;
    if (kind == CallKind.video && !_videoAvailable) {
      _setStatus('Video calls are not available on this server.');
      return;
    }

    setState(() {
      _callKind = kind;
      _phase = CallPhase.calling;
      _peerName = destination;
      _peerIsRemote = _peerUsers.contains(destination);
      _isMuted = false;
      _isCameraOff = false;
      _isSpeakerOn = kind == CallKind.video; // video calls start on loudspeaker
      _status = kind == CallKind.video
          ? 'Preparing the camera and microphone...'
          : 'Preparing the microphone...';
    });

    try {
      final pc = await _createMediaAndPeerConnection(kind);
      final offer = await pc.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': kind == CallKind.video ? 1 : 0,
      });
      await pc.setLocalDescription(offer);

      _setStatus('Calling $destination (${_kindName(kind)})...');
      await _pluginRequest(
        _callHandleId,
        {'request': 'call', 'username': destination},
        jsep: {'type': offer.type, 'sdp': offer.sdp},
      );
    } catch (error) {
      print('CALL ERROR: $error');
      await _endCall('Call failed: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming call
  // ---------------------------------------------------------------------------

  Future<void> _handleIncomingCall(
    CallKind kind,
    String caller,
    bool remote,
    Map<String, dynamic>? jsep,
  ) async {
    final handleId = kind == CallKind.audio ? _audioHandleId : _videoHandleId;
    if (_phase != CallPhase.idle) {
      await _sendHangup(handleId, 'Busy');
      return;
    }
    if (jsep == null) {
      _setStatus('Incoming call from $caller had no SDP offer.');
      await _sendHangup(handleId, 'No SDP');
      return;
    }

    setState(() {
      _callKind = kind;
      _phase = CallPhase.ringing;
      _peerName = caller;
      _peerIsRemote = remote;
      _isMuted = false;
      _isCameraOff = false;
      _isSpeakerOn = kind == CallKind.video;
      _status = 'Incoming ${_kindName(kind)} call from $caller'
          '${remote ? ' (other server)' : ''}';
    });
    _incomingCancelledByCaller = false;

    final accept = await _showIncomingCallDialog(kind, caller, remote);
    _incomingDialogContext = null;

    if (_incomingCancelledByCaller) {
      _incomingCancelledByCaller = false;
      if (mounted) setState(() => _phase = CallPhase.idle);
      _setStatus('Missed ${_kindName(kind)} call from $caller (caller hung up).');
      return;
    }
    if (_phase != CallPhase.ringing) return; // connection lost meanwhile

    if (!accept) {
      if (mounted) setState(() => _phase = CallPhase.idle);
      await _sendHangup(handleId, 'Declined');
      _setStatus('Declined the call from $caller.');
      return;
    }

    try {
      setState(() {
        _phase = CallPhase.connecting;
        _status = 'Answering $caller...';
      });
      final pc = await _createMediaAndPeerConnection(kind);
      await pc.setRemoteDescription(
        RTCSessionDescription(jsep['sdp'] as String?, jsep['type'] as String?),
      );
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': kind == CallKind.video ? 1 : 0,
      });
      await pc.setLocalDescription(answer);
      await _pluginRequest(
        handleId,
        {'request': 'accept'},
        jsep: {'type': answer.type, 'sdp': answer.sdp},
      );
      _setStatus('Answered. Connecting with $caller...');
    } catch (error) {
      print('ACCEPT ERROR: $error');
      await _sendHangup(handleId, 'Answer failed');
      await _endCall('Could not answer: $error');
    }
  }

  Future<bool> _showIncomingCallDialog(
    CallKind kind,
    String caller,
    bool remote,
  ) async {
    if (!mounted) return false;
    final video = kind == CallKind.video;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _incomingDialogContext = dialogContext;
        return AlertDialog(
          icon: Icon(video ? Icons.videocam : Icons.call, size: 36),
          title: Text('Incoming ${video ? 'video' : 'audio'} call from $caller'),
          content: Text(remote
              ? 'This user is registered on the other Janus server.'
              : 'This user is registered on this Janus server.'),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              icon: const Icon(Icons.call_end, color: Colors.red),
              label: const Text('Decline'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: Icon(video ? Icons.videocam : Icons.call),
              label: const Text('Accept'),
            ),
          ],
        );
      },
    );
    return accepted ?? false;
  }

  void _closeIncomingDialog() {
    final dialogContext = _incomingDialogContext;
    _incomingDialogContext = null;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Hang up
  // ---------------------------------------------------------------------------

  /// Tells a plugin to end (or refuse) a call.
  Future<void> _sendHangup(int? handleId, String reason) async {
    if (_socket == null || handleId == null) return;
    try {
      await _pluginRequest(handleId, {'request': 'hangup', 'reason': reason});
    } catch (error) {
      print('HANGUP ERROR: $error');
    }
  }

  /// Local hang-up button.
  Future<void> _hangup({String reason = 'Hung up'}) async {
    if (_phase == CallPhase.idle) return;
    final peer = _peerName;
    final handleId = _callHandleId;
    await _endCall('Call with $peer ended.');
    await _sendHangup(handleId, reason);
  }

  /// Back to idle: release microphone, camera and PeerConnection.
  Future<void> _endCall(String status) async {
    _stopCallTimer();
    if (mounted) {
      setState(() {
        _phase = CallPhase.idle;
        _isMuted = false;
        _isSpeakerOn = false;
        _isCameraOff = false;
        _status = status;
      });
    }
    await _disposeWebRtc();
    unawaited(_refreshUsers());
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
  }

  String get _phaseText {
    switch (_phase) {
      case CallPhase.idle:
        return 'Idle';
      case CallPhase.calling:
        return 'Calling...';
      case CallPhase.ringing:
        return 'Incoming call';
      case CallPhase.connecting:
        return 'Connecting...';
      case CallPhase.inCall:
        return 'In call  ${_formatDuration(_callDuration)}';
    }
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  /// Shown until the app is registered.
  Widget _buildConnectingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_isRegistering || kUsername.isNotEmpty)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                kUsername.isEmpty
                    ? 'No username set'
                    : 'Connecting as $kUsername...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserChips(List<String> users, bool remote) {
    if (users.isEmpty) {
      return const Text('nobody else', style: TextStyle(color: Colors.grey));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final user in users)
          ActionChip(
            avatar: Icon(remote ? Icons.public : Icons.computer, size: 16),
            label: Text(user),
            onPressed: _phase == CallPhase.idle
                ? () => setState(() => _destinationController.text = user)
                : null,
          ),
      ],
    );
  }

  Widget _buildDialCard() {
    final idle = _phase == CallPhase.idle;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Online users',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _refreshUsers,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text('This server (${_thisServerName ?? _assignedServer ?? '?'}):'),
            const SizedBox(height: 4),
            _buildUserChips(_localUsers, false),
            const SizedBox(height: 8),
            if (_otherServers.isEmpty)
              const Text('No other servers found right now',
                  style: TextStyle(color: Colors.grey))
            else
              for (final server in _otherServers) ...[
                Text('Server ${server.key}:'),
                const SizedBox(height: 4),
                _buildUserChips(server.value, true),
                const SizedBox(height: 8),
              ],
            const Divider(height: 24),
            _input(
              _destinationController,
              'Username to call',
              enabled: idle,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: idle ? () => _startCall(CallKind.audio) : null,
                    icon: const Icon(Icons.call),
                    label: const Text('Audio call'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: idle && _videoAvailable
                        ? () => _startCall(CallKind.video)
                        : null,
                    icon: const Icon(Icons.videocam),
                    label: const Text('Video call'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Remote video full width, local preview in the corner.
  Widget _buildVideoArea() {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: _hasRemoteVideo
                    ? RTCVideoView(
                        _remoteRenderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      )
                    : const Center(
                        child: Icon(Icons.person, size: 96, color: Colors.white38),
                      ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              width: 96,
              height: 128,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  color: Colors.grey.shade900,
                  child: _isCameraOff
                      ? const Center(
                          child: Icon(Icons.videocam_off, color: Colors.white54),
                        )
                      : RTCVideoView(
                          _localRenderer,
                          mirror: _isFrontCamera,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallCard() {
    final scheme = Theme.of(context).colorScheme;
    final video = _callKind == CallKind.video;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (video) ...[
              _buildVideoArea(),
              const SizedBox(height: 8),
            ] else
              const Icon(Icons.person, size: 56),
            Text(
              _peerName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text(
              '${video ? 'Video' : 'Audio'} call'
              '${_peerIsRemote ? ' · other server' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(_phaseText, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 16,
              runSpacing: 12,
              children: [
                _roundButton(
                  icon: _isMuted ? Icons.mic_off : Icons.mic,
                  label: _isMuted ? 'Unmute' : 'Mute',
                  onPressed: _toggleMute,
                  active: _isMuted,
                ),
                if (video)
                  _roundButton(
                    icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
                    label: _isCameraOff ? 'Camera on' : 'Camera off',
                    onPressed: _toggleCamera,
                    active: _isCameraOff,
                  ),
                if (video && _isMobile)
                  _roundButton(
                    icon: Icons.cameraswitch,
                    label: 'Flip',
                    onPressed: _isCameraOff ? null : _switchCamera,
                  ),
                _roundButton(
                  icon: _isSpeakerOn ? Icons.volume_up : Icons.hearing,
                  label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                  onPressed: _isMobile ? _toggleSpeaker : null,
                  active: _isSpeakerOn,
                ),
                _roundButton(
                  icon: Icons.call_end,
                  label: 'Hang up',
                  onPressed: () => _hangup(),
                  color: Colors.red,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool active = false,
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          onPressed: onPressed,
          iconSize: 28,
          style: IconButton.styleFrom(
            backgroundColor: color ?? (active ? scheme.primary : scheme.surface),
            foregroundColor:
                (color != null || active) ? Colors.white : scheme.onSurface,
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(_status),
            const Divider(height: 24),
            SelectableText(
              'Platform: $_platformName\n'
              'Janus: $_janusWsUrl (${_socket != null ? 'connected' : 'disconnected'})\n'
              'Servers found: ${_serversSummary.isEmpty ? '-' : _serversSummary}\n'
              'Session: ${_sessionId ?? '-'}\n'
              'Audio handle: ${_audioHandleId ?? '-'}   '
              'Video handle: ${_videoHandleId ?? '-'}\n'
              'Registered: ${_registeredAs ?? 'no'}   '
              'Call: ${_phase.name}${_phase == CallPhase.idle ? '' : ' (${_kindName(_callKind)})'}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
    final showCall = _phase == CallPhase.calling ||
        _phase == CallPhase.connecting ||
        _phase == CallPhase.inCall;

    return Scaffold(
      appBar: AppBar(
        title: const Text('IC Call'),
        actions: [
          if (_isRegistered)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text('$_registeredAs @ ${_thisServerName ?? _assignedServer ?? '?'}'),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomPadding),
              children: [
                if (showCall) ...[
                  _buildCallCard(),
                  const SizedBox(height: 12),
                ],
                if (_isRegistered) _buildDialCard() else _buildConnectingCard(),
                const SizedBox(height: 12),
                _buildStatusCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
