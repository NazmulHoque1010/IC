import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

// Temporary development-only lint suppression.
// Remove these later and replace print() with a logging package.
// ignore_for_file: avoid_print, unnecessary_string_interpolations

void main() {
  runApp(const JanusSipDemoApp());
}

class JanusSipDemoApp extends StatelessWidget {
  const JanusSipDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janus SIP Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String janusBaseUrl = 'http://192.168.97.53:8088/janus';

  static const String sipUsername = '1001';
  static const String sipPassword = '1001';
  static const String sipServer = '192.168.97.53';

  final TextEditingController _usernameController = TextEditingController(
    text: sipUsername,
  );

  final TextEditingController _passwordController = TextEditingController(
    text: sipPassword,
  );

  String _status = 'Not registered';
  bool _isRegistering = false;
  bool _isRegistered = false;

  int? _sessionId;
  int? _handleId;

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  bool _webrtcReady = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _disposeWebRtc();
    super.dispose();
  }

  Future<Map<String, dynamic>> _createJanusSession() async {
    final response = await http
        .post(
          Uri.parse(janusBaseUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'janus': 'create',
            'transaction': _randomTransaction(),
          }),
        )
        .timeout(const Duration(seconds: 10));

    print(
      'DEBUG: Create session status: ${response.statusCode}',
    );
    print('DEBUG: Create session body: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to create Janus session: HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['janus'] != 'success') {
      throw Exception('Janus session creation failed: ${data['error']}');
    }

    return data;
  }

  Future<Map<String, dynamic>> _attachSipPlugin({
    required int sessionId,
  }) async {
    final response = await http
        .post(
          Uri.parse('$janusBaseUrl/$sessionId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'janus': 'attach',
            'plugin': 'janus.plugin.sip',
            'transaction': _randomTransaction(),
          }),
        )
        .timeout(const Duration(seconds: 10));

    print(
      'DEBUG: Attach plugin status: ${response.statusCode}',
    );
    print('DEBUG: Attach plugin body: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to attach SIP plugin: HTTP ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['janus'] != 'success') {
      throw Exception('SIP plugin attach failed: ${data['error']}');
    }

    return data;
  }

  Future<void> _registerWithJanus() async {
    setState(() {
      _isRegistering = true;
      _status = 'Creating Janus session...';
      _isRegistered = false;
    });

    try {
      print('DEBUG: Creating Janus session');

      final sessionResponse = await _createJanusSession();
      final sessionId = sessionResponse['data']['id'] as int;
      _sessionId = sessionId;

      setState(() {
        _status = 'Attaching SIP plugin...';
      });

      print('DEBUG: Attaching SIP plugin to session $sessionId');

      final handleResponse = await _attachSipPlugin(sessionId: sessionId);
      final handleId = handleResponse['data']['id'] as int;
      _handleId = handleId;

      setState(() {
        _status = 'Sending SIP register request...';
      });

      print('DEBUG: Sending register to handle $handleId');

      final registerResponse = await http
          .post(
            Uri.parse('$janusBaseUrl/$sessionId/$handleId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'janus': 'message',
              'transaction': _randomTransaction(),
              'body': {
                'request': 'register',
                'username': 'sip:${_usernameController.text}@$sipServer',
                'authuser': _usernameController.text,
                'display_name': 'Flutter SIP Client',
                'secret': _passwordController.text,
                'proxy': 'sip:$sipServer:5070',
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      print(
        'DEBUG: Register status: ${registerResponse.statusCode}',
      );
      print('DEBUG: Register body: ${registerResponse.body}');

      if (registerResponse.statusCode != 200) {
        throw Exception(
          'Register request failed: HTTP ${registerResponse.statusCode}',
        );
      }

      final registerData =
          jsonDecode(registerResponse.body) as Map<String, dynamic>;

      print(
        'DEBUG: Janus register response: ${registerData['janus']}',
      );

      if (registerData['janus'] != 'ack' &&
          registerData['janus'] != 'success') {
        throw Exception(
          'Janus rejected register request: ${registerData['error']}',
        );
      }

      setState(() {
        _status = 'Waiting for registration event...';
      });

      print('DEBUG: Waiting for Janus registration events');

      String? registrationEvent;
      Map<String, dynamic>? registrationResultData;

      for (int attempt = 0; attempt < 10; attempt++) {
        final eventResponse = await http
            .get(
              Uri.parse('$janusBaseUrl/$sessionId?maxev=1'),
            )
            .timeout(const Duration(seconds: 10));

        print(
          'DEBUG: Event attempt ${attempt + 1} '
          'status: ${eventResponse.statusCode}',
        );
        print('DEBUG: Event body: ${eventResponse.body}');

        if (eventResponse.statusCode != 200) {
          throw Exception(
            'Failed to read Janus event: HTTP ${eventResponse.statusCode}',
          );
        }

        final eventData =
            jsonDecode(eventResponse.body) as Map<String, dynamic>;

        final pluginData = eventData['plugindata']?['data']
            as Map<String, dynamic>?;

        registrationResultData =
            pluginData?['result'] as Map<String, dynamic>?;

        registrationEvent =
            registrationResultData?['event'] as String?;

        print('DEBUG: Registration event: $registrationEvent');

        if (registrationEvent == 'registered' ||
            registrationEvent == 'registration_failed') {
          break;
        }

        await Future<void>.delayed(const Duration(seconds: 1));
      }

      if (registrationEvent == 'registered') {
        setState(() {
          _isRegistered = true;
          _status = 'Registered as $_usernameController.text';
        });
      } else {
        setState(() {
          _isRegistered = false;
          _status =
              'Registration not confirmed. Final event: $registrationEvent';
        });

        if (registrationResultData != null) {
          print(
            'DEBUG: Full registration result: '
            '${const JsonEncoder.withIndent('  ').convert(registrationResultData)}',
          );
        }
      }
    } on TimeoutException {
      print('DEBUG: A Janus HTTP request timed out');

      setState(() {
        _isRegistered = false;
        _status = 'Registration timed out waiting for Janus.';
      });
    } catch (error) {
      print('DEBUG: Registration failed: $error');

      setState(() {
        _isRegistered = false;
        _status = 'Registration failed: $error';
      });
    } finally {
      print('DEBUG: Register function finished');

      setState(() {
        _isRegistering = false;
      });
    }
  }

  Future<void> _simulateCall() async {
    if (!_isRegistered) {
      setState(() {
        _status = 'Register before calling.';
      });
      return;
    }

    setState(() {
      _status = 'Call button pressed. Real SIP calling is not implemented yet.';
    });
  }

  Future<void> _testMicrophoneAndSdp() async {
    try {
      setState(() {
        _status = 'Requesting microphone...';
      });

      final mediaConstraints = {
        'audio': true,
        'video': false,
      };

      final stream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      _localStream = stream;

      final audioTracks = stream.getAudioTracks();

      print('Microphone tracks found: ${audioTracks.length}');

      if (audioTracks.isEmpty) {
        setState(() {
          _status = 'No microphone audio track was returned.';
        });
        return;
      }

      print('Microphone track ID: ${audioTracks.first.id}');

      setState(() {
        _status = 'Creating WebRTC PeerConnection...';
      });

      final config = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      };

      final peerConnection = await createPeerConnection(config);
      _peerConnection = peerConnection;

      for (final track in stream.getTracks()) {
        await peerConnection.addTrack(track, stream);
      }

      setState(() {
        _status = 'Generating SDP offer...';
      });

      final offer = await peerConnection.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });

      await peerConnection.setLocalDescription(offer);

      final localDescription = await peerConnection.getLocalDescription();

      print('=== LOCAL SDP OFFER ===');
      print(localDescription?.sdp);
      print('=== END LOCAL SDP OFFER ===');

      setState(() {
        _webrtcReady = true;
        _status = 'Microphone captured and SDP offer generated.';
      });
    } catch (error) {
      print('WebRTC microphone/SDP test failed: $error');

      setState(() {
        _webrtcReady = false;
        _status = 'WebRTC microphone/SDP test failed: $error';
      });
    }
  }

  Future<void> _disposeWebRtc() async {
    try {
      await _localStream?.dispose();
      await _peerConnection?.close();
    } catch (_) {
      // Ignore cleanup errors during app shutdown.
    }

    _localStream = null;
    _peerConnection = null;
  }

  String _randomTransaction() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Janus SIP Demo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'SIP username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'SIP password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isRegistering ? null : _registerWithJanus,
              child: _isRegistering
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Register with Janus'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isRegistered ? _simulateCall : null,
              child: const Text('Call'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _testMicrophoneAndSdp,
              child: const Text('Test Microphone + SDP'),
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_status),
                    const SizedBox(height: 8),
                    Text('Janus session ID: ${_sessionId ?? 'none'}'),
                    Text('SIP handle ID: ${_handleId ?? 'none'}'),
                    Text(
                      'WebRTC ready: ${_webrtcReady ? 'yes' : 'no'}',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}