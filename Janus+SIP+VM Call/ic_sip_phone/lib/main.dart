// main.dart: IC SIP Phone, a MizuDroid-like SIP phone for the IC system.
//
// - Registers <name>@ic.local directly on FreeSWITCH ("phones" profile, UDP 5090),
//   password 1234. The name must be in the database (add it on the admin page).
// - The SIP engine is the Linphone SDK in MainActivity.kt; this file is the screens.
// - Supports PCMU, PCMA, GSM and Opus; FreeSWITCH picks the codec of the user's group.
// - Asks for a name once, remembers it and registers on every start until
//   "Disconnect & rename".
// Run with: flutter run -d <id> --dart-define=IC_SERVER=<VM1 public IP>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- settings

const String kServer = String.fromEnvironment('IC_SERVER', defaultValue: '__IC_PUBLIC_IP__');
const int kSipPort = 5090; // FreeSWITCH "phones" profile
const int kStatusPort = 8190; // status service: user list
const String kDomain = 'ic.local';
const String kPassword = '1234';
const String kNameKey = 'sip_name';
// Same name rule as the database and ic_directory.lua.
final RegExp kNameRule = RegExp(r'^[a-z][a-z0-9._-]{1,31}$');

final GlobalKey<ScaffoldMessengerState> kMessenger = GlobalKey<ScaffoldMessengerState>();

void _toast(String text) {
  kMessenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

// ---------------------------------------------------------------- SIP engine (Kotlin side)

class SipEngine {
  static const MethodChannel _methods = MethodChannel('ic/sip');
  static const EventChannel _events = EventChannel('ic/sip/events');

  static Stream<Map<String, dynamic>> events() =>
      _events.receiveBroadcastStream().map((e) => (e as Map).cast<String, dynamic>());

  static Future<void> register(String name) => _methods.invokeMethod('register', {
        'name': name,
        'server': kServer,
        'port': kSipPort,
        'domain': kDomain,
        'password': kPassword,
      });
  static Future<void> unregister() => _methods.invokeMethod('unregister');
  static Future<void> call(String name) =>
      _methods.invokeMethod('call', {'name': name, 'domain': kDomain});
  static Future<void> accept() => _methods.invokeMethod('accept');
  static Future<void> decline() => _methods.invokeMethod('decline');
  static Future<void> hangup() => _methods.invokeMethod('hangup');
  static Future<void> setMuted(bool on) => _methods.invokeMethod('mute', {'on': on});
  static Future<void> setSpeaker(bool on) => _methods.invokeMethod('speaker', {'on': on});
}

// ---------------------------------------------------------------- user list (read only)

class PhoneUser {
  PhoneUser(this.name, this.group, this.codec, this.online);
  final String name;
  final String group;
  final String codec;
  final bool online;

  factory PhoneUser.fromJson(Map<String, dynamic> j) => PhoneUser(j['name'] as String,
      j['group'] as String, (j['codec'] ?? '').toString(), j['online'] == true);
}

/// GET /users from the status service on the VM.
Future<List<PhoneUser>> fetchUsers() async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await http
        .getUrl(Uri.parse('http://$kServer:$kStatusPort/users'))
        .timeout(const Duration(seconds: 6));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final data = (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
        .cast<String, dynamic>();
    if (res.statusCode != 200) throw Exception(data['error'] ?? 'HTTP ${res.statusCode}');
    return [
      for (final u in (data['users'] as List))
        PhoneUser.fromJson((u as Map).cast<String, dynamic>())
    ];
  } finally {
    http.close();
  }
}

// ---------------------------------------------------------------- app

void main() => runApp(const IcSipPhoneApp());

class IcSipPhoneApp extends StatelessWidget {
  const IcSipPhoneApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'IC SIP Phone',
        scaffoldMessengerKey: kMessenger,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
      appBar: AppBar(title: const Text('IC SIP Phone')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Your SIP name (it must be in the database, e.g. alice)'),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Name', errorText: _error),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _submit, child: const Text('Register')),
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
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _refresh;
  Timer? _ticker;
  final _dialCtrl = TextEditingController();

  String _status = 'Starting...';
  bool _registered = false;
  bool _leaving = false;

  List<PhoneUser> _users = [];
  String? _usersError;

  CallState _call = CallState.idle;
  String _peer = '';
  String _note = '';
  String _codec = '';
  bool _muted = false;
  bool _speaker = false;
  DateTime? _since;

  @override
  void initState() {
    super.initState();
    _sub = SipEngine.events().listen(_onEvent);
    _register();
    _loadUsers();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_call == CallState.idle) _loadUsers();
    });
  }

  @override
  void dispose() {
    _leaving = true;
    _sub?.cancel();
    _refresh?.cancel();
    _ticker?.cancel();
    _dialCtrl.dispose();
    super.dispose();
  }

  // ---- registration ----

  Future<void> _register() async {
    setState(() => _status = 'Registering ${widget.name}@$kDomain on $kServer:$kSipPort...');
    try {
      await SipEngine.register(widget.name);
    } catch (e) {
      setState(() => _status = 'Could not start registration: $e');
    }
  }

  Future<void> _disconnectAndRename() async {
    _leaving = true;
    try {
      await SipEngine.unregister();
    } catch (_) {}
    widget.onRename();
  }

  // ---- events from the SIP engine ----

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted || _leaving) return;
    if (e['type'] == 'registration') {
      final state = e['state'] as String? ?? '';
      final msg = e['message'] as String? ?? '';
      setState(() {
        switch (state) {
          case 'Progress':
            _status = 'Registering...';
          case 'Ok':
            _registered = true;
            _status = 'Registered';
          case 'Failed':
            _registered = false;
            _status = 'Registration failed: $msg\n'
                'Is "${widget.name}" in the database? Add it on the admin page.';
          case 'Cleared':
            _registered = false;
            _status = 'Not registered';
        }
      });
    } else if (e['type'] == 'call') {
      _onCall(e);
    }
  }

  void _onCall(Map<String, dynamic> e) {
    final state = e['state'] as String? ?? '';
    final codec = e['codec'] as String? ?? '';
    switch (state) {
      case 'incoming':
        setState(() {
          _call = CallState.incoming;
          _peer = e['peer'] as String? ?? 'unknown';
          _note = 'Incoming call';
          _codec = '';
          _muted = false;
          _speaker = false;
        });
      case 'calling':
        if (_call == CallState.calling) setState(() => _note = 'Calling...');
      case 'ringing':
        if (_call == CallState.calling) setState(() => _note = 'Ringing...');
      case 'active':
        if (_call != CallState.active) {
          _since = DateTime.now();
          _ticker?.cancel();
          _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
        }
        setState(() {
          _call = CallState.active;
          if (codec.isNotEmpty) _codec = codec;
        });
      case 'ended':
        if (_call != CallState.idle) _endCall(e['reason'] as String? ?? '');
    }
  }

  // ---- calls ----

  Future<void> _callUser(String name) async {
    if (!kNameRule.hasMatch(name)) {
      _toast('Bad name: 2-32 characters a-z 0-9 . _ - (start with a letter)');
      return;
    }
    if (name == widget.name) {
      _toast('That is you.');
      return;
    }
    setState(() {
      _call = CallState.calling;
      _peer = name;
      _note = 'Calling...';
      _codec = '';
      _muted = false;
      _speaker = false;
    });
    try {
      await SipEngine.call(name);
    } catch (e) {
      _endCall('Call failed: $e');
    }
  }

  void _endCall(String reason) {
    _ticker?.cancel();
    if (!mounted) return;
    setState(() => _call = CallState.idle);
    _toast(reason.isEmpty ? 'Call ended' : 'Call ended: $reason');
    _loadUsers();
  }

  Future<void> _accept() async {
    try {
      await SipEngine.accept();
    } catch (e) {
      _endCall('Could not answer: $e');
    }
  }

  Future<void> _decline() async {
    try {
      await SipEngine.decline();
    } catch (_) {}
  }

  Future<void> _hangup() async {
    try {
      await SipEngine.hangup();
    } catch (_) {}
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    SipEngine.setMuted(_muted);
  }

  void _toggleSpeaker() {
    setState(() => _speaker = !_speaker);
    SipEngine.setSpeaker(_speaker);
  }

  String _duration() {
    final d = DateTime.now().difference(_since ?? DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  // ---- user list ----

  Future<void> _loadUsers() async {
    try {
      final users = await fetchUsers();
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
        title: Text('IC SIP Phone - ${widget.name}'),
        actions: [
          if (!inCall)
            IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _loadUsers),
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
    final me = _users.where((u) => u.name == widget.name).toList();
    final myGroup = me.isEmpty
        ? 'Not in the database'
        : 'Group ${me.first.group} - ${me.first.codec}';
    final others = _users.where((u) => u.name != widget.name).toList();
    return RefreshIndicator(
      onRefresh: _loadUsers,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: Icon(_registered ? Icons.check_circle : Icons.cloud_off,
                  color: _registered ? Colors.green : Colors.grey),
              title: Text(_status),
              subtitle: Text('${widget.name}@$kDomain via $kServer:$kSipPort UDP\n$myGroup'),
              isThreeLine: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dialCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Call any name (also app users)', isDense: true),
                    onSubmitted: (v) => _callUser(v.trim().toLowerCase()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.call),
                  color: Colors.green,
                  tooltip: 'Call',
                  onPressed: _registered
                      ? () => _callUser(_dialCtrl.text.trim().toLowerCase())
                      : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('SIP phone users', style: Theme.of(context).textTheme.titleSmall),
          ),
          if (_usersError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_usersError!, style: const TextStyle(color: Colors.red)),
            ),
          if (others.isEmpty && _usersError == null)
            const Padding(padding: EdgeInsets.all(16), child: Text('No other SIP phone users.')),
          for (final u in others)
            ListTile(
              leading: Icon(Icons.circle, size: 14, color: u.online ? Colors.green : Colors.grey),
              title: Text(u.name),
              subtitle: Text('Group ${u.group} - ${u.codec} - ${u.online ? 'online' : 'offline'}'),
              trailing: IconButton(
                icon: const Icon(Icons.call),
                color: Colors.green,
                tooltip: 'Call',
                onPressed: _registered && u.online ? () => _callUser(u.name) : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _callView() {
    final title = switch (_call) {
      CallState.incoming => '$_peer is calling',
      CallState.calling => 'Calling $_peer',
      CallState.active => 'In call with $_peer',
      CallState.idle => '',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_call == CallState.incoming ? Icons.ring_volume : Icons.phone_in_talk,
                size: 72, color: Colors.indigo),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(_call == CallState.active ? _duration() : _note),
            if (_codec.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Codec on this phone: $_codec', style: Theme.of(context).textTheme.bodySmall),
            ],
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
