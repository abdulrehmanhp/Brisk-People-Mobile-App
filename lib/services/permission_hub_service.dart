import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:signalr_netcore/signalr_client.dart';

import '../utils/jwt_utils.dart';
import 'auth_service.dart';
import 'permission_service.dart';

/// Listens to the backend SignalR hub at `/hubs/permissionHub`.
///
/// When an admin saves role permissions (`PUT /api/Auth/update-role`), the
/// server broadcasts `RoleUpdated` to the group `role_{orgId}_{roleId}`.
/// This service joins that group and re-fetches permissions so the mobile UI
/// updates without logout/login.
class PermissionHubService {
  PermissionHubService._();

  static const String _hubUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/hubs/permissionHub';

  static HubConnection? _connection;
  static bool _connecting = false;
  static String? _joinedOrgId;
  static String? _joinedRoleId;

  static Future<void> start() async {
    if (_connecting) return;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    if (token == null || token.trim().isEmpty) return;

    final ids = await _resolveHubIds(token);
    final orgId = ids.$1;
    final roleId = ids.$2;
    if (orgId == null || roleId == null) return;

    _connecting = true;
    try {
      if (_connection?.state == HubConnectionState.Connected &&
          _joinedOrgId == orgId &&
          _joinedRoleId == roleId) {
        return;
      }

      await stop();

      final httpOptions = HttpConnectionOptions(
        accessTokenFactory: () async => (await AuthService.getToken()) ?? '',
      );

      final hub = HubConnectionBuilder()
          .withUrl(_hubUrl, options: httpOptions)
          .withAutomaticReconnect()
          .build();

      hub.on('RoleUpdated', _onRoleUpdated);
      hub.onreconnected(({String? connectionId}) async {
        await _joinRoleGroup(hub, orgId, roleId);
      });

      await hub.start();
      await _joinRoleGroup(hub, orgId, roleId);

      _connection = hub;
      _joinedOrgId = orgId;
      _joinedRoleId = roleId;
    } catch (_) {
      await stop();
    } finally {
      _connecting = false;
    }
  }

  static Future<(String?, String?)> _resolveHubIds(String token) async {
    var orgId = JwtUtils.getClaim(token, 'organizationId');
    var roleId = JwtUtils.getClaim(token, 'roleId');

    if (roleId == null || roleId.isEmpty) {
      final perms = await PermissionService.getPermissions();
      roleId = perms?.roleId;
    }

    return (orgId, roleId);
  }

  static Future<void> _joinRoleGroup(
    HubConnection hub,
    String organizationId,
    String roleId,
  ) async {
    if (hub.state != HubConnectionState.Connected) return;
    await hub.invoke('JoinRole', args: <Object>[organizationId, roleId]);
  }

  static void _onRoleUpdated(List<Object?>? arguments) {
    unawaited(_handleRoleUpdated(arguments));
  }

  static Future<void> _handleRoleUpdated(List<Object?>? arguments) async {
    // Optional: verify payload targets our role (we only receive events for
    // groups we joined, but double-check when data is present).
    if (arguments != null && arguments.isNotEmpty) {
      final payload = arguments.first;
      if (payload is Map) {
        final updatedRoleId =
            payload['roleId']?.toString() ?? payload['RoleId']?.toString();
        if (updatedRoleId != null &&
            _joinedRoleId != null &&
            updatedRoleId.toLowerCase() != _joinedRoleId!.toLowerCase()) {
          return;
        }
      }
    }

    await AuthService.refreshPermissions();
  }

  static Future<void> stop() async {
    _connecting = false;
    _joinedOrgId = null;
    _joinedRoleId = null;

    final hub = _connection;
    _connection = null;
    if (hub == null) return;

    try {
      await hub.stop();
    } catch (_) {}
  }
}
