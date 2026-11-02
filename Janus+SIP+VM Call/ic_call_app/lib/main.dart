// IC SIP Call app
//
// Audio and video calls through the IC servers: each VM runs Janus (WebRTC)
// and FreeSWITCH (SIP). The app talks only to Janus, over the Janus WebSocket
// API, and registers its name twice on the server it joins:
//   * janus.plugin.videocall - calls between app users. Janus connects the two
//     apps directly; FreeSWITCH is not involved and nothing is transcoded.
//   * janus.plugin.sip       - calls with SIP phones (e.g. MizuDroid). Janus
//     registers the name with the FreeSWITCH on the same VM, which converts
//     between the app's Opus and the phone's PCMU. Calls to phones are audio only.
// The status service says which online users are SIP phones; every other name
// is called through the VideoCall plugin (same server only).
//
// First start: the app asks for a name and remembers it. Every start after
// that it registers that name automatically, until "Disconnect & rename".
//
// Finding a server: the app asks the IC status service (HTTP, port 8190) of the
// seed servers which servers exist, where they are and who is registered. It
// joins the server with the FEWEST users (random pick on a tie); if its own
// name is still registered somewhere (app reopened quickly), it goes back there.
//
//   flutter run -d <phone> --dart-define=IC_SEEDS=203.0.113.10,203.0.113.11
//   flutter run -d linux   --dart-define=IC_SEEDS=203.0.113.10,203.0.113.11
// Optional: --dart-define=IC_STATUS_PORT=8190 (default 8190)
//
// Password: 1234 for every name (the FreeSWITCH servers accept any valid name).
// Names: lowercase, start with a letter, then letters/digits/. _ -, 2-32 chars.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore_for_file: avoid_print

void main() {
  runApp(const ICSipCallApp());
}

/// Seed servers (host or host:port of the status service), comma-separated:
/// --dart-define=IC_SEEDS=203.0.113.10,203.0.113.11
const String kSeeds = String.fromEnvironment('IC_SEEDS');

/// Port of the IC status service when a seed gives none.
const int kStatusPort = int.fromEnvironment('IC_STATUS_PORT', defaultValue: 8190);

const String kSipPlugin = 'janus.plugin.sip';
const String kVideoCallPlugin = 'janus.plugin.videocall';
const String kPassword = '1234';
const String kDefaultDomain = 'ic.local';
const String kPrefsName = 'ic_sip_username';

/// Same rule as the servers' ic_directory.lua and dialplan.
final RegExp kNameRule = RegExp(r'^[a-z][a-z0-9._-]{1,31}$');

/// The seed servers from IC_SEEDS, as (host, port).
List<(String, int)> parseSeeds() {
  final seeds = <(String, int)>[];
  for (final entry in kSeeds.split(',')) {
    final text = entry.trim();
    if (text.isEmpty) continue;
    final colon = text.lastIndexOf(':');
    final port = colon > 0 ? int.tryParse(text.substring(colon + 1)) : null;
    final host = port != null ? text.substring(0, colon) : text;
    final seed = (host, port ?? kStatusPort);
    if (!seeds.contains(seed)) seeds.add(seed);
  }
  return seeds;
}

/// One IC server, as reported by the status service.
class ServerInfo {
  const ServerInfo({
    required this.name,
    required this.host,
    required this.wsPort,
    required this.sipProxy,
    required this.domain,
    required this.users,
    required this.phones,
    required this.load,
    required this.online,
    required this.sipOk,
  });

  final String name;
  final String host; // public address of Janus and the status service
  final int wsPort; // Janus WebSocket port
  final String sipProxy; // where Janus reaches FreeSWITCH (sip:127.0.0.1:5060)
  final String domain; // SIP domain (ic.local)
  final List<String> users; // everyone online here (app users and SIP phones)
  final List<String> phones; // the users that are SIP phones (e.g. MizuDroid)
  final int? load;
  final bool online;
  final bool sipOk;

  /// Can a phone register here right now?
  bool get usable => online && sipOk && load != null;

  static ServerInfo? fromJson(Map<String, dynamic> j) {
    final name = j['server']?.toString();
    final host = j['public_host']?.toString();
    if (name == null || name.isEmpty || host == null || host.isEmpty) return null;
    return ServerInfo(
      name: name,
      host: host,
      wsPort: (j['ws_port'] as num?)?.toInt() ?? 8188,
      sipProxy: (j['sip_proxy'] ?? 'sip:127.0.0.1:5060').toString(),
      domain: (j['domain'] ?? kDefaultDomain).toString(),
      users: j['users'] is List
          ? (j['users'] as List).map((e) => e.toString()).toList()
          : <String>[],
      phones: j['phones'] is List
          ? (j['phones'] as List).map((e) => e.toString()).toList()
          : <String>[],
      load: (j['load'] as num?)?.toInt(),
      online: j['online'] == true,
      sipOk: j['sip_ok'] == true,
    );
  }
}

enum CallKind { audio, video }

/// Which Janus plugin carries the current call.
enum CallPath {
  videocall, // app <-> app, Janus only
  sip, // app <-> SIP phone, through FreeSWITCH
}

enum CallPhase {
  idle, // no call
  calling, // we called someone, waiting for them to answer
  ringing, // someone is calling us, the Accept/Decline dialog is open
  connecting, // call answered, media connection being set up
  inCall, // media is flowing
}

class ICSipCallApp extends StatelessWidget {
  const ICSipCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IC SIP Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
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
  // Name and server
  // ---------------------------------------------------------------------------

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  String? _nameError;
  bool _checkingName = false;

  bool _prefsLoaded = false;
  String? _savedName; // remembered on the phone; null = ask for a name
  ServerInfo? _server; // the server we joined
  String _serversSummary = '';
  List<ServerInfo> _servers = []; // latest status (all servers)
  Timer? _usersTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _userDisconnected = false; // "Disconnect & rename" in progress

  // ---------------------------------------------------------------------------
  // Registration and call state
  // ---------------------------------------------------------------------------

  String _status = 'Starting...';
  bool _isRegistering = false;
  bool _isRegistered = false;
  String? _registeredAs;
  Completer<void>? _registration;
  Completer<void>? _unregistration;
  Completer<void>? _vcRegistration;

  CallPhase _phase = CallPhase.idle;
  CallKind _callKind = CallKind.audio;
  CallPath _callPath = CallPath.videocall;
  String _peerName = '';

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

  // ---------------------------------------------------------------------------
  // Janus WebSocket transport
  // ---------------------------------------------------------------------------

  int? _sessionId;
  int? _sipHandleId;
  int? _vcHandleId; // VideoCall plugin handle
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _keepAliveTimer;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  Future<void> _eventChain = Future<void>.value();
  int _transactionCounter = 0;

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCPeerConnection? _peerConnection;
  bool _answerApplied = false; // caller side: callee's answer already set
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  String get _janusWsUrl =>
      _server == null ? '-' : 'ws://${_server!.host}:${_server!.wsPort}';

  String get _domain => _server?.domain ?? kDefaultDomain;

  String get _platformName => Platform.isAndroid
      ? 'Android'
      : (Platform.isLinux ? 'Linux' : Platform.operatingSystem);

  String _kindName(CallKind kind) => kind == CallKind.audio ? 'audio' : 'video';

  /// Is this online user a SIP phone (called through FreeSWITCH)?
  bool _isPhone(String user) => _servers.any((s) => s.phones.contains(user));

  /// The Janus handle that carries calls on [path].
  int? _handleFor(CallPath path) =>
      path == CallPath.sip ? _sipHandleId : _vcHandleId;

  /// A call (or ringing) is in progress on the other plugin than [path].
  bool _busyOnOtherPath(CallPath path) =>
      _phase != CallPhase.idle && _callPath != path;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNameAndStart());
  }

  @override
  void dispose() {
    _disposed = true;
    _callTimer?.cancel();
    _keepAliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _usersTimer?.cancel();
    _nameController.dispose();
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

  /// "sip:alice@ic.local" or "\"Alice\" <sip:alice@ic.local>" -> "alice"
  String _userFromUri(String? uri) {
    if (uri == null || uri.isEmpty) return 'unknown';
    final match = RegExp(r'sips?:([^@>;\s]+)').firstMatch(uri);
    return match?.group(1) ?? uri;
  }

  // ---------------------------------------------------------------------------
  // Saved name
  // ---------------------------------------------------------------------------

  Future<void> _loadNameAndStart() async {
    String? name;
    try {
      final prefs = await SharedPreferences.getInstance();
      name = prefs.getString(kPrefsName);
    } catch (error) {
      print('PREFS READ ERROR: $error');
    }
    if (!mounted) return;
    setState(() {
      _prefsLoaded = true;
      _savedName = (name != null && kNameRule.hasMatch(name)) ? name : null;
      _status = _savedName == null
          ? 'Choose a name to start.'
          : 'Connecting as $_savedName...';
    });
    if (parseSeeds().isEmpty) {
      _setStatus('No servers configured. Build the app with '
          '--dart-define=IC_SEEDS=<server1>,<server2>');
      return;
    }
    if (_savedName != null) unawaited(_connectAndRegister());
  }

  Future<void> _saveName(String? name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (name == null) {
        await prefs.remove(kPrefsName);
      } else {
        await prefs.setString(kPrefsName, name);
      }
    } catch (error) {
      print('PREFS WRITE ERROR: $error');
    }
  }

  /// "Continue" on the name screen: check the rules and that nobody uses it.
  Future<void> _submitName() async {
    if (_checkingName) return;
    final name = _nameController.text.trim().toLowerCase();
    if (!kNameRule.hasMatch(name)) {
      setState(() => _nameError =
          '2-32 characters: lowercase letters, digits, . _ -, starting with a letter');
      return;
    }
    if (parseSeeds().isEmpty) {
      setState(() => _nameError = 'No servers configured in this build (IC_SEEDS).');
      return;
    }
    setState(() {
      _checkingName = true;
      _nameError = null;
      _status = 'Checking that "$name" is free...';
    });
    try {
      final servers = await _findServers();
      if (servers.isEmpty) {
        throw Exception('no server answered');
      }
      final takenOn = servers.where((s) => s.users.contains(name)).toList();
      if (!mounted) return;
      if (takenOn.isNotEmpty) {
        setState(() => _nameError =
            '"$name" is already in use on ${takenOn.first.name}. Choose another name.');
        return;
      }
      await _saveName(name);
      if (!mounted) return;
      setState(() {
        _savedName = name;
        _userDisconnected = false;
      });
      unawaited(_connectAndRegister());
    } catch (error) {
      if (mounted) setState(() => _nameError = 'Could not reach the servers: $error');
    } finally {
      if (mounted) setState(() => _checkingName = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Finding a server (IC status service)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>?> _getStatus(String host, int port) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(Uri.parse('http://$host:$port/status'));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error) {
      print('STATUS $host:$port failed: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Every server the seeds know about, merged by name (an entry that says
  /// "online" wins over one that does not).
  Future<List<ServerInfo>> _findServers() async {
    final seeds = parseSeeds();
    final answers = await Future.wait([
      for (final (host, port) in seeds) _getStatus(host, port),
    ]);
    final merged = <String, ServerInfo>{};
    for (final answer in answers) {
      final list = answer?['servers'];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final info = ServerInfo.fromJson(Map<String, dynamic>.from(item));
        if (info == null) continue;
        final known = merged[info.name];
        if (known == null || (!known.online && info.online)) {
          merged[info.name] = info;
        }
      }
    }
    final servers = merged.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    print('SERVERS: ${servers.map((s) => '${s.name}@${s.host} load=${s.load} '
        'online=${s.online} sip=${s.sipOk}').join(', ')}');
    return servers;
  }

  /// Where our name is still registered (quick reopen) if anywhere, otherwise
  /// the usable server with the fewest users (random pick on a tie).
  ServerInfo? _pickServer(List<ServerInfo> servers, String name) {
    final usable = servers.where((s) => s.usable).toList();
    if (usable.isEmpty) return null;
    for (final s in usable) {
      if (s.users.contains(name)) return s;
    }
    final fewest = usable.map((s) => s.load!).reduce(min);
    final candidates = usable.where((s) => s.load == fewest).toList();
    return candidates[Random().nextInt(candidates.length)];
  }

  String _summary(List<ServerInfo> servers) => servers
      .map((s) => s.usable
          ? '${s.name}: ${s.load} user${s.load == 1 ? '' : 's'}'
          : '${s.name}: unavailable')
      .join(', ');

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
    _handleConnectionLost('Connection to Janus closed (code ${socket.closeCode}).');
  }

  void _handleConnectionLost(String reason) {
    print('CONNECTION LOST: $reason');
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _usersTimer?.cancel();
    _usersTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket = null;

    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(Exception(reason));
    }
    _pending.clear();
    final registration = _registration;
    if (registration != null && !registration.isCompleted) {
      registration.completeError(Exception(reason));
    }
    final vcRegistration = _vcRegistration;
    if (vcRegistration != null && !vcRegistration.isCompleted) {
      vcRegistration.completeError(Exception(reason));
    }

    _closeIncomingDialog();
    unawaited(_disposeWebRtc());
    _stopCallTimer();

    if (!mounted) return;
    setState(() {
      _isRegistered = false;
      _registeredAs = null;
      _sessionId = null;
      _sipHandleId = null;
      _vcHandleId = null;
      _phase = CallPhase.idle;
      _status = '$reason Reconnecting...';
    });
    _scheduleReconnect(3);
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

  /// Sends a request to the SIP plugin handle (optionally with an SDP).
  Future<void> _sipRequest(
    Map<String, dynamic> body, {
    Map<String, dynamic>? jsep,
  }) async {
    final handleId = _sipHandleId;
    if (handleId == null) throw Exception('SIP plugin not attached');
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

  /// Sends a request to the VideoCall plugin handle (optionally with an SDP).
  Future<void> _vcRequest(
    Map<String, dynamic> body, {
    Map<String, dynamic>? jsep,
  }) async {
    final handleId = _vcHandleId;
    if (handleId == null) throw Exception('VideoCall plugin not attached');
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

  /// Sends a call request (call / accept / hangup / decline) on [path].
  Future<void> _pathRequest(
    CallPath path,
    Map<String, dynamic> body, {
    Map<String, dynamic>? jsep,
  }) =>
      path == CallPath.sip
          ? _sipRequest(body, jsep: jsep)
          : _vcRequest(body, jsep: jsep);

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _sendNoWait({'janus': 'keepalive'});
    });
  }

  // ---------------------------------------------------------------------------
  // Register / disconnect
  // ---------------------------------------------------------------------------

  void _scheduleReconnect(int seconds) {
    _reconnectTimer?.cancel();
    if (_disposed || _userDisconnected || _savedName == null) return;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(_connectAndRegister());
    });
  }

  /// Find the servers, join the least busy one and register the saved name.
  /// Retries every 5 seconds until it works.
  Future<void> _connectAndRegister() async {
    final name = _savedName;
    if (name == null || _isRegistering || _isRegistered || _disposed || !mounted) {
      return;
    }
    _reconnectTimer?.cancel();

    setState(() {
      _isRegistering = true;
      _registeredAs = null;
      _phase = CallPhase.idle;
      _status = 'Looking for servers...';
    });

    try {
      await _disposeWebRtc();
      await _closeWebSocket();
      _sessionId = null;
      _sipHandleId = null;
      _vcHandleId = null;

      final servers = await _findServers();
      final pick = _pickServer(servers, name);
      if (pick == null) {
        throw Exception(servers.isEmpty
            ? 'no server answered (seeds: ${parseSeeds().map((s) => '${s.$1}:${s.$2}').join(', ')})'
            : 'no server is ready right now (${_summary(servers)})');
      }
      _servers = servers;
      _serversSummary = _summary(servers);
      _server = pick;
      _setStatus('Found $_serversSummary. Joining ${pick.name}...');

      await _connectWebSocket();

      _setStatus('Creating Janus session on ${pick.name}...');
      final created = await _request({'janus': 'create'}, needSession: false);
      _sessionId = (created['data'] as Map)['id'] as int;
      _startKeepAlive();

      final attached = await _request({'janus': 'attach', 'plugin': kSipPlugin});
      _sipHandleId = (attached['data'] as Map)['id'] as int;

      _setStatus('Registering $name on ${pick.name}...');
      final registration = Completer<void>();
      registration.future.ignore();
      _registration = registration;
      try {
        await _sipRequest({
          'request': 'register',
          'username': 'sip:$name@${pick.domain}',
          'secret': kPassword,
          'display_name': name,
          // registrar AND route for every request: the FreeSWITCH on this VM
          'proxy': pick.sipProxy,
          'outbound_proxy': pick.sipProxy,
        });
        await registration.future.timeout(const Duration(seconds: 15));
      } finally {
        _registration = null;
      }

      // Same name in the VideoCall plugin, for calls between app users
      final vcAttached =
          await _request({'janus': 'attach', 'plugin': kVideoCallPlugin});
      _vcHandleId = (vcAttached['data'] as Map)['id'] as int;
      _setStatus('Registering $name for app-to-app calls on ${pick.name}...');
      final vcRegistration = Completer<void>();
      vcRegistration.future.ignore();
      _vcRegistration = vcRegistration;
      try {
        await _vcRequest({'request': 'register', 'username': name});
        await vcRegistration.future.timeout(const Duration(seconds: 10));
      } finally {
        _vcRegistration = null;
      }

      if (!mounted) return;
      setState(() {
        _isRegistered = true;
        _registeredAs = name;
        _status = 'Registered as $name on ${pick.name} '
            '(servers: $_serversSummary). Ready for calls.';
      });
      _startUsersRefresh();
    } catch (error) {
      print('REGISTER ERROR: $error');
      _setStatus('Could not register as $name: $error. Retrying in 5 s...');
      await _closeWebSocket();
      _sessionId = null;
      _sipHandleId = null;
      _vcHandleId = null;
      _scheduleReconnect(5);
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  /// "Disconnect & rename": end any call, unregister so the name is free at
  /// once, forget the name and go back to the name screen.
  Future<void> _disconnectAndRename() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Disconnect and rename?'),
        content: Text(_savedName == null
            ? 'Go back to the name screen.'
            : '"$_savedName" will be unregistered and forgotten on this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    _userDisconnected = true;
    _reconnectTimer?.cancel();
    _usersTimer?.cancel();
    _usersTimer = null;
    _setStatus('Disconnecting...');

    if (_phase != CallPhase.idle) await _hangup();

    if (_isRegistered && _sipHandleId != null) {
      final unregistration = Completer<void>();
      unregistration.future.ignore();
      _unregistration = unregistration;
      try {
        await _sipRequest({'request': 'unregister'});
        await unregistration.future.timeout(const Duration(seconds: 4));
      } catch (error) {
        print('UNREGISTER: $error');
      } finally {
        _unregistration = null;
      }
    }
    if (_sessionId != null) {
      try {
        await _request({'janus': 'destroy'}, timeout: const Duration(seconds: 3));
      } catch (_) {}
    }
    await _closeWebSocket();
    await _disposeWebRtc();
    await _saveName(null);

    if (!mounted) return;
    setState(() {
      _isRegistered = false;
      _registeredAs = null;
      _savedName = null;
      _sessionId = null;
      _sipHandleId = null;
      _vcHandleId = null;
      _server = null;
      _servers = [];
      _serversSummary = '';
      _phase = CallPhase.idle;
      _nameController.clear();
      _nameError = null;
      _status = 'Disconnected. Choose a name to start.';
    });
  }

  // ---------------------------------------------------------------------------
  // Online users (status service of the server we joined)
  // ---------------------------------------------------------------------------

  void _startUsersRefresh() {
    _usersTimer?.cancel();
    unawaited(_refreshUsers());
    _usersTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshUsers());
    });
  }

  Future<void> _refreshUsers() async {
    final server = _server;
    if (server == null || !_isRegistered) return;
    final answer = await _getStatus(server.host, kStatusPort);
    // Our server's status service down: ask the seeds instead
    final servers = <ServerInfo>[];
    if (answer != null && answer['servers'] is List) {
      for (final item in answer['servers'] as List) {
        if (item is! Map) continue;
        final info = ServerInfo.fromJson(Map<String, dynamic>.from(item));
        if (info != null) servers.add(info);
      }
    } else {
      servers.addAll(await _findServers());
    }
    if (!mounted || servers.isEmpty) return;
    servers.sort((a, b) => a.name.compareTo(b.name));
    setState(() {
      _servers = servers;
      _serversSummary = _summary(servers);
    });
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
      // Janus says the PeerConnection is gone; the plugin's hangup event follows
      print('DEBUG: Janus PeerConnection hangup: ${message['reason']}');
      return;
    }
    if (type != 'event') return;

    final sender = message['sender'];
    if (sender is! num) return;
    final senderId = sender.toInt();
    if (senderId != _sipHandleId && senderId != _vcHandleId) return;

    final pluginData = message['plugindata'];
    if (pluginData is! Map) return;
    final data = pluginData['data'];
    if (data is! Map) return;

    final jsepRaw = message['jsep'];
    final jsep = jsepRaw is Map ? Map<String, dynamic>.from(jsepRaw) : null;

    if (senderId == _vcHandleId) {
      await _handleVideoCallEvent(Map<String, dynamic>.from(data), jsep);
      return;
    }

    // Plugin errors (bad request, wrong state, ...)
    if (data['error'] != null) {
      final text = 'SIP error ${data['error_code'] ?? ''}: ${data['error']}';
      print('PLUGIN ERROR: $text');
      final registration = _registration;
      if (registration != null && !registration.isCompleted) {
        registration.completeError(Exception(text));
        return;
      }
      // A SIP call that is still being set up fails; anything else is left
      // alone (e.g. the error came from refusing a second incoming call).
      if (_callPath == CallPath.sip &&
          (_phase == CallPhase.calling || _phase == CallPhase.connecting)) {
        await _endCall(text);
      } else {
        _setStatus(text);
      }
      return;
    }

    final result = data['result'];
    if (result is! Map) return;
    final r = Map<String, dynamic>.from(result);
    final event = r['event'] as String?;
    print('DEBUG: sip event: $event');

    // While an app-to-app (VideoCall) call is going on, SIP call events can
    // only belong to a phone call we are refusing: they must not touch it.
    final sipCallEvents = {
      'calling', 'ringing', 'progress', 'accepted', 'updatingcall', 'hangup',
    };
    if (sipCallEvents.contains(event) && _busyOnOtherPath(CallPath.sip)) {
      print('DEBUG: ignoring SIP $event during a ${_callPath.name} call');
      return;
    }

    switch (event) {
      case 'registering':
        return;

      case 'registered':
        final pendingReg = _registration;
        if (pendingReg != null && !pendingReg.isCompleted) {
          pendingReg.complete();
        }
        return;

      case 'registration_failed':
        final failText = 'registration failed: ${r['code'] ?? ''} ${r['reason'] ?? ''}';
        final failedReg = _registration;
        if (failedReg != null && !failedReg.isCompleted) {
          failedReg.completeError(Exception(failText));
        } else {
          // A refresh failed: start over
          _setStatus(failText);
          unawaited(_closeWebSocket());
          _handleConnectionLost('SIP $failText.');
        }
        return;

      case 'unregistered':
        final unregistration = _unregistration;
        if (unregistration != null && !unregistration.isCompleted) {
          unregistration.complete();
        }
        return;

      case 'calling':
        if (_phase == CallPhase.calling) _setStatus('Calling $_peerName...');
        return;

      case 'ringing':
        if (_phase == CallPhase.calling) _setStatus('Ringing $_peerName...');
        return;

      case 'progress':
        // Early media: the answer may already come here
        if (jsep != null && _phase == CallPhase.calling) {
          await _applyRemoteAnswer(jsep);
        }
        return;

      case 'accepted':
        // Caller side: carries the callee's answer (unless it came with
        // "progress"). Callee side: confirms our accept, no SDP.
        if (jsep != null && _phase == CallPhase.calling) {
          await _applyRemoteAnswer(jsep);
        }
        if (_phase == CallPhase.calling) {
          if (mounted) setState(() => _phase = CallPhase.connecting);
          _setStatus('$_peerName answered. Connecting...');
        }
        return;

      case 'incomingcall':
        final caller = _userFromUri(r['username']?.toString());
        unawaited(_handleIncomingCall(caller, jsep, CallPath.sip));
        return;

      case 'updatingcall':
        // re-INVITE from FreeSWITCH with a new offer: answer it right away
        if (jsep != null) await _handleUpdate(jsep);
        return;

      case 'hangup':
        await _handleHangupEvent(r);
        return;

      case 'missed_call':
        _setStatus('Missed call from ${_userFromUri(r['caller']?.toString())}.');
        return;

      default:
        return; // 'proceeding', 'info', 'message', 'notify', ...
    }
  }

  /// Events of the VideoCall plugin (calls between app users).
  Future<void> _handleVideoCallEvent(
    Map<String, dynamic> data,
    Map<String, dynamic>? jsep,
  ) async {
    if (data['error'] != null) {
      final code = (data['error_code'] as num?)?.toInt();
      final text = 'VideoCall error ${code ?? ''}: ${data['error']}';
      print('PLUGIN ERROR: $text');
      final registration = _vcRegistration;
      if (registration != null && !registration.isCompleted) {
        registration.completeError(Exception(code == 476
            ? 'the name is still held by a previous session, waiting for it to end'
            : text));
        return;
      }
      if (_callPath == CallPath.videocall &&
          (_phase == CallPhase.calling || _phase == CallPhase.connecting)) {
        // 478: no such username (not an app user on this server)
        await _endCall(code == 478 ? '$_peerName is not online on this server.' : text);
      } else {
        _setStatus(text);
      }
      return;
    }

    final result = data['result'];
    if (result is! Map) return;
    final r = Map<String, dynamic>.from(result);
    final event = r['event'] as String?;
    print('DEBUG: videocall event: $event');

    // While a phone (SIP) call is going on, VideoCall call events can only
    // belong to an app call we are refusing: they must not touch it.
    if (event != 'registered' && event != 'incomingcall' &&
        _busyOnOtherPath(CallPath.videocall)) {
      print('DEBUG: ignoring VideoCall $event during a ${_callPath.name} call');
      return;
    }

    switch (event) {
      case 'registered':
        final pending = _vcRegistration;
        if (pending != null && !pending.isCompleted) pending.complete();
        return;

      case 'calling':
        if (_phase == CallPhase.calling) _setStatus('Ringing $_peerName...');
        return;

      case 'incomingcall':
        final caller = (r['username'] ?? 'unknown').toString();
        unawaited(_handleIncomingCall(caller, jsep, CallPath.videocall));
        return;

      case 'accepted':
        // Caller side: carries the callee's answer. Callee side: no SDP.
        if (_phase == CallPhase.calling) {
          if (jsep != null) await _applyRemoteAnswer(jsep);
          if (mounted) setState(() => _phase = CallPhase.connecting);
          _setStatus('$_peerName answered. Connecting...');
        }
        return;

      case 'update':
        // Renegotiation: answer a new offer with "set"
        final pc = _peerConnection;
        if (pc != null && jsep != null && jsep['type'] == 'offer') {
          try {
            await pc.setRemoteDescription(
              RTCSessionDescription(jsep['sdp'] as String?, 'offer'),
            );
            final answer = await pc.createAnswer({});
            await pc.setLocalDescription(answer);
            await _vcRequest({'request': 'set'},
                jsep: {'type': answer.type, 'sdp': answer.sdp});
          } catch (error) {
            print('VIDEOCALL UPDATE ERROR: $error');
          }
        } else if (pc != null && jsep != null && jsep['type'] == 'answer') {
          await pc.setRemoteDescription(
            RTCSessionDescription(jsep['sdp'] as String?, 'answer'),
          );
        }
        return;

      case 'hangup':
        final reason = (r['reason'] ?? '').toString();
        if (_phase == CallPhase.ringing) {
          // The caller gave up while our Accept/Decline dialog was open
          _incomingCancelledByCaller = true;
          _closeIncomingDialog();
          return;
        }
        if (_phase == CallPhase.idle) return; // confirmation of our own hangup
        final busy = reason.toLowerCase().contains('busy');
        await _endCall(busy
            ? '$_peerName is busy.'
            : _phase == CallPhase.calling
                ? '$_peerName did not take the call.'
                : 'Call with $_peerName ended.');
        return;

      default:
        return; // 'simulcast', 'set', ...
    }
  }

  /// Turns a SIP hang-up code into words for the user.
  String _hangupText(int? code, String reason) {
    switch (code) {
      case 486:
      case 600:
        return '$_peerName is busy';
      case 603:
        return '$_peerName declined the call';
      case 480:
      case 404:
        return '$_peerName is not online';
      case 408:
        return '$_peerName did not answer';
      case 487:
        return 'Call cancelled';
      case 488:
        return 'Call failed: no common audio/video format';
      default:
        return 'Call with $_peerName ended ($reason)';
    }
  }

  Future<void> _handleHangupEvent(Map<String, dynamic> r) async {
    final code = (r['code'] as num?)?.toInt();
    final reason = (r['reason'] ?? 'unknown').toString();

    // The caller gave up while our Accept/Decline dialog was open
    if (_phase == CallPhase.ringing) {
      _incomingCancelledByCaller = true;
      _closeIncomingDialog();
      return;
    }
    // Ignore the plugin's confirmation of a hangup we already handled
    if (_phase == CallPhase.idle) return;

    await _endCall('${_hangupText(code, reason)}.');
  }

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  Future<RTCPeerConnection> _createMediaAndPeerConnection(
    CallKind kind,
    CallPath path,
  ) async {
    await _disposeWebRtc();
    final handleId = _handleFor(path); // trickle goes to the plugin of this call

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
    _answerApplied = false;
    _isFrontCamera = true;
    if (kind == CallKind.video) _localRenderer.srcObject = stream;
    _applyMute();
    _applyCamera();

    // Janus has a public address, so host candidates are enough (as in IC Call)
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
          _setStatus('In ${_kindName(_callKind)} call with $_peerName.');
          unawaited(_applySpeaker());
        }
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_hangup());
        _setStatus('Call failed: the media connection could not be set up.');
      }
    };

    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    await _applySpeaker();
    return pc;
  }

  /// Applies the callee's answer once (it can come with "progress" and again
  /// with "accepted").
  Future<void> _applyRemoteAnswer(Map<String, dynamic> jsep) async {
    final pc = _peerConnection;
    final sdp = jsep['sdp'] as String?;
    final type = jsep['type'] as String?;
    if (pc == null || sdp == null || type == null) return;
    if (_answerApplied) {
      print('DEBUG: answer already applied, ignoring the repeat');
      return;
    }
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _answerApplied = true;
  }

  /// re-INVITE: new offer from the other side, we answer with "update".
  Future<void> _handleUpdate(Map<String, dynamic> jsep) async {
    final pc = _peerConnection;
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(jsep['sdp'] as String?, jsep['type'] as String?),
      );
      final answer = await pc.createAnswer({});
      await pc.setLocalDescription(answer);
      await _sipRequest(
        {'request': 'update'},
        jsep: {'type': answer.type, 'sdp': answer.sdp},
      );
    } catch (error) {
      print('UPDATE ERROR: $error');
    }
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
    for (final track in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !_isMuted;
    }
  }

  /// Camera off = the video track is disabled (the other side sees black).
  void _applyCamera() {
    for (final track in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
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

  Future<void> _startCall(String destination, CallKind requestedKind) async {
    final target = destination.trim().toLowerCase();
    if (!_isRegistered) {
      _setStatus('Not registered yet.');
      return;
    }
    if (!kNameRule.hasMatch(target)) {
      _setStatus('"$destination" is not a valid name.');
      return;
    }
    if (target == _registeredAs) {
      _setStatus("You can't call yourself.");
      return;
    }
    if (_phase != CallPhase.idle) return;

    // SIP phones are called through FreeSWITCH (audio only); app users
    // directly through Janus's VideoCall plugin
    final path = _isPhone(target) ? CallPath.sip : CallPath.videocall;
    final kind = path == CallPath.sip ? CallKind.audio : requestedKind;
    if (kind != requestedKind) {
      print('DEBUG: $target is a SIP phone, calling with audio only');
    }

    setState(() {
      _callKind = kind;
      _callPath = path;
      _phase = CallPhase.calling;
      _peerName = target;
      _isMuted = false;
      _isCameraOff = false;
      _isSpeakerOn = kind == CallKind.video; // video calls start on loudspeaker
      _status = kind == CallKind.video
          ? 'Preparing the camera and microphone...'
          : 'Preparing the microphone...';
    });

    try {
      final pc = await _createMediaAndPeerConnection(kind, path);
      final offer = await pc.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': kind == CallKind.video ? 1 : 0,
      });
      await pc.setLocalDescription(offer);

      _setStatus(path == CallPath.sip
          ? 'Calling phone $target (audio, via FreeSWITCH)...'
          : 'Calling $target (${_kindName(kind)})...');
      await _pathRequest(
        path,
        path == CallPath.sip
            ? {'request': 'call', 'uri': 'sip:$target@$_domain'}
            : {'request': 'call', 'username': target},
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

  /// Does an SDP offer contain an active video stream?
  bool _offerHasVideo(String? sdp) {
    if (sdp == null) return false;
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('m=video ') && !line.startsWith('m=video 0 ')) return true;
    }
    return false;
  }

  Future<void> _handleIncomingCall(
    String caller,
    Map<String, dynamic>? jsep,
    CallPath path,
  ) async {
    if (_phase != CallPhase.idle) {
      await _refuse(path, 486); // Busy Here
      return;
    }
    if (jsep == null) {
      _setStatus('Incoming call from $caller had no SDP offer.');
      await _refuse(path, 488);
      return;
    }
    final kind = _offerHasVideo(jsep['sdp'] as String?) ? CallKind.video : CallKind.audio;

    setState(() {
      _callKind = kind;
      _callPath = path;
      _phase = CallPhase.ringing;
      _peerName = caller;
      _isMuted = false;
      _isCameraOff = false;
      _isSpeakerOn = kind == CallKind.video;
      _status = 'Incoming ${_kindName(kind)} call from $caller';
    });
    _incomingCancelledByCaller = false;

    final accept = await _showIncomingCallDialog(kind, caller);
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
      await _refuse(path, 603); // Decline
      _setStatus('Declined the call from $caller.');
      return;
    }

    try {
      setState(() {
        _phase = CallPhase.connecting;
        _status = 'Answering $caller...';
      });
      final pc = await _createMediaAndPeerConnection(kind, path);
      await pc.setRemoteDescription(
        RTCSessionDescription(jsep['sdp'] as String?, jsep['type'] as String?),
      );
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': kind == CallKind.video ? 1 : 0,
      });
      await pc.setLocalDescription(answer);
      await _pathRequest(
        path,
        {'request': 'accept'},
        jsep: {'type': answer.type, 'sdp': answer.sdp},
      );
      _setStatus('Answered. Connecting with $caller...');
    } catch (error) {
      print('ACCEPT ERROR: $error');
      await _refuse(path, 500);
      await _endCall('Could not answer: $error');
    }
  }

  Future<bool> _showIncomingCallDialog(CallKind kind, String caller) async {
    if (!mounted) return false;
    final video = kind == CallKind.video;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _incomingDialogContext = dialogContext;
        return AlertDialog(
          icon: Icon(video ? Icons.videocam : Icons.call, size: 36),
          title: Text('Incoming ${video ? 'video' : 'audio'} call'),
          content: Text('$caller is calling you.'),
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

  /// Refuses an incoming call: SIP with a code (486 busy, 603 declined, ...),
  /// VideoCall with a hangup (the plugin has no codes).
  Future<void> _refuse(CallPath path, int code) async {
    if (_socket == null || _handleFor(path) == null) return;
    try {
      if (path == CallPath.sip) {
        await _sipRequest({'request': 'decline', 'code': code});
      } else {
        await _vcRequest({'request': 'hangup'});
      }
    } catch (error) {
      print('REFUSE ERROR: $error');
    }
  }

  /// Local hang-up button (also cancels a call that is still ringing).
  Future<void> _hangup() async {
    if (_phase == CallPhase.idle) return;
    final peer = _peerName;
    final path = _callPath;
    await _endCall('Call with $peer ended.');
    if (_socket == null || _handleFor(path) == null) return;
    try {
      await _pathRequest(path, {'request': 'hangup'});
    } catch (error) {
      print('HANGUP ERROR: $error');
    }
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
    unawaited(_applySpeaker()); // back to earpiece routing
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

  /// First start (or after "Disconnect & rename"): choose a name.
  Widget _buildNameCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose your name', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('Others call you by this name. It is remembered on this '
                'phone and used every time the app opens.'),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              enabled: !_checkingName,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitName(),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. nazmul',
                helperText: 'lowercase letters, digits, . _ - (2-32, start with a letter)',
                errorText: _nameError,
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _checkingName ? null : _submitName,
              icon: _checkingName
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(_checkingName ? 'Checking...' : 'Continue'),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown while connecting / registering.
  Widget _buildConnectingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Connecting as $_savedName...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _disconnectAndRename,
                icon: const Icon(Icons.edit),
                label: const Text('Use a different name'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersCard() {
    final idle = _phase == CallPhase.idle;
    final me = _registeredAs;
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
            for (final server in _servers) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  'Server ${server.name}'
                  '${server.name == _server?.name ? ' (you are here)' : ''}'
                  '${server.usable ? '' : ' - unavailable'}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              if (server.users.where((u) => u != me).isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 8, bottom: 4),
                  child: Text('nobody else', style: TextStyle(color: Colors.grey)),
                )
              else
                for (final user in server.users.where((u) => u != me))
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 8),
                    leading: Icon(server.phones.contains(user)
                        ? Icons.phone_android
                        : (server.name == _server?.name ? Icons.person : Icons.public)),
                    title: Text(user),
                    subtitle: Text(server.phones.contains(user)
                        ? 'SIP phone (audio only)'
                        : 'app'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Audio call',
                          onPressed: idle ? () => _startCall(user, CallKind.audio) : null,
                          icon: const Icon(Icons.call),
                        ),
                        IconButton(
                          tooltip: 'Video call',
                          onPressed: idle && !server.phones.contains(user)
                              ? () => _startCall(user, CallKind.video)
                              : null,
                          icon: const Icon(Icons.videocam),
                        ),
                      ],
                    ),
                  ),
            ],
            const Divider(height: 24),
            TextField(
              controller: _destinationController,
              enabled: idle,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Or type a name to call',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: idle
                        ? () => _startCall(_destinationController.text, CallKind.audio)
                        : null,
                    icon: const Icon(Icons.call),
                    label: const Text('Audio call'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: idle
                        ? () => _startCall(_destinationController.text, CallKind.video)
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
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
            Text(_peerName, style: Theme.of(context).textTheme.headlineSmall),
            Text('${video ? 'Video' : 'Audio'} call',
                style: const TextStyle(fontSize: 12)),
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
                  onPressed: _hangup,
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
            foregroundColor: (color != null || active) ? Colors.white : scheme.onSurface,
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
              'Server: ${_server?.name ?? '-'}   Janus: $_janusWsUrl '
              '(${_socket != null ? 'connected' : 'disconnected'})\n'
              'Servers: ${_serversSummary.isEmpty ? '-' : _serversSummary}\n'
              'Session: ${_sessionId ?? '-'}   SIP handle: ${_sipHandleId ?? '-'}   '
              'VideoCall handle: ${_vcHandleId ?? '-'}\n'
              'Registered: ${_registeredAs == null ? 'no' : 'sip:$_registeredAs@$_domain + VideoCall $_registeredAs'}\n'
              'Call: ${_phase.name}${_phase == CallPhase.idle ? '' : ' (${_kindName(_callKind)}, '
                  '${_callPath == CallPath.sip ? 'SIP via FreeSWITCH' : 'VideoCall, Janus only'})'}',
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
    final needName = _prefsLoaded && _savedName == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('IC SIP Call'),
        actions: [
          if (_isRegistered)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: Text('$_registeredAs @ ${_server?.name ?? '?'}')),
            ),
          if (_savedName != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'rename') _disconnectAndRename();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.logout),
                    title: Text('Disconnect & rename'),
                  ),
                ),
              ],
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
                if (!_prefsLoaded)
                  const Center(child: CircularProgressIndicator())
                else if (needName)
                  _buildNameCard()
                else if (_isRegistered)
                  _buildUsersCard()
                else
                  _buildConnectingCard(),
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
