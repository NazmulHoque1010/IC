// main.dart: IC Phone, a SIP phone app for the IC system.
//
// - Registers ONCE, through Janus (WebSocket 8188) and its SIP plugin, in FreeSWITCH
//   (profile "internal") as <name>@ic.local with password 1234. No database row needed.
// - Calls MizuDroid users and receives their calls. The app offers and accepts Opus
//   only; FreeSWITCH converts to each phone's group codec (A PCMU, B GSM, C PCMA).
// - Manages the MizuDroid users in MySQL through the status service (HTTP 8190):
//   add, rename, change group, delete.
// - Asks for a name once, remembers it and registers on every start until
//   "Disconnect & rename".
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- settings

// The VM with Janus, FreeSWITCH, the database and the status service.
const String kServer = String.fromEnvironment('IC_SERVER', defaultValue: '__IC_PUBLIC_IP__');
const int kJanusPort = 8188; // Janus WebSocket
const int kStatusPort = 8190; // status service: users API
const String kDomain = 'ic.local';
const String kSipProxy = 'sip:127.0.0.1:5060'; // FreeSWITCH "internal", seen from Janus
const String kPassword = '1234';
const String kNameKey = 'ic_name';
// Same name rule as the database and ic_directory.lua.
final RegExp kNameRule = RegExp(r'^[a-z][a-z0-9._-]{1,31}$');
// Same mapping as ic_directory.lua and ic_status.py.
const Map<String, String> kGroupCodec = {'A': 'PCMU', 'B': 'GSM', 'C': 'PCMA'};

final GlobalKey<ScaffoldMessengerState> kMessenger = GlobalKey<ScaffoldMessengerState>();

void _toast(String text) {
  kMessenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

// ---------------------------------------------------------------- Opus only

/// Keep only Opus in the audio part of an SDP: the app offers and accepts Opus only.
String opusOnly(String sdp) {
  final lines = sdp.split('\r\n');
  final opus = <String>{};
  for (final l in lines) {
    final m = RegExp(r'^a=rtpmap:(\d+) opus/48000', caseSensitive: false).firstMatch(l);
    if (m != null) opus.add(m.group(1)!);
  }
  if (opus.isEmpty) return sdp;
  final out = <String>[];
  var inAudio = false;
  for (final l in lines) {
    if (l.startsWith('m=')) {
      inAudio = l.startsWith('m=audio');
      if (inAudio) {
        // m=audio <port> <proto> <payload types...>: keep only the Opus payload type
        final parts = l.split(' ');
        out.add([...parts.take(3), ...parts.skip(3).where(opus.contains)].join(' '));
        continue;
      }
    }
    if (inAudio) {
      final m = RegExp(r'^a=(rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
      if (m != null && !opus.contains(m.group(2))) continue; // a line of a removed codec
    }
    out.add(l);
  }
  return out.join('\r\n');
}

// ---------------------------------------------------------------- Janus SIP

/// The app's only link to the server: one WebSocket to Janus, one Janus session,
/// one handle on the SIP plugin. Janus turns the app's WebRTC into plain SIP and RTP
/// towards FreeSWITCH.
class JanusSip {
  JanusSip(this.server);
  final String server;

  // Registration state: 'registering', 'registered', 'failed', 'disconnected'.
  void Function(String state, String? detail)? onRegistration;
  // Call events: 'incoming', 'calling', 'ringing', 'progress', 'accepted', 'hangup',
  // 'missed_call', 'error', and Janus's own 'janus_hangup'.
  void Function(String event, Map<String, dynamic> result)? onCallEvent;

  WebSocket? _ws;
  int? _session;
  int? _handle;
  bool _registered = false;
  Timer? _keepalive;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Random _random = Random();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  Map<String, dynamic>? _incomingJsep;
  bool _remoteSet = false;

  /// Open the WebSocket, create a Janus session and attach to the SIP plugin.
  Future<void> connect() async {
    _ws = await WebSocket.connect('ws://$server:$kJanusPort', protocols: ['janus-protocol'])
        .timeout(const Duration(seconds: 8));
    _ws!.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());
    final created = await _request({'janus': 'create'});
    _session = created['data']['id'] as int;
    final attached = await _request({'janus': 'attach', 'plugin': 'janus.plugin.sip'});
    _handle = attached['data']['id'] as int;
    // Janus drops a session after 60 s of silence; a keepalive every 25 s keeps it.
    _keepalive = Timer.periodic(const Duration(seconds: 25), (_) => _send({'janus': 'keepalive'}));
  }

  /// Register name@ic.local in FreeSWITCH through Janus. The result comes to onRegistration.
  Future<void> register(String name) async {
    onRegistration?.call('registering', null);
    await message({
      'request': 'register',
      'username': 'sip:$name@$kDomain',
      'display_name': name,
      'secret': kPassword,
      'proxy': kSipProxy,
      'outbound_proxy': kSipProxy,
    });
  }

  /// Call a SIP user: offer Opus only.
  Future<void> call(String name) async {
    await _openMedia();
    final offer = await _pc!.createOffer({});
    final local = RTCSessionDescription(opusOnly(offer.sdp!), offer.type);
    await _pc!.setLocalDescription(local);
    await message({'request': 'call', 'uri': 'sip:$name@$kDomain'},
        jsep: {'type': local.type, 'sdp': local.sdp});
  }

  /// Answer the incoming call: answer with Opus only.
  Future<void> accept() async {
    final offer = _incomingJsep;
    if (offer == null) throw StateError('no incoming call');
    _incomingJsep = null;
    await _openMedia();
    _remoteSet = true;
    await _pc!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String));
    final answer = await _pc!.createAnswer({});
    final local = RTCSessionDescription(opusOnly(answer.sdp!), answer.type);
    await _pc!.setLocalDescription(local);
    await message({'request': 'accept'}, jsep: {'type': local.type, 'sdp': local.sdp});
  }

  Future<void> decline() async {
    _incomingJsep = null;
    await message({'request': 'decline'});
  }

  /// Hang up: tell the server first, then close our audio.
  Future<void> hangup() async {
    try {
      await message({'request': 'hangup'});
    } catch (_) {}
    await closeMedia();
  }

  void setMuted(bool muted) {
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  /// Send a request to the SIP plugin (with an SDP for calls). Janus answers "ack"
  /// at once; the plugin's real answer comes later as an event.
  Future<void> message(Map<String, dynamic> body, {Map<String, dynamic>? jsep}) async {
    if (_ws == null || _handle == null) throw StateError('not connected to Janus');
    await _request({
      'janus': 'message',
      'handle_id': _handle,
      'body': body,
      if (jsep != null) 'jsep': jsep,
    });
  }

  /// Unregister and close everything (used by "Disconnect & rename").
  Future<void> close() async {
    await closeMedia();
    final ws = _ws;
    if (ws == null) return;
    try {
      if (_registered) await message({'request': 'unregister'});
      if (_session != null) await _request({'janus': 'destroy'});
    } catch (_) {}
    _ws = null; // closed on purpose: _onClosed will not report it
    _cleanup();
    await ws.close();
  }

  // ---- media ----

  Future<void> _openMedia() async {
    await closeMedia();
    _remoteSet = false;
    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ],
      'sdpSemantics': 'unified-plan',
    });
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    // Trickle ICE: send each of our network candidates to Janus as it is found.
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      _send({
        'janus': 'trickle',
        'handle_id': _handle,
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      });
    };
    _pc!.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        _send({'janus': 'trickle', 'handle_id': _handle, 'candidate': {'completed': true}});
      }
    };
  }

  Future<void> closeMedia() async {
    final pc = _pc;
    final stream = _localStream;
    _pc = null;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
  }

  Future<void> _setRemote(Map<String, dynamic> jsep) async {
    final pc = _pc;
    if (pc == null || _remoteSet) return;
    _remoteSet = true;
    await pc.setRemoteDescription(
        RTCSessionDescription(jsep['sdp'] as String, jsep['type'] as String));
  }

  // ---- messages ----

  Future<Map<String, dynamic>> _request(Map<String, dynamic> msg) {
    final tx = _newTransaction();
    final done = Completer<Map<String, dynamic>>();
    _pending[tx] = done;
    _send(msg, tx);
    return done.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(tx);
      throw TimeoutException('Janus did not answer "${msg['janus']}"');
    });
  }

  /// Every message carries a random transaction id; Janus's reply carries the same id.
  void _send(Map<String, dynamic> msg, [String? tx]) {
    msg['transaction'] = tx ?? _newTransaction();
    if (_session != null) msg['session_id'] = _session;
    _ws?.add(jsonEncode(msg));
  }

  String _newTransaction() => List.generate(
      12, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)]).join();

  void _onMessage(dynamic raw) {
    final msg = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    final type = msg['janus'] as String?;
    final tx = msg['transaction'] as String?;

    // A direct answer to one of our requests
    if (tx != null && (type == 'success' || type == 'ack' || type == 'error')) {
      final done = _pending.remove(tx);
      if (done != null) {
        if (type == 'error') {
          done.completeError(Exception('Janus: ${msg['error']?['reason']}'));
        } else {
          done.complete(msg);
        }
        return;
      }
    }

    // An event from the SIP plugin
    if (type == 'event') {
      final data = (msg['plugindata']?['data'] as Map?)?.cast<String, dynamic>();
      if (data == null) return;
      final jsep = (msg['jsep'] as Map?)?.cast<String, dynamic>();
      if (data['error'] != null) {
        final reason = '${data['error_code']} ${data['error']}';
        if (!_registered) {
          onRegistration?.call('failed', reason);
        } else {
          onCallEvent?.call('error', {'reason': reason});
        }
        return;
      }
      final result = (data['result'] as Map?)?.cast<String, dynamic>();
      if (result == null) return;
      final event = result['event']?.toString() ?? '';
      switch (event) {
        case 'registering':
          break;
        case 'registered':
          _registered = true;
          onRegistration?.call('registered', null);
        case 'registration_failed':
          _registered = false;
          onRegistration?.call('failed', '${result['code']} ${result['reason']}');
        case 'unregistered':
          _registered = false;
        case 'incomingcall':
          _incomingJsep = jsep;
          onCallEvent?.call('incoming', result);
        case 'progress' || 'accepted':
          if (jsep != null) _setRemote(jsep);
          onCallEvent?.call(event, result);
        case 'hangup':
          _incomingJsep = null;
          closeMedia();
          onCallEvent?.call('hangup', result);
        default:
          onCallEvent?.call(event, result);
      }
      return;
    }

    // Janus's own events about the media
    if (type == 'hangup' || type == 'webrtcup' || type == 'media') {
      onCallEvent?.call('janus_$type', {'reason': msg['reason']});
    }
  }

  void _onClosed() {
    if (_ws == null) return; // closed on purpose by close()
    _ws = null;
    _cleanup();
    closeMedia();
    onRegistration?.call('disconnected', null);
  }

  void _cleanup() {
    _keepalive?.cancel();
    _keepalive = null;
    _session = null;
    _handle = null;
    _registered = false;
    _incomingJsep = null;
    for (final done in _pending.values) {
      if (!done.isCompleted) done.completeError(const SocketException('connection closed'));
    }
    _pending.clear();
  }
}

// ---------------------------------------------------------------- users API

class PhoneUser {
  PhoneUser(this.name, this.group, this.codec, this.online);
  final String name;
  final String group;
  final String codec;
  final bool online;

  factory PhoneUser.fromJson(Map<String, dynamic> j) => PhoneUser(j['name'] as String,
      j['group'] as String, (j['codec'] ?? '').toString(), j['online'] == true);
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The MizuDroid users in MySQL, through the status service on the VM (HTTP 8190).
class UsersApi {
  UsersApi(this.server);
  final String server;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  Future<List<PhoneUser>> list() async {
    final data = await _go('GET', '/users');
    return [
      for (final u in (data['users'] as List)) PhoneUser.fromJson((u as Map).cast<String, dynamic>())
    ];
  }

  Future<Map<String, dynamic>> _go(String method, String path, [Map<String, dynamic>? body]) async {
    final req = await _http
        .openUrl(method, Uri.parse('http://$server:$kStatusPort$path'))
        .timeout(const Duration(seconds: 6));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length; // the server reads exactly Content-Length bytes
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 8));
    final text = await res.transform(utf8.decoder).join();
    final data = (jsonDecode(text) as Map).cast<String, dynamic>();
    if (res.statusCode != 200) {
      throw ApiException((data['error'] ?? 'HTTP ${res.statusCode}').toString());
    }
    return data;
  }
}

// ---------------------------------------------------------------- app

void main() => runApp(const IcPhoneApp());

class IcPhoneApp extends StatelessWidget {
  const IcPhoneApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'IC Phone',
        scaffoldMessengerKey: kMessenger,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const StartScreen(),
      );
}

/// First start: the name screen. Later starts: straight to home with the saved name.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  String? _name;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _name = prefs.getString(kNameKey);
      _loaded = true;
    });
  }

  Future<void> _setName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null) {
      await prefs.remove(kNameKey);
    } else {
      await prefs.setString(kNameKey, name);
    }
    setState(() => _name = name);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_name == null) return NameScreen(onDone: _setName);
    return HomeScreen(key: ValueKey(_name), name: _name!, onRename: () => _setName(null));
  }
}

class NameScreen extends StatefulWidget {
  const NameScreen({super.key, required this.onDone});
  final void Function(String name) onDone;

  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  final _ctrl = TextEditingController();
  String? _error;

  void _submit() {
    final name = _ctrl.text.trim().toLowerCase();
    if (!kNameRule.hasMatch(name)) {
      setState(() => _error = '2-32 characters: a-z 0-9 . _ - (start with a letter)');
      return;
    }
    widget.onDone(name);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IC Phone')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Choose your name'),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Name', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _submit, child: const Text('Continue')),
          ],
        ),
      ),
    );
  }
}

enum CallState { idle, calling, incoming, active }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.name, required this.onRename});
  final String name;
  final VoidCallback onRename;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final JanusSip _sip = JanusSip(kServer);
  final UsersApi _usersApi = UsersApi(kServer);

  String _status = 'Connecting...';
  bool _registered = false;
  bool _leaving = false;
  Timer? _retry;
  Timer? _refresh;
  Timer? _ticker;

  List<PhoneUser> _users = [];
  String? _usersError;

  CallState _call = CallState.idle;
  String _peer = '';
  String _callNote = '';
  bool _muted = false;
  bool _speaker = false;
  DateTime? _since;

  @override
  void initState() {
    super.initState();
    _sip.onRegistration = _onRegistration;
    _sip.onCallEvent = _onCallEvent;
    _start();
    _loadUsers();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_call == CallState.idle) _loadUsers();
    });
  }

  @override
  void dispose() {
    _leaving = true;
    _retry?.cancel();
    _refresh?.cancel();
    _ticker?.cancel();
    _sip.close();
    super.dispose();
  }

  // ---- registration ----

  /// Connect to Janus and register the saved name.
  Future<void> _start() async {
    _retry?.cancel();
    if (!mounted || _leaving) return;
    setState(() {
      _status = 'Connecting to $kServer...';
      _registered = false;
    });
    try {
      await _sip.connect();
      await _sip.register(widget.name);
    } catch (e) {
      await _sip.close();
      _onRegistration('disconnected', e.toString());
    }
  }

  void _onRegistration(String state, String? detail) {
    if (!mounted || _leaving) return;
    if (state == 'disconnected' && _call != CallState.idle) _endCall('Connection lost');
    setState(() {
      _registered = state == 'registered';
      switch (state) {
        case 'registering':
          _status = 'Registering...';
        case 'registered':
          _status = 'Registered';
        case 'failed':
          _status = 'Registration failed: $detail\n'
              'If this name belongs to a SIP phone, choose another name.';
        default:
          _status = 'Disconnected${detail == null ? '' : ': $detail'}\nRetrying in 5 s...';
      }
    });
    if (state == 'disconnected') {
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 5), _start);
    }
  }

  Future<void> _disconnectAndRename() async {
    _leaving = true;
    _retry?.cancel();
    await _sip.close();
    widget.onRename();
  }

  // ---- calls ----

  void _onCallEvent(String event, Map<String, dynamic> r) {
    if (!mounted) return;
    switch (event) {
      case 'incoming':
        setState(() {
          _call = CallState.incoming;
          _peer = _nameFromUri(r['username'] as String?);
          _callNote = 'Incoming call';
          _muted = false;
          _speaker = false;
        });
      case 'calling' || 'proceeding':
        if (_call == CallState.calling) setState(() => _callNote = 'Calling...');
      case 'ringing' || 'progress':
        if (_call == CallState.calling) setState(() => _callNote = 'Ringing...');
      case 'accepted':
        _startActive();
      case 'hangup':
        final code = r['code'];
        _endCall(code == null || code == 200
            ? 'Call ended'
            : 'Call ended: $code ${r['reason'] ?? ''}');
      case 'janus_hangup':
        if (_call != CallState.idle) {
          _sip.hangup();
          _endCall('Media connection lost');
        }
      case 'missed_call':
        _toast('Missed call from ${_nameFromUri(r['caller'] as String?)} (you were busy)');
      case 'error':
        _toast('SIP error: ${r['reason']}');
        if (_call != CallState.idle) {
          _sip.closeMedia();
          _endCall(null);
        }
    }
  }

  String _nameFromUri(String? uri) =>
      RegExp(r'^sips?:([^@]+)@').firstMatch(uri ?? '')?.group(1) ?? (uri ?? 'unknown');

  Future<void> _callUser(String name) async {
    setState(() {
      _call = CallState.calling;
      _peer = name;
      _callNote = 'Calling...';
      _muted = false;
      _speaker = false;
    });
    try {
      await _sip.call(name);
    } catch (e) {
      await _sip.closeMedia();
      _endCall('Call failed: $e');
    }
  }

  Future<void> _accept() async {
    try {
      await _sip.accept();
      _startActive();
    } catch (e) {
      await _sip.hangup();
      _endCall('Could not answer: $e');
    }
  }

  Future<void> _decline() async {
    try {
      await _sip.decline();
    } catch (_) {}
    _endCall('Declined');
  }

  Future<void> _hangup() async {
    await _sip.hangup();
    _endCall('Call ended');
  }

  void _startActive() {
    if (_call == CallState.active) return;
    setState(() {
      _call = CallState.active;
      _since = DateTime.now();
      _callNote = '';
    });
    Helper.setSpeakerphoneOn(_speaker);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _endCall(String? note) {
    _ticker?.cancel();
    if (!mounted) return;
    final wasInCall = _call != CallState.idle;
    setState(() {
      _call = CallState.idle;
      _muted = false;
      _speaker = false;
    });
    if (wasInCall && note != null) _toast(note);
    _loadUsers();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _sip.setMuted(_muted);
  }

  void _toggleSpeaker() {
    setState(() => _speaker = !_speaker);
    Helper.setSpeakerphoneOn(_speaker);
  }

  String _duration() {
    final d = DateTime.now().difference(_since ?? DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  // ---- users in the database ----

  Future<void> _loadUsers() async {
    try {
      final users = await _usersApi.list();
      if (!mounted) return;
      setState(() {
        _users = users;
        _usersError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _usersError = 'Cannot load users: $e');
    }
  }

  // ---- screens ----

  @override
  Widget build(BuildContext context) {
    final inCall = _call != CallState.idle;
    return Scaffold(
      appBar: AppBar(
        title: Text('IC Phone - ${widget.name}'),
        actions: [
          if (!inCall)
            IconButton(
                icon: const Icon(Icons.refresh), tooltip: 'Refresh users', onPressed: _loadUsers),
          if (!inCall)
            PopupMenuButton<String>(
              onSelected: (_) => _disconnectAndRename(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Disconnect & rename')),
              ],
            ),
        ],
      ),
      body: inCall ? _callView() : _homeView(),
    );
  }

  Widget _homeView() {
    return RefreshIndicator(
      onRefresh: _loadUsers,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: Icon(_registered ? Icons.check_circle : Icons.cloud_off,
                  color: _registered ? Colors.green : Colors.grey),
              title: Text(_status),
              subtitle: Text('${widget.name}@$kDomain via Janus on $kServer'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('SIP phone users (MizuDroid)',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          if (_usersError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_usersError!, style: const TextStyle(color: Colors.red)),
            ),
          if (_users.isEmpty && _usersError == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No SIP phone users yet. Tap "Add user".'),
            ),
          for (final u in _users) _userTile(u),
        ],
      ),
    );
  }

  Widget _userTile(PhoneUser u) {
    final canCall = _registered && u.online && _call == CallState.idle;
    return ListTile(
      leading: Icon(Icons.circle, size: 14, color: u.online ? Colors.green : Colors.grey),
      title: Text(u.name),
      subtitle: Text('Group ${u.group} - ${u.codec} - ${u.online ? 'online' : 'offline'}'),
      trailing: IconButton(
        icon: const Icon(Icons.call),
        color: Colors.green,
        tooltip: 'Call',
        onPressed: canCall ? () => _callUser(u.name) : null,
      ),
    );
  }
  Widget _callView() {
    final peer = _users.where((u) => u.name == _peer).toList();
    final peerCodec = peer.isEmpty ? '?' : '${peer.first.codec} (group ${peer.first.group})';
    final title = switch (_call) {
      CallState.incoming => '$_peer is calling',
      CallState.calling => 'Calling $_peer',
      CallState.active => 'In call with $_peer',
      CallState.idle => '',
    };
    final note = _call == CallState.active ? _duration() : _callNote;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_call == CallState.incoming ? Icons.ring_volume : Icons.phone_in_talk,
                size: 72, color: Colors.teal),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(note),
            const SizedBox(height: 8),
            Text('You: OPUS    $_peer: $peerCodec', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 32),
            if (_call == CallState.incoming)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: _accept,
                    icon: const Icon(Icons.call),
                    label: const Text('Accept'),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _decline,
                    icon: const Icon(Icons.call_end),
                    label: const Text('Decline'),
                  ),
                ],
              ),
            if (_call == CallState.active)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    iconSize: 32,
                    tooltip: 'Mute',
                    onPressed: _toggleMute,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                  ),
                  const SizedBox(width: 24),
                  IconButton.filledTonal(
                    iconSize: 32,
                    tooltip: 'Speaker',
                    onPressed: _toggleSpeaker,
                    icon: Icon(_speaker ? Icons.volume_up : Icons.hearing),
                  ),
                ],
              ),
            if (_call == CallState.active || _call == CallState.calling) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: _hangup,
                icon: const Icon(Icons.call_end),
                label: const Text('Hang up'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
