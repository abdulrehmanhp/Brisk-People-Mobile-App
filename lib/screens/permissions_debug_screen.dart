import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/permission_service.dart';

/// Shows the raw permission tree returned by the backend so developers and
/// admins can verify which action keys are granted for the logged-in user.
class PermissionsDebugScreen extends StatefulWidget {
  const PermissionsDebugScreen({super.key});

  @override
  State<PermissionsDebugScreen> createState() => _PermissionsDebugScreenState();
}

class _PermissionsDebugScreenState extends State<PermissionsDebugScreen> {
  bool _loading = true;
  String _payload = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final info = await AuthService.getUserInfo();
    final userId = info['userId'] ?? '';
    await AuthService.refreshPermissions();
    final json = await PermissionService.dumpAsPrettyJson(userId);
    if (!mounted) return;
    setState(() {
      _payload = json;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text(
          'My Permissions',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF2563EB),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Refresh from server',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Copy JSON',
            onPressed: _payload.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _payload));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Permissions copied')),
                    );
                  },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _payload,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
    );
  }
}
