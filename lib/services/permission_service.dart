import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Models

class PermissionAction {
  final String actionId;
  final String actionName;
  final String actionKey;
  final bool hasPermission;

  const PermissionAction({
    required this.actionId,
    required this.actionName,
    required this.actionKey,
    required this.hasPermission,
  });

  factory PermissionAction.fromJson(Map<String, dynamic> json) =>
      PermissionAction(
        actionId: json['actionId']?.toString() ?? '',
        actionName: json['actionName']?.toString() ?? '',
        actionKey: json['actionKey']?.toString() ?? '',
        hasPermission: json['hasPermission'] == true,
      );
}

class PermissionSubMenu {
  final String subMenuId;
  final String subMenuName;
  final List<PermissionAction> actions;

  const PermissionSubMenu({
    required this.subMenuId,
    required this.subMenuName,
    required this.actions,
  });

  factory PermissionSubMenu.fromJson(Map<String, dynamic> json) =>
      PermissionSubMenu(
        subMenuId: json['subMenuId']?.toString() ?? '',
        subMenuName: json['subMenuName']?.toString() ?? '',
        actions: (json['actions'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(PermissionAction.fromJson)
            .toList(),
      );
}

class PermissionMenu {
  final String menuId;
  final String menuName;
  final List<PermissionSubMenu> subMenus;

  const PermissionMenu({
    required this.menuId,
    required this.menuName,
    required this.subMenus,
  });

  factory PermissionMenu.fromJson(Map<String, dynamic> json) => PermissionMenu(
    menuId: json['menuId']?.toString() ?? '',
    menuName: json['menuName']?.toString() ?? '',
    subMenus: (json['subMenus'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PermissionSubMenu.fromJson)
        .toList(),
  );
}

class UserPermissions {
  final String userId;
  final String? userName;
  final String email;
  final String roleId;
  final String roleName;
  final List<PermissionMenu> menus;

  const UserPermissions({
    required this.userId,
    this.userName,
    required this.email,
    required this.roleId,
    required this.roleName,
    required this.menus,
  });

  factory UserPermissions.fromJson(Map<String, dynamic> json) =>
      UserPermissions(
        userId: json['userId']?.toString() ?? '',
        userName: json['userName']?.toString(),
        email: json['email']?.toString() ?? '',
        roleId: json['roleId']?.toString() ?? '',
        roleName: json['roleName']?.toString() ?? '',
        menus: (json['menus'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(PermissionMenu.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'userName': userName,
    'email': email,
    'roleId': roleId,
    'roleName': roleName,
    'menus': menus
        .map(
          (m) => {
            'menuId': m.menuId,
            'menuName': m.menuName,
            'subMenus': m.subMenus
                .map(
                  (sm) => {
                    'subMenuId': sm.subMenuId,
                    'subMenuName': sm.subMenuName,
                    'actions': sm.actions
                        .map(
                          (a) => {
                            'actionId': a.actionId,
                            'actionName': a.actionName,
                            'actionKey': a.actionKey,
                            'hasPermission': a.hasPermission,
                          },
                        )
                        .toList(),
                  },
                )
                .toList(),
          },
        )
        .toList(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// PermissionService
// ─────────────────────────────────────────────────────────────────────────────

class PermissionService {
  static const String _baseUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Auth';
  static const String _permissionsKey = 'user_permissions';

  // In-memory cache so we avoid repeated SharedPreferences reads every check.
  static UserPermissions? _cached;

  // ── Fetch & persist ──────────────────────────────────────────────────────

  /// Fetches permissions for [userId] from the backend, stores them in
  /// SharedPreferences and in the in-memory cache, then returns them.
  /// Returns null on any error so callers can degrade gracefully.
  static Future<UserPermissions?> fetchAndStore(String userId) async {
    if (userId.trim().isEmpty) return null;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/get-user-permissions/$userId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      if (body['success'] != true) return null;

      final data = body['data'];
      if (data is! Map<String, dynamic>) return null;

      final permissions = UserPermissions.fromJson(data);
      _cached = permissions;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_permissionsKey, jsonEncode(permissions.toJson()));

      return permissions;
    } catch (_) {
      return null;
    }
  }

  // ── Load from cache ──────────────────────────────────────────────────────

  /// Returns the cached permissions (memory first, then SharedPreferences).
  static Future<UserPermissions?> getPermissions() async {
    if (_cached != null) return _cached;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_permissionsKey);
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      _cached = UserPermissions.fromJson(decoded);
      return _cached;
    } catch (_) {
      return null;
    }
  }

  // ── Clear ────────────────────────────────────────────────────────────────

  /// Clears cached permissions on logout.
  static Future<void> clear() async {
    _cached = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_permissionsKey);
  }

  // ── Permission checks ────────────────────────────────────────────────────

  /// Checks whether the user has the specific [actionKey] permission under
  /// [menuName] → [subMenuName].
  static Future<bool> hasActionPermission(
    String menuName,
    String subMenuName,
    String actionKey,
  ) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;
    return _checkAction(permissions, menuName, subMenuName, actionKey);
  }

  /// Synchronous version — only works if permissions are already in memory.
  /// Use after [fetchAndStore] or [getPermissions] has been awaited.
  static bool hasActionPermissionSync(
    String menuName,
    String subMenuName,
    String actionKey,
  ) {
    if (_cached == null) return false;
    return _checkAction(_cached!, menuName, subMenuName, actionKey);
  }

  /// Returns true if the user has at least one permitted action under
  /// [menuName] → [subMenuName].
  static Future<bool> hasSubMenuPermission(
    String menuName,
    String subMenuName,
  ) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;

    final menu = _findMenu(permissions, menuName);
    if (menu == null) return false;

    final subMenu = _findSubMenu(menu, subMenuName);
    if (subMenu == null) return false;

    return subMenu.actions.any((a) => a.hasPermission);
  }

  /// Returns true if the user has at least one permitted action under any
  /// sub-menu of [menuName].
  static Future<bool> hasMenuPermission(String menuName) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;

    final menu = _findMenu(permissions, menuName);
    if (menu == null) return false;

    return menu.subMenus.any(
      (sm) => sm.actions.any((a) => a.hasPermission),
    );
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  static bool _checkAction(
    UserPermissions permissions,
    String menuName,
    String subMenuName,
    String actionKey,
  ) {
    final menu = _findMenu(permissions, menuName);
    if (menu == null) return false;

    final subMenu = _findSubMenu(menu, subMenuName);
    if (subMenu == null) return false;

    final action = subMenu.actions.firstWhere(
      (a) => a.actionKey.toLowerCase() == actionKey.toLowerCase(),
      orElse: () => const PermissionAction(
        actionId: '',
        actionName: '',
        actionKey: '',
        hasPermission: false,
      ),
    );

    return action.hasPermission;
  }

  static PermissionMenu? _findMenu(
    UserPermissions permissions,
    String menuName,
  ) {
    try {
      return permissions.menus.firstWhere(
        (m) => m.menuName.toLowerCase() == menuName.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  static PermissionSubMenu? _findSubMenu(
    PermissionMenu menu,
    String subMenuName,
  ) {
    try {
      return menu.subMenus.firstWhere(
        (sm) => sm.subMenuName.toLowerCase() == subMenuName.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }
}
