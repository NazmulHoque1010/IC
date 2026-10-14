import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'janus_sip_client.dart';
import 'sdp_utils.dart';

// ignore_for_file: avoid_print

void main() {
  runApp(const JanusVideoCallApp());
}

class JanusVideoCallApp extends StatelessWidget {
  const JanusVideoCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janus Video Call',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const VideoCallPage(),
    );
  }
}

/// Quick-fill values for each server. Each PC runs its own Janus; the SIP
/// host is the SIP registrar/proxy that Janus registers the user with.
class ServerPreset {
  const ServerPreset(this.label, this.janusHost, this.sipHost);

  final String label;
  final String janusHost;
  final String sipHost;
}

const List<ServerPreset> kPresets = [
  ServerPreset('PC1', '192.168.97.135', '192.168.97.135'),
  ServerPreset('PC2', '192.168.99.112', '192.168.99.112'),
];

enum CallState { idle, calling, incoming, inCall }

class VideoCallPage extends StatefulWidget {
  const VideoCallPage({super.key});

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  // Settings
  final _janusHost = TextEditingController(text: kPresets.first.janusHost);
  final _janusPort = TextEditingController(text: '8188');
  final _sipHost = TextEditingController(text: kPresets.first.sipHost);
  final _sipPort = TextEditingController(text: '5060');
  final _extension = TextEditingController();
  final _password = TextEditingController();
  final _destination = TextEditingController();
  String _preset = kPresets.first.label;

  // Janus / registration
  JanusSipClient? _janus;
  bool _registering = false;
  bool _registered = false;

  // Call
  CallState _callState = CallState.idle;
  String _status = 'Pick your server, enter your extension and register.';
  String _peer = '';
  Map<String, dynamic>? _pendingOffer;
  bool _remoteAnswerApplied = false;

  // Media
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCPeerConnection? _pc;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _remoteHasVideo = false;

  // In-call controls
  bool _muted = false;
  bool _cameraOff = false;
  bool _speakerOn = true; // video calls default to loudspeaker
  bool _frontCamera = true;

  int get _sipPortValue => int.tryParse(_sipPort.text.trim()) ?? 5060;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
  }

  @override
  void dispose() {
    unawaited(_janus?.close());
    unawaited(_teardownMedia().then((_) {
      _localRenderer.dispose();
      _remoteRenderer.dispose();
    }));

    for (final controller in [
      _janusHost,
      _janusPort,
      _sipHost,
      _sipPort,
      _extension,
      _password,
      _destination,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setStatus(String message) {
    print('STATUS: $message');
    if (!mounted) return;
    setState(() => _status = message);
  }

  void _applyPreset(ServerPreset preset) {
    setState(() {
      _preset = preset.label;
      _janusHost.text = preset.janusHost;
      _sipHost.text = preset.sipHost;
    });
  }

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  Future<void> _register() async {
    final extension = _extension.text.trim();
    if (extension.isEmpty) {
      _setStatus('Enter your extension first.');
      return;
    }

    setState(() {
      _registering = true;
      _registered = false;
      _status = 'Connecting to Janus...';
    });

    await _endCall('Connecting to Janus...');
    await _janus?.close();

    final client = JanusSipClient(
      onSipEvent: _onSipEvent,
      onConnectionLost: _onConnectionLost,
    );
    _janus = client;

    try {
      await client.connect(
        'ws://${_janusHost.text.trim()}:${_janusPort.text.trim()}',
      );

      _setStatus('Registering $extension...');

      await client.register(
        extension: extension,
        password: _password.text,
        sipHost: _sipHost.text.trim(),
        sipPort: _sipPortValue,
      );

      if (!mounted) return;
      setState(() {
        _registered = true;
        _status = 'Registered as $extension on $_preset. '
            'Ready to make or receive video calls.';
      });
    } catch (error) {
      print('REGISTER ERROR: $error');
      _setStatus('Registration failed: $error');
      await client.close();
      if (identical(_janus, client)) _janus = null;
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  void _onConnectionLost(String reason) {
    if (!mounted) return;
    setState(() => _registered = false);
    unawaited(_endCall('$reason Register again.'));
  }

  // ---------------------------------------------------------------------------
  // Media
  // ---------------------------------------------------------------------------

  /// Opens camera + microphone and creates a fresh PeerConnection.
  Future<RTCPeerConnection> _startMedia() async {
    await _teardownMedia();

    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 24},
      },
    });

    _localStream = stream;
    _localRenderer.srcObject = stream;
    _frontCamera = true;

    // LAN only: host candidates are enough, so no STUN/TURN server is set.
    final pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _janus?.trickle({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onTrack = (event) async {
      print('Remote track: ${event.track.kind}');

      if (event.streams.isNotEmpty) {
        _remoteRenderer.srcObject = event.streams.first;
      } else {
        _remoteStream ??= await createLocalMediaStream('remote');
        await _remoteStream!.addTrack(event.track);
        _remoteRenderer.srcObject = _remoteStream;
      }

      if (event.track.kind == 'video') _remoteHasVideo = true;
      if (mounted) setState(() {});
    };

    pc.onConnectionState = (state) {
      print('PeerConnection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setStatus('Connected with $_peer');
        unawaited(_applySpeaker());
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _setStatus('Media connection failed (ICE). Check network/ports.');
      }
    };

    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    await _applySpeaker();
    if (mounted) setState(() {});
    return pc;
  }

  /// Sets the local description with VP8 preferred, falling back to the
  /// unmodified SDP if the WebRTC stack rejects the edit.
  Future<RTCSessionDescription> _setLocalPreferVp8(
    RTCPeerConnection pc,
    RTCSessionDescription description,
  ) async {
    final munged = RTCSessionDescription(
      preferVideoCodec(description.sdp ?? '', 'VP8'),
      description.type,
    );

    try {
      await pc.setLocalDescription(munged);
      return munged;
    } catch (error) {
      print('VP8 preference rejected ($error), using original SDP.');
      await pc.setLocalDescription(description);
      return description;
    }
  }

  Future<void> _applyRemoteAnswer(Map<String, dynamic> jsep) async {
    final pc = _pc;
    if (pc == null || _remoteAnswerApplied) return;

    final sdp = jsep['sdp'] as String?;
    final type = jsep['type'] as String?;
    if (sdp == null || type == null) return;

    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteAnswerApplied = true;
  }

  Future<void> _teardownMedia() async {
    final pc = _pc;
    final local = _localStream;
    final remote = _remoteStream;

    _pc = null;
    _localStream = null;
    _remoteStream = null;
    _remoteAnswerApplied = false;
    _remoteHasVideo = false;

    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;

    try {
      await pc?.close();
    } catch (error) {
      print('PeerConnection close warning: $error');
    }

    try {
      if (local != null) {
        for (final track in local.getTracks()) {
          await track.stop();
        }
        await local.dispose();
      }
      await remote?.dispose();
    } catch (error) {
      print('Stream cleanup warning: $error');
    }
  }

  /// Returns to idle and releases camera, microphone and PeerConnection.
  Future<void> _endCall(String status) async {
    if (mounted) {
      setState(() {
        _callState = CallState.idle;
        _pendingOffer = null;
        _muted = false;
        _cameraOff = false;
        _speakerOn = true;
        _status = status;
      });
    }
    await _teardownMedia();
  }

  // ---------------------------------------------------------------------------
  // Outgoing call
  // ---------------------------------------------------------------------------

  Future<void> _call() async {
    final janus = _janus;
    final destination = _destination.text.trim();

    if (!_registered || janus == null) {
      _setStatus('Register first.');
      return;
    }
    if (destination.isEmpty) {
      _setStatus('Enter the extension to call.');
      return;
    }
    if (_callState != CallState.idle) return;

    setState(() {
      _callState = CallState.calling;
      _peer = destination;
      _status = 'Starting camera and microphone...';
    });

    try {
      final pc = await _startMedia();

      final offer = await pc.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 1,
      });
      final local = await _setLocalPreferVp8(pc, offer);

      _setStatus('Calling $destination...');

      await janus.call(
        uri: 'sip:$destination@${_sipHost.text.trim()}:$_sipPortValue',
        jsep: {'type': local.type, 'sdp': local.sdp},
      );
    } catch (error) {
      print('CALL ERROR: $error');
      await _endCall('Call failed: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming call
  // ---------------------------------------------------------------------------

  Future<void> _accept() async {
    final janus = _janus;
    final offer = _pendingOffer;
    if (janus == null || offer == null) return;

    setState(() {
      _callState = CallState.inCall;
      _pendingOffer = null;
      _status = 'Answering $_peer...';
    });

    try {
      final pc = await _startMedia();

      await pc.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
      );
      _remoteAnswerApplied = true;

      final answer = await pc.createAnswer({});
      final local = await _setLocalPreferVp8(pc, answer);

      await janus.accept({'type': local.type, 'sdp': local.sdp});
      _setStatus('Connecting with $_peer...');
    } catch (error) {
      print('ACCEPT ERROR: $error');
      await _endCall('Could not answer: $error');
    }
  }

  Future<void> _decline() async {
    final caller = _peer;
    try {
      await _janus?.decline();
    } catch (error) {
      print('DECLINE ERROR: $error');
    }
    await _endCall('Declined call from $caller.');
  }

  Future<void> _hangup() async {
    final janus = _janus;
    final wasActive = _callState != CallState.idle;

    if (mounted) setState(() => _callState = CallState.idle);

    if (wasActive) {
      try {
        await janus?.hangup();
      } catch (error) {
        print('HANGUP ERROR: $error');
      }
    }
    await _endCall('Call ended.');
  }

  // ---------------------------------------------------------------------------
  // SIP plugin events
  // ---------------------------------------------------------------------------

  Future<void> _onSipEvent(
    String event,
    Map<String, dynamic> data,
    Map<String, dynamic>? jsep,
  ) async {
    switch (event) {
      case 'incomingcall':
        final caller = extensionFromUri(data['username']?.toString() ?? '');
        // Already busy: Janus itself rejects extra calls with 486 Busy Here.
        if (_callState != CallState.idle) return;
        if (jsep == null) {
          _setStatus('Incoming call from $caller had no SDP offer.');
          return;
        }
        if (!mounted) return;
        setState(() {
          _callState = CallState.incoming;
          _peer = caller;
          _pendingOffer = jsep;
          _status = 'Incoming video call from $caller';
        });
        return;

      case 'calling':
        _setStatus('Calling $_peer...');
        return;

      case 'ringing':
        _setStatus('Ringing $_peer...');
        return;

      case 'proceeding':
      case 'progress':
        if (jsep != null) await _applyRemoteAnswer(jsep);
        _setStatus('Waiting for $_peer to answer...');
        return;

      case 'accepted':
        if (jsep != null) await _applyRemoteAnswer(jsep);
        if (!mounted) return;
        setState(() {
          _callState = CallState.inCall;
          _status = 'Connecting media with $_peer...';
        });
        return;

      case 'hangup':
        final missed = _callState == CallState.incoming;
        await _endCall(
          missed
              ? 'Missed call from $_peer.'
              : 'Call ended (${data['code'] ?? ''} ${data['reason'] ?? ''}).',
        );
        return;

      case 'error':
        final reason = data['reason']?.toString() ?? 'Unknown error';
        if (_callState != CallState.idle) {
          await _endCall(reason);
        } else {
          _setStatus(reason);
        }
        return;

      case 'registration_failed':
        if (!mounted) return;
        setState(() {
          _registered = false;
          _status =
              'Registration lost: ${data['code']} ${data['reason']}. '
              'Register again.';
        });
        return;

      default:
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // In-call controls
  // ---------------------------------------------------------------------------

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !_muted;
    }
  }

  void _toggleCamera() {
    setState(() => _cameraOff = !_cameraOff);
    for (final track
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !_cameraOff;
    }
  }

  Future<void> _switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      if (mounted) setState(() => _frontCamera = !_frontCamera);
    } catch (error) {
      print('Switch camera failed: $error');
    }
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    await _applySpeaker();
  }

  Future<void> _applySpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (error) {
      print('Speakerphone warning: $error');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final showCallScreen = _callState == CallState.calling ||
        _callState == CallState.inCall;

    return Scaffold(
      backgroundColor: showCallScreen ? Colors.black : null,
      appBar: showCallScreen
          ? null
          : AppBar(title: const Text('Janus Video Call')),
      body: SafeArea(
        child: showCallScreen ? _buildCallScreen() : _buildHomeScreen(),
      ),
    );
  }

  Widget _buildHomeScreen() {
    final theme = Theme.of(context);
    final canEditServer = !_registering;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Server', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final preset in kPresets)
              ChoiceChip(
                label: Text(preset.label),
                selected: _preset == preset.label,
                onSelected: canEditServer ? (_) => _applyPreset(preset) : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(flex: 3, child: _field(_janusHost, 'Janus host')),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _field(_janusPort, 'WS port', number: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(flex: 3, child: _field(_sipHost, 'SIP proxy host')),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _field(_sipPort, 'SIP port', number: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _field(_extension, 'My extension', number: true),
        const SizedBox(height: 12),
        _field(_password, 'Password', obscure: true),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _registering ? null : _register,
          icon: _registering
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: Text(_registered ? 'Re-register' : 'Register'),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  _registered ? Icons.check_circle : Icons.info_outline,
                  color: _registered ? Colors.green : theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_status)),
              ],
            ),
          ),
        ),
        if (_callState == CallState.incoming) ...[
          const SizedBox(height: 12),
          _buildIncomingCard(),
        ],
        const SizedBox(height: 16),
        _field(_destination, 'Extension to call', number: true),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _registered && _callState == CallState.idle ? _call : null,
          icon: const Icon(Icons.videocam),
          label: const Text('Video call'),
        ),
      ],
    );
  }

  Widget _buildIncomingCard() {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Incoming video call from $_peer',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: _decline,
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: _accept,
                  icon: const Icon(Icons.videocam),
                  label: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallScreen() {
    return Stack(
      children: [
        // Remote video (full screen)
        Positioned.fill(
          child: _remoteHasVideo
              ? RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person, size: 96, color: Colors.white38),
                      const SizedBox(height: 8),
                      Text(
                        _peer,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                        ),
                      ),
                    ],
                  ),
                ),
        ),

        // Status text
        Positioned(
          top: 16,
          left: 16,
          right: 140,
          child: Text(
            _status,
            style: const TextStyle(
              color: Colors.white,
              shadows: [Shadow(blurRadius: 4)],
            ),
          ),
        ),

        // Local preview
        Positioned(
          top: 16,
          right: 16,
          width: 110,
          height: 150,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: _cameraOff
                ? Container(
                    color: Colors.grey.shade900,
                    child: const Icon(Icons.videocam_off, color: Colors.white54),
                  )
                : RTCVideoView(
                    _localRenderer,
                    mirror: _frontCamera,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
          ),
        ),

        // Controls
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _roundButton(
                icon: _muted ? Icons.mic_off : Icons.mic,
                onPressed: _toggleMute,
              ),
              _roundButton(
                icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                onPressed: _toggleCamera,
              ),
              _roundButton(
                icon: Icons.cameraswitch,
                onPressed: _switchCamera,
              ),
              _roundButton(
                icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                onPressed: _toggleSpeaker,
              ),
              _roundButton(
                icon: Icons.call_end,
                onPressed: _hangup,
                color: Colors.red,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onPressed,
    Color color = Colors.white24,
  }) {
    return RawMaterialButton(
      onPressed: onPressed,
      shape: const CircleBorder(),
      fillColor: color,
      padding: const EdgeInsets.all(14),
      constraints: const BoxConstraints(),
      child: Icon(icon, color: Colors.white),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    bool number = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
