import 'package:flutter/material.dart';

import '../services/permission_service.dart';

/// Hides [child] when the user lacks [actionKey]. Mirrors the web app's
/// `*ngIf="hasPermission('action_key')"` pattern.
class PermissionGate extends StatelessWidget {
  final String actionKey;
  final Widget child;
  final Widget? fallback;

  const PermissionGate({
    super.key,
    required this.actionKey,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final allowed =
        PermissionService.hasPermissionByActionKeySync(actionKey);
    if (allowed) return child;
    return fallback ?? const SizedBox.shrink();
  }
}

/// Full-screen placeholder when a route is opened without permission.
class PermissionDeniedScaffold extends StatelessWidget {
  final String featureName;

  const PermissionDeniedScaffold({
    super.key,
    required this.featureName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text(featureName),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                'Access restricted',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your role does not have permission to access $featureName. '
                'Contact your administrator if you believe this is a mistake.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
