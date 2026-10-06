import 'dart:async';

import 'package:flutter/material.dart';

void main() {
  runApp(const JanusSipDemoApp());
}

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
    text: 'http://192.168.97.53:8088/janus',
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

  @override
  void dispose() {
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
    });

    await Future<void>.delayed(const Duration(seconds: 1));

    if (!mounted) {
      return;
    }

    setState(() {
      _isRegistering = false;
      _isRegistered = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Prototype only: registration status changed locally. '
          'No Janus or SIP request has been sent yet.',
        ),
      ),
    );
  }

  void _resetRegistration() {
    setState(() {
      _isRegistering = false;
      _isRegistered = false;
    });
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
        ? 'Registering...'
        : _isRegistered
        ? 'Registered (prototype)'
        : 'Not registered';

    final statusColor = _isRegistering
        ? Colors.orange
        : _isRegistered
        ? Colors.green
        : Colors.grey;

    return Scaffold(
      appBar: AppBar(title: const Text('Janus SIP Client'), centerTitle: false),
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
                      'Enter the Janus gateway and SIP account details. '
                      'This screen is UI-only in Phase 1.',
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
                              decoration: const InputDecoration(
                                labelText: 'Janus URL',
                                hintText: 'http://192.168.97.53:8088/janus',
                                prefixIcon: Icon(Icons.hub_outlined),
                                border: OutlineInputBorder(),
                              ),
                              validator: _janusUrlValidator,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _sipServerController,
                              keyboardType: TextInputType.url,
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
                              decoration: const InputDecoration(
                                labelText: 'SIP username',
                                hintText: 'For example: janus',
                                prefixIcon: Icon(Icons.person_outline),
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) =>
                                  _requiredValidator(value, 'SIP username'),
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
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
                    Card(
                      color: statusColor.withValues(alpha: 0.12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              _isRegistering
                                  ? Icons.sync
                                  : _isRegistered
                                  ? Icons.check_circle_outline
                                  : Icons.info_outline,
                              color: statusColor,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Registration status',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    statusText,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _isRegistering ? null : _register,
                      icon: _isRegistering
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              _isRegistered
                                  ? Icons.refresh
                                  : Icons.login_outlined,
                            ),
                      label: Text(
                        _isRegistering
                            ? 'Registering...'
                            : _isRegistered
                            ? 'Register again'
                            : 'Register',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_isRegistered)
                      OutlinedButton.icon(
                        onPressed: _resetRegistration,
                        icon: const Icon(Icons.logout_outlined),
                        label: const Text('Reset prototype status'),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Phase 1: this button validates the form and changes '
                      'only local UI state. Phase 2 will send the Janus '
                      'SIP-plugin registration request.',
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
