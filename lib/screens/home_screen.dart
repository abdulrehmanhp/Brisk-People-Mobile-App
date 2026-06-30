import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';
import '../services/leave_service.dart';
import '../services/permission_service.dart';
import 'profile_screen.dart';
import 'attendance_screen.dart';
import 'attendance_history_screen.dart';
import 'leave_screen.dart';
import 'payroll_screen.dart';
import 'shift_swap_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onClockAction;
  final VoidCallback? onClockStatusChanged;

  const HomeScreen({super.key, this.onClockAction, this.onClockStatusChanged});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late Timer _timer;
  Timer? _approvalRefreshTimer;
  DateTime _currentTime = DateTime.now();

  // User info
  String _firstName = '';
  String _lastName = '';
  String _role = '';
  String _userId = '';
  String _profileImageUrl = '';

  // Attendance
  DateTime? checkInTime;
  DateTime? checkOutTime;
  bool isCheckedIn = false;
  String? shiftId;
  String? _token;
  bool _isSubmitting = false;

  // Total hours worked today (completed sessions only; live part added via getter)
  Duration _totalWorkedToday = Duration.zero;
  // Start of the currently active session (used for live hours ticker)
  DateTime? _activeSessionStart;

  // Notifications
  bool _hasUnreadNotification = false;
  String _welcomeNotificationName = '';
  final List<_HomeNotificationItem> _activityNotifications = [];

  // Weekly attendance: map of date string (yyyy-MM-dd) -> 'present' | 'absent'
  Map<String, String> _weeklyAttendance = {};

  List<LeaveRequestItem> _pendingLeaveApprovals = [];
  List<ShiftSwapRequestItem> _pendingShiftSwapApprovals = [];
  // Whether the user can approve team leave requests (action key:
  // 'team_leave_approve' under Leave Management -> Team Leaves).
  // Resolved from the permissions API — no role strings here.
  bool _canApproveRequests = false;
  // Whether the user can see/manage team shift-swap requests (action key:
  // 'TEAM_SHIFT_SWAP_TABLE' under Attendance -> Shifts). This is a SEPARATE
  // permission from leave approval — a role can have one without the other,
  // so they must never be conflated into a single flag.
  bool _canManageTeamShiftSwaps = false;

  // Quick Action visibility — each mirrors the exact action key the web app
  // checks for the same feature (see PermissionKeys for the full mapping).
  bool _canClockIn = false;
  bool _canClockOut = false;
  bool _canApplyLeave = false;
  bool _canViewPayslip = false;
  bool _canCreateShiftSwap = false;
  bool _canViewMyAttendanceSummary = false;
  // Becomes true once the permission flags above have been resolved at
  // least once, so the Quick Actions grid doesn't flash "nothing" before
  // the very first permission check completes.
  bool _quickActionsResolved = false;

  String _announcementTitle = 'Office closed on 23 March';
  String _announcementBody = 'Public Holiday observation. Enjoy your day off!';

  StreamSubscription<int>? _permissionSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _permissionSubscription = PermissionService.onChanged.listen((_) {
      if (mounted) reloadPermissions();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
        // Update live hours if checked in
        if (isCheckedIn && checkInTime != null) {
          _recalcLiveHours();
        }
      }
    });
    _loadUserInfo();
    loadTodayAttendance();
    _loadWeeklyAttendance();
    _checkFirstLoginNotification();
    _loadAnnouncementFromStorage();
    _loadPendingApprovals();
    _approvalRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        _loadPendingApprovals();
      }
    });
  }

  @override
  void dispose() {
    _permissionSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _timer.cancel();
    _approvalRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh profile picture when app comes to foreground
      _refreshProfilePicture();
    }
  }

  void _recalcLiveHours() {
    if (checkInTime != null && checkOutTime == null) {
      // Base accumulated hours from previous sessions + current live session
      // _totalWorkedToday already includes the current session from loadTodayAttendance
      // We just need to re-trigger build for the timer display
    }
  }

  Future<void> _loadUserInfo() async {
    final info = await AuthService.getUserInfo();
    if (mounted) {
      setState(() {
        _firstName = info['firstName'] ?? '';
        _lastName = info['lastName'] ?? '';
        _role = info['role'] ?? '';
        _userId = info['userId'] ?? '';
        _profileImageUrl = info['profileUrl'] ?? '';
      });
    }

    final refreshed = await AuthService.getProfilePictureDisplayUrl(
      refresh: true,
    );
    if (mounted && refreshed != null) {
      setState(() => _profileImageUrl = refreshed);
    }

    // Resolve every role-gated capability used on this screen from the
    // permissions API — mirrors exactly what the web app's sidebar/components
    // check for the same features (see PermissionKeys for the key mapping
    // and reasoning). No hard-coded role-name strings anywhere here.
    await _loadPermissionFlags();

    await _loadPendingApprovals();
  }

  /// Called when permissions change live (SignalR) or on parent refresh.
  Future<void> reloadPermissions() async {
    await _loadPermissionFlags();
    await _loadPendingApprovals();
    if (mounted) setState(() {});
  }

  /// Resolves all permission-gated UI flags used by this screen. Safe to
  /// call repeatedly (e.g. on app resume) to pick up role changes made by a
  /// superadmin without requiring the employee to log out.
  Future<void> _loadPermissionFlags() async {
    final results = await Future.wait([
      PermissionService.hasPermissionByActionKey(PermissionKeys.teamLeaveApprove),
      PermissionService.hasPermissionByActionKey(PermissionKeys.teamShiftSwapTable),
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockIn),
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockOut),
      PermissionService.hasPermissionByActionKey(PermissionKeys.myLeaveRequestLeave),
      PermissionService.hasPermissionByActionKey(PermissionKeys.myPayslip),
      PermissionService.hasPermissionByActionKey(PermissionKeys.createShiftSwapRequest),
      PermissionService.hasPermissionByActionKey(PermissionKeys.myAttendanceSummary),
    ]);

    if (!mounted) return;
    setState(() {
      _canApproveRequests = results[0];
      _canManageTeamShiftSwaps = results[1];
      _canClockIn = results[2];
      _canClockOut = results[3];
      _canApplyLeave = results[4];
      _canViewPayslip = results[5];
      _canCreateShiftSwap = results[6];
      _canViewMyAttendanceSummary = results[7];
      _quickActionsResolved = true;
    });
  }

  Future<void> _refreshProfilePicture() async {
    // Refresh profile picture URL when returning from profile screen
    final refreshed = await AuthService.getProfilePictureDisplayUrl(
      refresh: true,
    );
    if (mounted && refreshed != null && refreshed != _profileImageUrl) {
      setState(() => _profileImageUrl = refreshed);
    }
  }

  Future<void> loadTodayAttendance() async {
    _token ??= await AuthService.getToken();
    if (_token == null || _token!.isEmpty) return;

    final response = await AttendanceService.getTodayAttendance(_token!);
    final dynamic data = response?['data'];

    if (data is! Map<String, dynamic>) {
      // No attendance record yet (first clock-in of the day) — still fetch shiftId
      if ((shiftId ?? '').isEmpty) {
        final userInfo = await AuthService.getUserInfo();
        final storedUserId = userInfo['userId'];
        if (storedUserId != null && storedUserId.isNotEmpty) {
          final sid = await AttendanceService.getEmployeeShiftId(
            _token!,
            storedUserId,
          );
          if (mounted && sid != null && sid.isNotEmpty) {
            setState(() => shiftId = sid);
          }
        }
      }
      return;
    }

    dynamic rawShiftId = data['shiftId'] ?? data['ShiftId'];
    final String? employeeId = (data['employeeId'] ?? data['EmployeeId'])
        ?.toString();
    if (rawShiftId == null && employeeId != null && employeeId.isNotEmpty) {
      rawShiftId = await AttendanceService.getEmployeeShiftId(
        _token!,
        employeeId,
      );
    }

    // ── Use sessions API for authoritative clock-in state ──
    final todayStart = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final sessionsResult = await AttendanceService.getEmployeeAllAttendance(
      _token!,
      startDate: todayStart.toUtc().toIso8601String(),
      endDate: DateTime.now().toUtc().toIso8601String(),
      pageNumber: 1,
      pageSize: 50,
    );
    final sessionsList =
        (sessionsResult['data'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];

    DateTime? firstIn;
    DateTime? lastOut;
    DateTime? activeStart;
    Duration completedTotal = Duration.zero;

    if (sessionsList.isNotEmpty) {
      for (final entry in sessionsList) {
        final cin = _parseDateTime(
          entry['checkInTime'] ?? entry['CheckInTime'],
        );
        final cout = _parseDateTime(
          entry['checkOutTime'] ?? entry['CheckOutTime'],
        );
        if (cin != null) {
          // Track first check-in of the day
          if (firstIn == null || cin.isBefore(firstIn)) firstIn = cin;
          if (cout != null) {
            completedTotal += cout.difference(cin);
            if (lastOut == null || cout.isAfter(lastOut)) lastOut = cout;
          } else {
            // This session is still active — track latest active start
            if (activeStart == null || cin.isAfter(activeStart)) {
              activeStart = cin;
            }
          }
        }
      }
    } else {
      // No sessions from API — fall back to main attendance record
      final parsedCheckIn = _parseDateTime(
        data['checkInTime'] ?? data['CheckInTime'],
      );
      final parsedCheckOut = _parseDateTime(
        data['checkOutTime'] ?? data['CheckOutTime'],
      );
      firstIn = parsedCheckIn;
      if (parsedCheckIn != null && parsedCheckOut == null) {
        activeStart = parsedCheckIn;
      } else {
        lastOut = parsedCheckOut;
      }
    }

    final bool nowCheckedIn = activeStart != null;
    // If still clocked in, the Out time shown is the last completed session's out
    // (lastOut is only set for completed sessions, so it correctly stays null
    // if the ONLY session today is still active)

    if (!mounted) return;
    setState(() {
      shiftId = rawShiftId?.toString();
      checkInTime = firstIn;
      checkOutTime = lastOut;
      isCheckedIn = nowCheckedIn;
      _activeSessionStart = activeStart;
      _totalWorkedToday = completedTotal;
    });
    widget.onClockStatusChanged?.call();
  }

  Future<void> _loadWeeklyAttendance() async {
    _token ??= await AuthService.getToken();
    if (_token == null || _token!.isEmpty) return;

    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));

    // Use EmployeeAllAttendance API to get accurate session-based data for the week
    final result = await AttendanceService.getEmployeeAllAttendance(
      _token!,
      startDate: monday.toUtc().toIso8601String(),
      endDate: DateTime(
        sunday.year,
        sunday.month,
        sunday.day,
        23,
        59,
        59,
      ).toUtc().toIso8601String(),
      pageNumber: 1,
      pageSize: 100,
    );
    final sessions =
        (result['data'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        [];

    final Map<String, String> weekly = {};
    for (final s in sessions) {
      final wd = s['workDate']?.toString() ?? '';
      final d = DateTime.tryParse(wd);
      if (d != null) {
        final key = DateFormat('yyyy-MM-dd').format(d);
        final ci = s['checkInTime'] ?? s['CheckInTime'];
        if (ci != null) weekly[key] = 'present';
      }
    }

    // Also mark today if we have check-in from live state
    final todayKey = DateFormat('yyyy-MM-dd').format(now);
    if (checkInTime != null && !weekly.containsKey(todayKey)) {
      weekly[todayKey] = 'present';
    }

    if (mounted) setState(() => _weeklyAttendance = weekly);
  }

  Future<void> _loadAnnouncementFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _announcementTitle =
          prefs.getString('announcement_title') ?? _announcementTitle;
      _announcementBody =
          prefs.getString('announcement_body') ?? _announcementBody;
    });
  }

  Future<void> _loadPendingApprovals() async {
    _token ??= await AuthService.getToken();
    if (_token == null || _token!.isEmpty) return;

    if (_userId.trim().isEmpty || _role.trim().isEmpty) {
      final info = await AuthService.getUserInfo();
      _userId = info['userId'] ?? '';
      _role = info['role'] ?? '';
    }

    // Re-check permission flags in case they weren't loaded yet (e.g. on a
    // timer refresh that fires before _loadUserInfo finishes on first
    // launch). These two capabilities are governed by DIFFERENT permissions
    // on the web app ('team_leave_approve' vs 'TEAM_SHIFT_SWAP_TABLE') and
    // must stay independent — a role can have one without the other.
    if (!_canApproveRequests || !_canManageTeamShiftSwaps) {
      final results = await Future.wait([
        PermissionService.hasPermissionByActionKey(
          PermissionKeys.teamLeaveApprove,
        ),
        PermissionService.hasPermissionByActionKey(
          PermissionKeys.teamShiftSwapTable,
        ),
      ]);
      if (mounted &&
          (results[0] != _canApproveRequests ||
              results[1] != _canManageTeamShiftSwaps)) {
        setState(() {
          _canApproveRequests = results[0];
          _canManageTeamShiftSwaps = results[1];
        });
      }
    }

    final leaveFuture = _canApproveRequests
        ? LeaveService.getTeamLeaveRequests(_token!, currentEmployeeId: _userId)
        : LeaveService.getMyLeaveRequests(_token!, currentEmployeeId: _userId);
    final swapFuture = _canManageTeamShiftSwaps
        ? AttendanceService.getPendingShiftSwapRequests(_token!)
        : AttendanceService.getShiftSwapRequestsByEmployee(_token!, _userId);

    final results = await Future.wait<dynamic>([leaveFuture, swapFuture]);
    final leaveResult = results[0] as List<LeaveRequestItem>;
    final swapResult = results[1] as List<ShiftSwapRequestItem>;

    final pendingLeaves = _canApproveRequests
        ? leaveResult
        : leaveResult.where((e) => e.isPending).toList();
    final pendingSwaps = _canManageTeamShiftSwaps
        ? swapResult
        : swapResult.where((e) => e.isPending).toList();

    // Each notification helper only cares about the list relevant to its own
    // role (manager vs employee) — pass an empty list for whichever
    // perspective doesn't apply so a non-manager never gets "new team
    // request" notifications, and vice versa.
    await _notifyManagerForNewPendingRequests(
      _canApproveRequests ? pendingLeaves : const <LeaveRequestItem>[],
      _canManageTeamShiftSwaps ? pendingSwaps : const <ShiftSwapRequestItem>[],
    );
    await _notifyEmployeeForDecisionUpdates(
      _canApproveRequests ? const <LeaveRequestItem>[] : leaveResult,
      _canManageTeamShiftSwaps ? const <ShiftSwapRequestItem>[] : swapResult,
    );

    if (!mounted) return;
    setState(() {
      _pendingLeaveApprovals = pendingLeaves;
      _pendingShiftSwapApprovals = pendingSwaps;
    });
  }

  String _notifKey(String name) => 'home_notif_${_userId}_$name';

  void _addActivityNotification(_HomeNotificationItem item) {
    if (_activityNotifications.any((e) => e.id == item.id)) return;
    if (!mounted) return;
    setState(() {
      _activityNotifications.insert(0, item);
      if (_activityNotifications.length > 25) {
        _activityNotifications.removeRange(25, _activityNotifications.length);
      }
      _hasUnreadNotification = true;
    });
  }

  Future<void> _notifyManagerForNewPendingRequests(
    List<LeaveRequestItem> pendingLeaves,
    List<ShiftSwapRequestItem> pendingSwaps,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final previousLeaveIds =
        prefs.getStringList(_notifKey('manager_pending_leave_ids')) ??
        <String>[];
    final previousSwapIds =
        prefs.getStringList(_notifKey('manager_pending_swap_ids')) ??
        <String>[];

    final leaveIds = pendingLeaves
        .map((e) => e.requestId)
        .where((e) => e.isNotEmpty)
        .toSet();
    final swapIds = pendingSwaps
        .map((e) => e.requestId)
        .where((e) => e.isNotEmpty)
        .toSet();

    for (final leave in pendingLeaves) {
      if (!previousLeaveIds.contains(leave.requestId)) {
        final requester = leave.employeeName.trim().isEmpty
            ? 'An employee'
            : leave.employeeName.trim();
        _addActivityNotification(
          _HomeNotificationItem(
            id: 'mgr_leave_${leave.requestId}',
            title: 'New Leave Request',
            body: '$requester requested ${leave.typeName} leave.',
            target: _HomeNotificationTarget.leaveManager,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    for (final swap in pendingSwaps) {
      if (!previousSwapIds.contains(swap.requestId)) {
        final requester = swap.employeeName.trim().isEmpty
            ? 'An employee'
            : swap.employeeName.trim();
        _addActivityNotification(
          _HomeNotificationItem(
            id: 'mgr_swap_${swap.requestId}',
            title: 'New Shift Swap Request',
            body: '$requester requested a shift swap.',
            target: _HomeNotificationTarget.shiftManager,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    await prefs.setStringList(
      _notifKey('manager_pending_leave_ids'),
      leaveIds.toList(),
    );
    await prefs.setStringList(
      _notifKey('manager_pending_swap_ids'),
      swapIds.toList(),
    );
  }

  Future<void> _notifyEmployeeForDecisionUpdates(
    List<LeaveRequestItem> allLeaves,
    List<ShiftSwapRequestItem> allSwaps,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final previousLeaveRaw = prefs.getString(
      _notifKey('employee_leave_status_map'),
    );
    final previousSwapRaw = prefs.getString(
      _notifKey('employee_swap_status_map'),
    );

    Map<String, dynamic> safeDecodeMap(String? raw) {
      if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
      return <String, dynamic>{};
    }

    final Map<String, dynamic> previousLeaveMap = safeDecodeMap(
      previousLeaveRaw,
    );
    final Map<String, dynamic> previousSwapMap = safeDecodeMap(previousSwapRaw);

    final Map<String, String> currentLeaveMap = {};
    for (final leave in allLeaves) {
      final id = leave.requestId.trim();
      if (id.isEmpty) continue;
      final current = leave.status.toLowerCase();
      final previous = (previousLeaveMap[id] ?? '').toString().toLowerCase();
      currentLeaveMap[id] = current;
      final isDecision = current == 'approved' || current == 'rejected';
      if (previous == 'pending' && isDecision) {
        _addActivityNotification(
          _HomeNotificationItem(
            id: 'emp_leave_${id}_$current',
            title: 'Leave Request ${_capitalize(current)}',
            body: '${leave.typeName} leave was $current.',
            target: _HomeNotificationTarget.leaveEmployee,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    final Map<String, String> currentSwapMap = {};
    for (final swap in allSwaps) {
      final id = swap.requestId.trim();
      if (id.isEmpty) continue;
      final current = swap.status.toLowerCase();
      final previous = (previousSwapMap[id] ?? '').toString().toLowerCase();
      currentSwapMap[id] = current;
      final isDecision = current == 'approved' || current == 'rejected';
      if (previous == 'pending' && isDecision) {
        _addActivityNotification(
          _HomeNotificationItem(
            id: 'emp_swap_${id}_$current',
            title: 'Shift Swap ${_capitalize(current)}',
            body: 'Your shift swap request was $current.',
            target: _HomeNotificationTarget.shiftEmployee,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    await prefs.setString(
      _notifKey('employee_leave_status_map'),
      jsonEncode(currentLeaveMap),
    );
    await prefs.setString(
      _notifKey('employee_swap_status_map'),
      jsonEncode(currentSwapMap),
    );
  }

  String _capitalize(String input) {
    if (input.isEmpty) return input;
    return input[0].toUpperCase() + input.substring(1).toLowerCase();
  }

  Future<void> handleAttendance() async {
    if (_isSubmitting) return;

    final canAct = isCheckedIn ? _canClockOut : _canClockIn;
    if (!canAct) {
      _showTopMessage(
        'You do not have permission to ${isCheckedIn ? 'clock out' : 'clock in'}.',
        success: false,
      );
      return;
    }

    if (mounted) setState(() => _isSubmitting = true);

    _token ??= await AuthService.getToken();
    if (_token == null || _token!.isEmpty) {
      if (mounted) {
        _showTopMessage('Session expired. Please login again.', success: false);
        setState(() => _isSubmitting = false);
      }
      return;
    }

    if ((shiftId ?? '').isEmpty) {
      final userInfo = await AuthService.getUserInfo();
      final storedUserId = userInfo['userId'];
      if (storedUserId != null && storedUserId.isNotEmpty) {
        final sid = await AttendanceService.getEmployeeShiftId(
          _token!,
          storedUserId,
        );
        if (sid != null && sid.isNotEmpty && mounted) {
          setState(() => shiftId = sid);
        }
      }
    }

    final String currentShiftId = shiftId ?? '';
    if (currentShiftId.isEmpty) {
      if (mounted) {
        _showTopMessage(
          'No shift assigned. Please contact HR or try again.',
          success: false,
        );
        setState(() => _isSubmitting = false);
      }
      return;
    }

    final result = !isCheckedIn
        ? await AttendanceService.clockIn(_token!, currentShiftId)
        : await AttendanceService.clockOut(_token!, currentShiftId);

    if (!mounted) return;

    if (result.success) {
      await loadTodayAttendance();
      await _loadWeeklyAttendance();
    }

    if (!mounted) return;
    _showTopMessage(result.message, success: result.success);
    setState(() => _isSubmitting = false);
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  /// Completed sessions + live current session (updates every second via timer).
  Duration get _liveHoursToday {
    if (isCheckedIn && _activeSessionStart != null) {
      return _totalWorkedToday + _currentTime.difference(_activeSessionStart!);
    }
    return _totalWorkedToday;
  }

  /// Shows a floating card at the top of the screen — green for success, red for error.
  void _showTopMessage(String message, {bool success = true}) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final toastWidth = screenWidth > 440 ? 360.0 : (screenWidth - 24);
        return Positioned(
          top: MediaQuery.of(ctx).padding.top + 12,
          right: 12,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: toastWidth,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: success
                    ? const Color(0xFF1A8C5B)
                    : const Color(0xFFB03A2E),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 16,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    success ? Icons.check_circle_rounded : Icons.error_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () {
      if (entry.mounted) entry.remove();
    });
  }

  Future<void> _checkFirstLoginNotification() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final lastDate = prefs.getString('last_welcome_date') ?? '';
    if (lastDate != today) {
      await prefs.setString('last_welcome_date', today);
      final info = await AuthService.getUserInfo();
      final name = ('${info['firstName'] ?? ''} ${info['lastName'] ?? ''}')
          .trim();
      if (mounted) {
        setState(() {
          _hasUnreadNotification = true;
          _welcomeNotificationName = name.isNotEmpty ? name : 'there';
        });
        _addActivityNotification(
          _HomeNotificationItem(
            id: 'welcome_$today',
            title: 'Welcome Back',
            body: 'Good to see you, ${name.isNotEmpty ? name : 'there'}!',
            target: _HomeNotificationTarget.none,
            createdAt: DateTime.now(),
          ),
        );
      }
    }
  }

  void _handleNotificationTap(_HomeNotificationItem item) {
    Navigator.pop(context);
    switch (item.target) {
      case _HomeNotificationTarget.leaveManager:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const LeaveScreen(showBackButton: true, initialSegmentIndex: 1),
          ),
        ).then((_) => _loadPendingApprovals());
        break;
      case _HomeNotificationTarget.leaveEmployee:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const LeaveScreen(showBackButton: true, initialSegmentIndex: 0),
          ),
        ).then((_) => _loadPendingApprovals());
        break;
      case _HomeNotificationTarget.shiftManager:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const ShiftSwapScreen(
              showBackButton: true,
              initialSegmentIndex: 1,
            ),
          ),
        ).then((_) => _loadPendingApprovals());
        break;
      case _HomeNotificationTarget.shiftEmployee:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const ShiftSwapScreen(
              showBackButton: true,
              initialSegmentIndex: 0,
            ),
          ),
        ).then((_) => _loadPendingApprovals());
        break;
      case _HomeNotificationTarget.none:
        break;
    }
  }

  void _showNotificationPanel() {
    setState(() => _hasUnreadNotification = false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCE8FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.notifications_active_rounded,
                    color: Color(0xFF2563EB),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Notifications',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Icon(
                    Icons.close_rounded,
                    color: Colors.grey.shade400,
                    size: 22,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF3B7DED), Color(0xFF1D4FD7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('👋', style: TextStyle(fontSize: 30)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome back, $_welcomeNotificationName!',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Wishing you a productive and fulfilling day ahead. Stay focused and make it count!',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            DateFormat(
                              'EEEE, d MMMM yyyy',
                            ).format(DateTime.now()),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (_activityNotifications.isEmpty)
              Center(
                child: Text(
                  "You're all caught up!",
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
              )
            else
              ..._activityNotifications.take(8).map((item) {
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: InkWell(
                    onTap: () => _handleNotificationTap(item),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFD),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE4EBF5)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5EEFF),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.campaign_outlined,
                              size: 18,
                              color: Color(0xFF2563EB),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  style: const TextStyle(
                                    color: Color(0xFF0B132B),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.body,
                                  style: const TextStyle(
                                    color: Color(0xFF5D738E),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: Color(0xFF97A8BE),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  String _getGreeting() {
    final hour = _currentTime.hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _formatHoursWorked(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final formattedDate = DateFormat('EEEE, d MMMM yyyy').format(_currentTime);
    final employeeName = '$_firstName $_lastName'.trim().isEmpty
        ? 'Employee'
        : '$_firstName $_lastName'.trim();

    final bool isPresentToday = checkInTime != null;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(employeeName, formattedDate, isPresentToday),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    _buildQuickActions(),
                    const SizedBox(height: 20),
                    _buildTodayAtGlance(),
                    const SizedBox(height: 20),
                    _buildThisWeek(),
                    const SizedBox(height: 20),
                    _buildPendingApprovals(),
                    const SizedBox(height: 20),
                    _buildAnnouncements(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── HEADER ──
  Widget _buildHeader(String name, String date, bool isPresent) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B7DED), Color(0xFF2563EB), Color(0xFF1D4FD7)],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: logo, notification, avatar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: Text(
                        'B',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _showNotificationPanel,
                        child: Stack(
                          children: [
                            const Icon(
                              Icons.notifications_outlined,
                              color: Colors.white,
                              size: 26,
                            ),
                            if (_hasUnreadNotification)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ProfileScreen(),
                            ),
                          ).then((_) async {
                            await _loadAnnouncementFromStorage();
                            await _loadUserInfo();
                          });
                        },
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Colors.white24,
                          backgroundImage: _profileImageUrl.trim().isNotEmpty
                              ? NetworkImage(_profileImageUrl)
                              : null,
                          child: _profileImageUrl.trim().isEmpty
                              ? Text(
                                  _getInitials(name),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Greeting
              Text(
                '${_getGreeting()} 🌅',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                date,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              // Status chips
              Row(
                children: [
                  Expanded(
                    child: _buildChip(
                      '⏰ ${checkInTime != null ? DateFormat('hh:mm a').format(checkInTime!) : '--:--'} In',
                      Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildChip(
                      isPresent ? '✅ Present Today' : '❌ Absent Today',
                      Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Widget _buildChip(String label, Color bgColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ── QUICK ACTIONS ──
  Widget _buildQuickActions() {
    if (!_quickActionsResolved) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final canClock = isCheckedIn ? _canClockOut : _canClockIn;
    final cards = <Widget>[];

    if (canClock) {
      cards.add(
        _buildActionCard(
          icon: Icons.access_time_filled,
          label: _isSubmitting
              ? 'Processing...'
              : (isCheckedIn ? 'Clock Out' : 'Clock In'),
          subtitle: _isSubmitting
              ? 'Please wait'
              : (isCheckedIn ? 'Tap to check out' : 'Tap to check in'),
          color: const Color(0xFFDCE8FF),
          iconColor: const Color(0xFF2563EB),
          onTap: _isSubmitting ? null : handleAttendance,
        ),
      );
    }

    if (_canApplyLeave) {
      cards.add(
        _buildActionCard(
          icon: Icons.calendar_today,
          label: 'Apply Leave',
          subtitle: 'Request time off',
          color: const Color(0xFFD5F5E3),
          iconColor: const Color(0xFF27AE60),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LeaveScreen(
                  openApplySheetOnLoad: true,
                  showBackButton: true,
                ),
              ),
            ).then((_) => _loadPendingApprovals());
          },
        ),
      );
    }

    if (_canViewPayslip) {
      cards.add(
        _buildActionCard(
          icon: Icons.receipt_long,
          label: 'Payslip',
          subtitle: 'View salary slip',
          color: const Color(0xFFFFF3CD),
          iconColor: const Color(0xFFF39C12),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PayrollScreen()),
            );
          },
        ),
      );
    }

    if (_canCreateShiftSwap) {
      cards.add(
        _buildActionCard(
          icon: Icons.swap_horiz,
          label: 'Shift Swap',
          subtitle: 'Create request',
          color: const Color(0xFFF0E0FF),
          iconColor: const Color(0xFF8E44AD),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ShiftSwapScreen(
                  openCreateSheetOnLoad: true,
                  showBackButton: true,
                ),
              ),
            ).then((_) => _loadPendingApprovals());
          },
        ),
      );
    }

    if (_canViewMyAttendanceSummary) {
      cards.add(
        _buildActionCard(
          icon: Icons.assignment_outlined,
          label: 'My Attendance',
          subtitle: 'View full records',
          color: const Color(0xFFE0F7FA),
          iconColor: const Color(0xFF00838F),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AttendanceScreen()),
          ).then((_) {
            loadTodayAttendance();
            _loadWeeklyAttendance();
          }),
        ),
      );
    }

    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }

    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final left = cards[i];
      final right = i + 1 < cards.length ? cards[i + 1] : null;
      rows.add(
        Row(
          children: [
            Expanded(child: left),
            const SizedBox(width: 12),
            Expanded(child: right ?? const SizedBox.shrink()),
          ],
        ),
      );
      if (i + 2 < cards.length) {
        rows.add(const SizedBox(height: 12));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...rows,
      ],
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required Color iconColor,
    required VoidCallback? onTap,
  }) {
    return Opacity(
      opacity: onTap == null ? 0.75 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── TODAY AT A GLANCE ──
  Widget _buildTodayAtGlance() {
    final inTime = checkInTime != null
        ? DateFormat('hh:mm a').format(checkInTime!)
        : '--:--';
    final outTime = checkOutTime != null
        ? DateFormat('hh:mm a').format(checkOutTime!)
        : '--:--';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Today at a Glance',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(child: _buildGlanceItem('IN', inTime)),
              Container(width: 1, height: 40, color: Colors.grey.shade300),
              Expanded(child: _buildGlanceItem('OUT', outTime)),
              Container(width: 1, height: 40, color: Colors.grey.shade300),
              Expanded(
                child: _buildGlanceItem(
                  'HOURS TODAY',
                  _formatHoursWorked(_liveHoursToday),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGlanceItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ],
    );
  }

  // ── THIS WEEK ──
  Widget _buildThisWeek() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    // Mon-Sun (7 days)
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'This Week',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AttendanceHistoryScreen(),
                  ),
                );
              },
              child: const Text(
                'View All →',
                style: TextStyle(
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: days.map((day) {
            final key = DateFormat('yyyy-MM-dd').format(day);
            final isToday =
                day.day == now.day &&
                day.month == now.month &&
                day.year == now.year;
            final status = _weeklyAttendance[key];
            final isFuture = day.isAfter(
              DateTime(now.year, now.month, now.day),
            );

            Color bgColor;
            Color textColor = Colors.black87;
            if (isToday) {
              if (status == 'present' || checkInTime != null) {
                bgColor = const Color(0xFF27AE60);
              } else {
                bgColor = const Color(0xFF2563EB);
              }
              textColor = Colors.white;
            } else if (isFuture) {
              bgColor = Colors.grey.shade100;
              textColor = Colors.grey.shade400;
            } else if (status == 'present') {
              bgColor = const Color(0xFF27AE60);
              textColor = Colors.white;
            } else if (status == 'absent') {
              bgColor = const Color(0xFFE74C3C);
              textColor = Colors.white;
            } else {
              // Past day with no data
              if (day.weekday == DateTime.saturday ||
                  day.weekday == DateTime.sunday) {
                bgColor = Colors.grey.shade200;
              } else {
                bgColor = Colors.grey.shade100;
              }
            }

            return _buildDayCircle(
              DateFormat('EEE').format(day).toUpperCase(),
              day.day.toString(),
              bgColor,
              textColor,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildDayCircle(
    String dayLabel,
    String date,
    Color bgColor,
    Color textColor,
  ) {
    return Column(
      children: [
        Text(
          dayLabel,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              date,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── PENDING APPROVALS ──
  Widget _buildPendingApprovals() {
    final showLeaveRow =
        _canApproveRequests || _canApplyLeave;
    final showSwapRow =
        _canManageTeamShiftSwaps || _canCreateShiftSwap;

    if (!showLeaveRow && !showSwapRow) {
      return const SizedBox.shrink();
    }

    final leaveCount = _pendingLeaveApprovals.length;
    final swapCount = _pendingShiftSwapApprovals.length;
    final leaveTitle = _canApproveRequests
        ? 'Leave Request Pending'
        : 'My Pending Leave Requests';
    final swapTitle = _canManageTeamShiftSwaps
        ? 'Shift Swap Request Pending'
        : 'My Pending Shift Swaps';

    final items = <Widget>[];

    if (showLeaveRow) {
      items.add(
        _buildApprovalItem(
          icon: Icons.calendar_month,
          iconBg: const Color(0xFFDCE8FF),
          iconColor: const Color(0xFF2563EB),
          title: leaveTitle,
          subtitle: leaveCount == 0
              ? 'No pending leave requests'
              : '$leaveCount pending leave request${leaveCount == 1 ? '' : 's'}',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LeaveScreen(
                  showBackButton: true,
                  initialSegmentIndex: _canApproveRequests ? 1 : 0,
                ),
              ),
            ).then((_) => _loadPendingApprovals());
          },
        ),
      );
    }

    if (showLeaveRow && showSwapRow) {
      items.add(Divider(height: 1, color: Colors.grey.shade200));
    }

    if (showSwapRow) {
      items.add(
        _buildApprovalItem(
          icon: Icons.swap_horiz,
          iconBg: const Color(0xFFF0E0FF),
          iconColor: const Color(0xFF8E44AD),
          title: swapTitle,
          subtitle: swapCount == 0
              ? 'No pending shift swap requests'
              : '$swapCount pending shift swap request${swapCount == 1 ? '' : 's'}',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ShiftSwapScreen(
                  showBackButton: true,
                  initialSegmentIndex: _canManageTeamShiftSwaps ? 1 : 0,
                ),
              ),
            ).then((_) => _loadPendingApprovals());
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Pending Approvals',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(children: items),
        ),
      ],
    );
  }

  Widget _buildApprovalItem({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  // ── ANNOUNCEMENTS ──
  Widget _buildAnnouncements() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Announcements 📢',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _announcementTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _announcementBody,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _HomeNotificationTarget {
  none,
  leaveManager,
  leaveEmployee,
  shiftManager,
  shiftEmployee,
}

class _HomeNotificationItem {
  final String id;
  final String title;
  final String body;
  final _HomeNotificationTarget target;
  final DateTime createdAt;

  const _HomeNotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.target,
    required this.createdAt,
  });
}