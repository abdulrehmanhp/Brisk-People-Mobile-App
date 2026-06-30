import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Models — mirror backend UserPermissionResponse tree.

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

/// Central registry of action keys the mobile app checks — must match the web
/// frontend and backend `[PermissionAuthorize]` attributes exactly.
class PermissionKeys {
  PermissionKeys._();

  // Attendance → Time Tracker
  static const String clockIn = 'CLOCK_IN_BUTTON';
  static const String clockOut = 'CLOCK_OUT_BUTTON';
  static const String recentAttendanceTable = 'RECENT_ATTENDANCE_TABLE';
  static const String todaySessionTable = 'TODAY_SESSION_TABLE';

  // Attendance → My Attendance
  static const String myAttendanceSummary = 'my_attendance_summary';
  static const String attendanceRecordTable = 'ATTENDANCE_RECORD_TABLE';

  // Attendance → Shifts
  static const String createShiftSwapRequest = 'SWAP_SHIFT_BUTTON';
  static const String teamShiftSwapTable = 'TEAM_SHIFT_SWAP_TABLE';

  // Leave Management → My Leaves
  static const String myLeaveRequestLeave = 'my_leave_request_leave';
  static const String myLeaveEditRequest = 'my_leave_edit_request';
  static const String myLeaveCancelRequest = 'my_leave_cancel_request';

  // Leave Management → Team Leaves / Team Requests
  static const String teamLeaveApprove = 'team_leave_approve';
  static const String teamLeaveReject = 'team_leave_reject';

  // Payroll
  static const String myPayslip = 'my_payslip';

  // Admin
  static const String adminDashboard = 'admin_dashboard';

  /// Any key that unlocks the Payroll bottom-nav tab (mirrors web sidebar).
  static const List<String> payrollNavActionKeys = [
    'my_payslip',
    'compliance_payslip_view',
    'payslip_generation',
    'mail_upload_payslip',
    'payroll_rules_view',
    'overtime_entry_view',
    'attendance_summary_view',
    'late_attendance_view',
    'leave_summary_view',
    'payroll_period_view',
    'my_benefits',
    'payroll_calculation',
    'payroll_result',
    'bonus_entry_view',
    'performance_pay_view',
    'loan_admin_view',
    'pf_admin_view',
    'gratuity_admin_view',
    'salary_advance_admin_list',
    'salary_advance_admin_view',
  ];
}

class PermissionService {
  static const String _baseUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Auth';
  static const String _permissionsKey = 'user_permissions';

  static UserPermissions? _cached;
  static int _version = 0;
  static final StreamController<int> _changesController =
      StreamController<int>.broadcast();

  /// Increments every time permissions are refreshed from the server.
  static int get version => _version;

  /// Fires with the new [version] after permissions are updated.
  static Stream<int> get onChanged => _changesController.stream;

  static void _notifyChanged() {
    _version++;
    if (!_changesController.isClosed) {
      _changesController.add(_version);
    }
  }

  /// Loads from cache first, then refreshes from
  /// `GET /api/Auth/get-user-permissions/{userId}`.
  static Future<UserPermissions?> fetchAndStore(String userId) async {
    if (userId.trim().isEmpty) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http
          .get(
            Uri.parse('$_baseUrl/get-user-permissions/$userId'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return await getPermissions();
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return await getPermissions();
      if (body['success'] != true) return await getPermissions();

      final data = body['data'];
      if (data is! Map<String, dynamic>) return await getPermissions();

      final permissions = UserPermissions.fromJson(data);
      _cached = permissions;

      await prefs.setString(_permissionsKey, jsonEncode(permissions.toJson()));

      _notifyChanged();
      return permissions;
    } catch (_) {
      return await getPermissions();
    }
  }

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

  static Future<void> clear() async {
    _cached = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_permissionsKey);
    _notifyChanged();
  }

  static Future<bool> hasActionPermission(
    String menuName,
    String subMenuName,
    String actionKey,
  ) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;
    return _checkAction(permissions, menuName, subMenuName, actionKey);
  }

  static bool hasActionPermissionSync(
    String menuName,
    String subMenuName,
    String actionKey,
  ) {
    if (_cached == null) return false;
    return _checkAction(_cached!, menuName, subMenuName, actionKey);
  }

  static Future<bool> hasSubMenuPermission(
    String menuName,
    String subMenuName, {
    List<String> aliases = const [],
  }) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;
    return _hasAnySubMenuPermission(permissions, menuName, [
      subMenuName,
      ...aliases,
    ]);
  }

  static Future<bool> hasMenuPermission(String menuName) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;

    final menu = _findMenu(permissions, menuName);
    if (menu == null) return false;

    return menu.subMenus.any(
      (sm) => sm.actions.any((a) => a.hasPermission),
    );
  }

  static Future<bool> hasMenuParentPermission(String menuName) =>
      hasMenuPermission(menuName);

  static Future<bool> hasPermissionByActionKey(String actionKey) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;
    return _checkActionKeyAnywhere(permissions, actionKey);
  }

  static bool hasPermissionByActionKeySync(String actionKey) {
    if (_cached == null) return false;
    return _checkActionKeyAnywhere(_cached!, actionKey);
  }

  static Future<bool> hasAnyPermissionByActionKeys(
    List<String> actionKeys,
  ) async {
    final permissions = await getPermissions();
    if (permissions == null) return false;
    return actionKeys.any((k) => _checkActionKeyAnywhere(permissions, k));
  }

  static bool hasAnyPermissionByActionKeysSync(List<String> actionKeys) {
    if (_cached == null) return false;
    return actionKeys.any((k) => _checkActionKeyAnywhere(_cached!, k));
  }

  static Future<String> dumpAsPrettyJson(String userId) async {
    final fresh = await fetchAndStore(userId);
    final permissions = fresh ?? await getPermissions();
    if (permissions == null) {
      return 'No permissions could be loaded for this user.\n'
          'Check your internet connection and try again.';
    }
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(permissions.toJson());
  }

  static bool _checkActionKeyAnywhere(
    UserPermissions permissions,
    String actionKey,
  ) {
    final normalized = actionKey.toLowerCase();
    for (final menu in permissions.menus) {
      for (final subMenu in menu.subMenus) {
        for (final action in subMenu.actions) {
          if (action.actionKey.toLowerCase() == normalized &&
              action.hasPermission) {
            return true;
          }
        }
      }
    }
    return false;
  }

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

  static bool _hasAnySubMenuPermission(
    UserPermissions permissions,
    String menuName,
    List<String> subMenuNames,
  ) {
    final menu = _findMenu(permissions, menuName);
    if (menu == null) return false;

    for (final name in subMenuNames) {
      final subMenu = _findSubMenu(menu, name);
      if (subMenu != null && subMenu.actions.any((a) => a.hasPermission)) {
        return true;
      }
    }
    return false;
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
