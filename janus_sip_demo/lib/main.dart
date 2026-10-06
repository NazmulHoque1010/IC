import 'dart:async';

import 'package:flutter/material.dart';

import 'services/janus_rest_service.dart';

void main() {
  runApp(const JanusSipDemoApp());
}

enum CallStatus { idle, calling, ringing, connected, ended }

class JanusSipDemoApp extends StatelessWidget {
  const JanusSipDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janus SIP Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      home: const RegistrationScreen(),
    );
  }
}

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();

  final _janusUrlController = TextEditingController(
    text: 'http://localhost:8088/janus',
  );
  final _sipServerController = TextEditingController(
    text: '192.168.97.53:5060',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController(
    text: 'Janus Flutter Client',
  );

  bool _isRegistering = false;
  bool _isRegistered = false;
  bool _hidePassword = true;

  bool _isTestingJanus = false;
  String? _janusConnectionMessage;
  bool _janusConnectionSucceeded = false;

  JanusRestService? _janusService;

  @override
  void dispose() {
    _janusService?.dispose();
    _janusUrlController.dispose();
    _sipServerController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isRegistering = true;
      _isRegistered = false;
      _janusConnectionMessage = null;
      _janusConnectionSucceeded = false;
    });

    final previousService = _janusService;
    _janusService = JanusRestService(
      serverUrl: _janusUrlController.text.trim(),
    );
    await previousService?.dispose();

    try {
      final result = await _janusService!.registerSip(
        extension: _usernameController.text.trim(),
        password: _passwordController.text,
        sipServer: _sipServerController.text.trim(),
        displayName: _displayNameController.text.trim(),
      );

      if (!mounted) {
        return;
      }

      if (!result.event.isRegistered) {
        throw JanusApiException(
          'SIP registration failed (${result.event.code}): '
          '${result.event.reason}',
        );
      }

      setState(() {
        _isRegistered = true;
        _janusConnectionSucceeded = true;
        _janusConnectionMessage =
            'SIP registered as ${result.event.username}.\n'
            'Janus session ID: ${result.sessionId}\n'
            'SIP plugin handle ID: ${result.handleId}';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('SIP registration through Janus succeeded.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isRegistered = false;
        _janusConnectionSucceeded = false;
        _janusConnectionMessage = 'SIP registration failed:\n$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRegistering = false;
        });
      }
    }
  }

  Future<void> _testJanusConnection() async {
    FocusScope.of(context).unfocus();

    final janusUrl = _janusUrlController.text.trim();
    final validationError = _janusUrlValidator(janusUrl);

    if (validationError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    setState(() {
      _isTestingJanus = true;
      _janusConnectionMessage = null;
      _janusConnectionSucceeded = false;
    });

    final service = JanusRestService(serverUrl: janusUrl);

    try {
      final result = await service.createSessionAndAttachSip();

      if (!mounted) {
        return;
      }

      setState(() {
        _janusConnectionSucceeded = true;
        _janusConnectionMessage =
            'Connected to Janus successfully.\n'
            'Session ID: ${result.sessionId}\n'
            'SIP plugin handle ID: ${result.handleId}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _janusConnectionSucceeded = false;
        _janusConnectionMessage = 'Janus connection failed:\n$error';
      });
    } finally {
      await service.dispose();

      if (mounted) {
        setState(() {
          _isTestingJanus = false;
        });
      }
    }
  }

  void _openDialScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DialScreen(
          janusUrl: _janusUrlController.text.trim(),
          sipServer: _sipServerController.text.trim(),
          username: _usernameController.text.trim(),
          displayName: _displayNameController.text.trim(),
        ),
      ),
    );
  }

  String? _requiredValidator(String? value, String label) {
    if (value == null || value.trim().isEmpty) {
      return '$label is required.';
    }
    return null;
  }

  String? _janusUrlValidator(String? value) {
    final requiredError = _requiredValidator(value, 'Janus URL');
    if (requiredError != null) {
      return requiredError;
    }

    final url = Uri.tryParse(value!.trim());
    if (url == null || !(url.isScheme('http') || url.isScheme('https'))) {
      return 'Enter a valid HTTP or HTTPS URL.';
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final statusText = _isRegistering
        ? 'Registering through Janus...'
        : _isRegistered
        ? 'Registered through Janus'
        : 'Not registered';

    final statusColor = _isRegistering
        ? Colors.orange
        : _isRegistered
        ? Colors.green
        : Colors.grey;

    return Scaffold(
      appBar: AppBar(title: const Text('Janus SIP Client')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.phone_in_talk_outlined,
                      size: 64,
                      color: Colors.indigo,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Connect to Janus',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Register a SIP account through the Janus SIP plugin.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _janusUrlController,
                              keyboardType: TextInputType.url,
                              enabled: !_isRegistering && !_isRegistered,
                              decoration: const InputDecoration(
                                labelText: 'Janus URL',
                                hintText: 'http://localhost:8088/janus',
                                prefixIcon: Icon(Icons.hub_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: _janusUrlValidator,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _sipServerController,
                              keyboardType: TextInputType.url,
                              enabled: !_isRegistering && !_isRegistered,
                              decoration: const InputDecoration(
                                labelText: 'SIP server',
                                hintText: '192.168.97.53:5060',
                                prefixIcon: Icon(Icons.dns_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) =>
                                  _requiredValidator(value, 'SIP server'),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _usernameController,
                              enabled: !_isRegistering && !_isRegistered,
                              decoration: const InputDecoration(
                                labelText: 'SIP extension',
                                hintText: 'For example: 1001',
                                prefixIcon: Icon(Icons.person_outline),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) =>
                                  _requiredValidator(value, 'SIP extension'),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              enabled: !_isRegistering && !_isRegistered,
                              obscureText: _hidePassword,
                              enableSuggestions: false,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: 'SIP password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  tooltip: _hidePassword
                                      ? 'Show password'
                                      : 'Hide password',
                                  icon: Icon(
                                    _hidePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _hidePassword = !_hidePassword;
                                    });
                                  },
                                ),
                              ),
                              validator: (value) =>
                                  _requiredValidator(value, 'SIP password'),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _displayNameController,
                              enabled: !_isRegistering && !_isRegistered,
                              decoration: const InputDecoration(
                                labelText: 'Display name',
                                prefixIcon: Icon(Icons.badge_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) =>
                                  _requiredValidator(value, 'Display name'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    StatusCard(
                      title: 'Registration status',
                      message: statusText,
                      color: statusColor,
                      icon: _isRegistering
                          ? Icons.sync
                          : _isRegistered
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _isTestingJanus || _isRegistering
                          ? null
                          : _testJanusConnection,
                      icon: _isTestingJanus
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check_outlined),
                      label: Text(
                        _isTestingJanus
                            ? 'Testing Janus...'
                            : 'Test Janus connection',
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    if (_janusConnectionMessage != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        color:
                            (_janusConnectionSucceeded
                                    ? Colors.green
                                    : Colors.red)
                                .withValues(alpha: 0.12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _janusConnectionSucceeded
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                color: _janusConnectionSucceeded
                                    ? Colors.green
                                    : Colors.red,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _janusConnectionMessage!,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_isRegistered)
                      FilledButton.icon(
                        onPressed: _openDialScreen,
                        icon: const Icon(Icons.dialpad_outlined),
                        label: const Text('Open dial pad'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _isRegistering || _isTestingJanus
                            ? null
                            : _register,
                        icon: _isRegistering
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.login_outlined),
                        label: Text(
                          _isRegistering ? 'Registering...' : 'Register',
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Current Phase 2: SIP registration through Janus is '
                      'real. WebRTC audio and SIP calling are not '
                      'implemented yet.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DialScreen extends StatefulWidget {
  const DialScreen({
    required this.janusUrl,
    required this.sipServer,
    required this.username,
    required this.displayName,
    super.key,
  });

  final String janusUrl;
  final String sipServer;
  final String username;
  final String displayName;

  @override
  State<DialScreen> createState() => _DialScreenState();
}

class _DialScreenState extends State<DialScreen> {
  final _destinationController = TextEditingController(text: '1000');

  CallStatus _callStatus = CallStatus.idle;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  int _callSeconds = 0;

  Timer? _callTimer;
  Timer? _ringTimer;
  Timer? _connectTimer;

  @override
  void dispose() {
    _cancelCallTimers();
    _destinationController.dispose();
    super.dispose();
  }

  void _cancelCallTimers() {
    _callTimer?.cancel();
    _ringTimer?.cancel();
    _connectTimer?.cancel();
  }

  void _call() {
    FocusScope.of(context).unfocus();

    final destination = _destinationController.text.trim();
    if (destination.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a destination extension first.')),
      );
      return;
    }

    _cancelCallTimers();

    setState(() {
      _callStatus = CallStatus.calling;
      _isMuted = false;
      _isSpeakerOn = false;
      _callSeconds = 0;
    });

    _ringTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || _callStatus != CallStatus.calling) {
        return;
      }

      setState(() {
        _callStatus = CallStatus.ringing;
      });
    });

    _connectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          (_callStatus != CallStatus.calling &&
              _callStatus != CallStatus.ringing)) {
        return;
      }

      setState(() {
        _callStatus = CallStatus.connected;
      });

      _startCallTimer();
    });
  }

  void _startCallTimer() {
    _callTimer?.cancel();

    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _callStatus != CallStatus.connected) {
        return;
      }

      setState(() {
        _callSeconds++;
      });
    });
  }

  void _hangUp() {
    _cancelCallTimers();

    setState(() {
      _callStatus = CallStatus.ended;
      _isMuted = false;
      _isSpeakerOn = false;
      _callSeconds = 0;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Prototype only: local call state ended. No SIP BYE was sent.',
        ),
      ),
    );
  }

  void _toggleMute() {
    if (_callStatus != CallStatus.connected) {
      return;
    }

    setState(() {
      _isMuted = !_isMuted;
    });
  }

  void _toggleSpeaker() {
    if (_callStatus != CallStatus.connected) {
      return;
    }

    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
  }

  bool get _isCallActive =>
      _callStatus == CallStatus.calling ||
      _callStatus == CallStatus.ringing ||
      _callStatus == CallStatus.connected;

  String get _callStatusText {
    switch (_callStatus) {
      case CallStatus.idle:
        return 'Ready to call';
      case CallStatus.calling:
        return 'Calling ${_destinationController.text.trim()}...';
      case CallStatus.ringing:
        return 'Ringing...';
      case CallStatus.connected:
        return 'Connected';
      case CallStatus.ended:
        return 'Call ended';
    }
  }

  Color get _callStatusColor {
    switch (_callStatus) {
      case CallStatus.idle:
        return Colors.indigo;
      case CallStatus.calling:
      case CallStatus.ringing:
        return Colors.orange;
      case CallStatus.connected:
        return Colors.green;
      case CallStatus.ended:
        return Colors.grey;
    }
  }

  IconData get _callStatusIcon {
    switch (_callStatus) {
      case CallStatus.idle:
        return Icons.phone_outlined;
      case CallStatus.calling:
        return Icons.phone_forwarded_outlined;
      case CallStatus.ringing:
        return Icons.ring_volume_outlined;
      case CallStatus.connected:
        return Icons.phone_in_talk_outlined;
      case CallStatus.ended:
        return Icons.phone_disabled_outlined;
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final destination = _destinationController.text.trim().isEmpty
        ? '1000'
        : _destinationController.text.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Dial extension')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Registered account',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.displayName.isEmpty
                                ? widget.username
                                : widget.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${widget.username}@${widget.sipServer}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Janus: ${widget.janusUrl}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Call a SIP extension',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _destinationController,
                    enabled: !_isCallActive,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                    decoration: const InputDecoration(
                      labelText: 'Destination extension',
                      hintText: '1000',
                      prefixIcon: Icon(Icons.dialpad_outlined),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 20),
                  StatusCard(
                    title: 'Call status',
                    message: _callStatusText,
                    color: _callStatusColor,
                    icon: _callStatusIcon,
                  ),
                  if (_callStatus == CallStatus.connected) ...[
                    const SizedBox(height: 12),
                    Text(
                      _formatDuration(_callSeconds),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isCallActive ? null : _call,
                          icon: const Icon(Icons.call_outlined),
                          label: Text('Call $destination'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: Colors.green,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isCallActive ? _hangUp : null,
                          icon: const Icon(Icons.call_end_outlined),
                          label: const Text('Hang up'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _callStatus == CallStatus.connected
                              ? _toggleMute
                              : null,
                          icon: Icon(
                            _isMuted ? Icons.mic_off_outlined : Icons.mic_none,
                          ),
                          label: Text(_isMuted ? 'Muted' : 'Mute'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _callStatus == CallStatus.connected
                              ? _toggleSpeaker
                              : null,
                          icon: Icon(
                            _isSpeakerOn
                                ? Icons.volume_up_outlined
                                : Icons.volume_down_outlined,
                          ),
                          label: Text(_isSpeakerOn ? 'Speaker on' : 'Speaker'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Phase 1 simulation: Call changes local UI state only. '
                    'No WebRTC offer, audio stream, SIP INVITE, or SIP BYE '
                    'is sent.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({
    required this.title,
    required this.message,
    required this.color,
    required this.icon,
    super.key,
  });

  final String title;
  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(message, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
