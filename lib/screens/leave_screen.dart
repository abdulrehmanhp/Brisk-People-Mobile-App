import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/auth_service.dart';
import '../services/leave_service.dart';
import '../services/permission_service.dart';
import '../widgets/permission_gate.dart';

class LeaveScreen extends StatefulWidget {
  final bool openApplySheetOnLoad;
  final bool showBackButton;
  final int initialSegmentIndex;

  const LeaveScreen({
    super.key,
    this.openApplySheetOnLoad = false,
    this.showBackButton = false,
    this.initialSegmentIndex = 0,
  });

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  bool _isLoading = true;
  bool _hasAutoOpenedApplySheet = false;
  bool _isApplySheetOpen = false;
  String? _token;
  String? _userId;
  bool _canApplyLeave = false;
  bool _canCancelLeave = false;
  bool _canViewMyLeaves = false;
  bool _canViewTeamRequests = false;
  bool _canApproveTeam = false;
  bool _canRejectTeam = false;
  bool _permissionsResolved = false;

  int _segmentIndex = 0; // 0 My Requests, 1 Team Requests, 2 Calendar
  int _historyFilter = 0; // 0 all, 1 this month, 2 last 3 months
  DateTime _monthFocus = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _selectedDate = DateTime.now();

  final TextEditingController _searchController = TextEditingController();

  List<LeaveTypeItem> _leaveTypes = [];
  List<LeaveRequestItem> _requests = [];
  List<LeaveRequestItem> _teamRequests = [];
  final Set<String> _cancellingRequestIds = <String>{};
  final Set<String> _teamActionRequestIds = <String>{};

  @override
  void initState() {
    super.initState();
    _segmentIndex = widget.initialSegmentIndex.clamp(0, 2);
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    _token ??= await AuthService.getToken();
    if ((_userId ?? '').isEmpty) {
      final userInfo = await AuthService.getUserInfo();
      _userId = (userInfo['userId'] ?? '').trim();
    }

    await _loadPermissionFlags();

    if (_token == null || _token!.isEmpty) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('Session expired. Please login again.', isError: true);
      }
      return;
    }

    final futures = <Future<dynamic>>[
      LeaveService.getLeaveTypesForRequest(_token!),
      LeaveService.getMyLeaveRequests(_token!, currentEmployeeId: _userId),
    ];
    if (_canViewTeamRequests) {
      futures.add(
        LeaveService.getTeamLeaveRequests(_token!, currentEmployeeId: _userId),
      );
    }

    final results = await Future.wait<dynamic>(futures);
    final types = results[0] as List<LeaveTypeItem>;
    final history = results[1] as List<LeaveRequestItem>;
    final teamHistory = _canViewTeamRequests
        ? (results[2] as List<LeaveRequestItem>)
        : <LeaveRequestItem>[];

    history.sort((a, b) {
      final ad = a.submittedAt ?? a.startDate ?? DateTime(1970);
      final bd = b.submittedAt ?? b.startDate ?? DateTime(1970);
      return bd.compareTo(ad);
    });
    teamHistory.sort((a, b) {
      final ad = a.submittedAt ?? a.startDate ?? DateTime(1970);
      final bd = b.submittedAt ?? b.startDate ?? DateTime(1970);
      return bd.compareTo(ad);
    });

    if (!mounted) return;
    setState(() {
      _leaveTypes = types;
      _requests = history;
      _teamRequests = teamHistory;
      _isLoading = false;
    });

    // Open apply sheet only after leave types are available.
    if (widget.openApplySheetOnLoad &&
        !_hasAutoOpenedApplySheet &&
        _leaveTypes.isNotEmpty &&
        _canApplyLeave) {
      _hasAutoOpenedApplySheet = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openApplyLeaveSheet();
      });
    }
  }

  Future<void> _loadPermissionFlags() async {
    final results = await Future.wait([
      PermissionService.hasPermissionByActionKey(
        PermissionKeys.myLeaveRequestLeave,
      ),
      PermissionService.hasPermissionByActionKey(
        PermissionKeys.myLeaveCancelRequest,
      ),
      PermissionService.hasSubMenuPermission(
        'Leave Management',
        'My Leaves',
      ),
      PermissionService.hasSubMenuPermission(
        'Leave Management',
        'Team Requests',
        aliases: const ['Team Leaves'],
      ),
      PermissionService.hasPermissionByActionKey(PermissionKeys.teamLeaveApprove),
      PermissionService.hasPermissionByActionKey(PermissionKeys.teamLeaveReject),
    ]);

    if (!mounted) return;
    setState(() {
      _canApplyLeave = results[0];
      _canCancelLeave = results[1];
      _canViewMyLeaves = results[2] || results[0];
      _canViewTeamRequests = results[3] || results[4] || results[5];
      _canApproveTeam = results[4];
      _canRejectTeam = results[5];
      _permissionsResolved = true;
      if (!_canViewTeamRequests && _segmentIndex == 1) {
        _segmentIndex = 0;
      }
    });
  }

  List<LeaveRequestItem> get _filteredRequests {
    final q = _searchController.text.trim().toLowerCase();
    final now = DateTime.now();

    final filteredByTime = _requests.where((r) {
      final s = r.startDate;
      if (s == null) return _historyFilter == 0;
      if (_historyFilter == 1) {
        return s.year == now.year && s.month == now.month;
      }
      if (_historyFilter == 2) {
        final threshold = DateTime(now.year, now.month - 2, 1);
        return s.isAfter(threshold.subtract(const Duration(days: 1)));
      }
      return true;
    });

    if (q.isEmpty) return filteredByTime.toList();
    return filteredByTime.where((r) {
      final hay = [
        r.typeName,
        r.reason,
        r.status,
        DateFormat('dd MMM yyyy').format(r.startDate ?? DateTime(1970)),
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  int get _approvedCount => _filteredRequests.where((e) => e.isApproved).length;

  double get _approvedDaysTaken {
    var total = 0.0;
    for (final r in _filteredRequests.where((e) => e.isApproved)) {
      final days = r.daysRequested > 0
          ? r.daysRequested
          : r.computedDurationDays.toDouble();
      if (days > 0) total += days;
    }
    return total;
  }

  int _remainingDaysForType(LeaveTypeItem type) {
    var used = 0.0;
    for (final r in _requests.where(
      (e) =>
          e.leaveTypeId == type.leaveTypeId &&
          e.consumesBalance &&
          (e.startDate?.year == DateTime.now().year),
    )) {
      final d = r.daysRequested > 0
          ? r.daysRequested
          : r.computedDurationDays.toDouble();
      if (d > 0) used += d;
    }
    final remain = type.maxDaysPerYear - used;
    return remain < 0 ? 0 : remain.floor();
  }

  Color _typeColor(LeaveTypeItem type) {
    return Color(type.parsedColor.value);
  }

  Future<void> _openApplyLeaveSheet() async {
    if (!_canApplyLeave) {
      _showMessage('You do not have permission to apply for leave.', isError: true);
      return;
    }
    if (_isApplySheetOpen) return;
    _isApplySheetOpen = true;

    TextEditingController? reasonController;

    // Wrap in try/finally so the flag resets even on early dismiss.
    try {
      if (_leaveTypes.isEmpty) {
        _showMessage('No active leave types available.', isError: true);
        return;
      }

      final leaveTypeOptions = _leaveTypes
          .where((e) => e.leaveTypeId.trim().isNotEmpty)
          .fold<List<LeaveTypeItem>>(<LeaveTypeItem>[], (acc, item) {
            if (acc.any((e) => e.leaveTypeId == item.leaveTypeId)) {
              return acc;
            }
            acc.add(item);
            return acc;
          });

      if (leaveTypeOptions.isEmpty) {
        _showMessage('No valid leave types available.', isError: true);
        return;
      }

      LeaveTypeItem selectedType = leaveTypeOptions.first;
      DateTime fromDate = DateTime.now();
      DateTime toDate = DateTime.now().add(const Duration(days: 1));
      bool isSheetSubmitting = false;
      reasonController = TextEditingController();

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              final duration = toDate.difference(fromDate).inDays + 1;
              return Padding(
                padding: EdgeInsets.only(
                  left: 18,
                  right: 18,
                  top: 12,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 22,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 56,
                          height: 7,
                          decoration: BoxDecoration(
                            color: const Color(0xFFD6DCE6),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Apply for Leave',
                        style: TextStyle(
                          fontSize: 38 / 2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Leave Type',
                        style: TextStyle(
                          color: Colors.blueGrey.shade700,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFD4DDE9)),
                        ),
                        child: DropdownButtonFormField<String>(
                          initialValue: selectedType.leaveTypeId,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          items: leaveTypeOptions
                              .map(
                                (e) => DropdownMenuItem<String>(
                                  value: e.leaveTypeId,
                                  child: Text(_titleCase(e.typeName)),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            final found = leaveTypeOptions.firstWhere(
                              (e) => e.leaveTypeId == value,
                            );
                            setSheetState(() => selectedType = found);
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _dateField(
                              context: ctx,
                              label: 'From',
                              date: fromDate,
                              onPick: () async {
                                final picked = await showDatePicker(
                                  context: ctx,
                                  initialDate: fromDate,
                                  firstDate: DateTime.now().subtract(
                                    const Duration(days: 365),
                                  ),
                                  lastDate: DateTime.now().add(
                                    const Duration(days: 365 * 3),
                                  ),
                                );
                                if (picked == null) return;
                                setSheetState(() {
                                  fromDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                  );
                                  if (toDate.isBefore(fromDate)) {
                                    toDate = fromDate;
                                  }
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _dateField(
                              context: ctx,
                              label: 'To',
                              date: toDate,
                              onPick: () async {
                                final picked = await showDatePicker(
                                  context: ctx,
                                  initialDate: toDate.isBefore(fromDate)
                                      ? fromDate
                                      : toDate,
                                  firstDate: fromDate,
                                  lastDate: DateTime.now().add(
                                    const Duration(days: 365 * 3),
                                  ),
                                );
                                if (picked == null) return;
                                setSheetState(() {
                                  toDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                  );
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text(
                            'Duration',
                            style: TextStyle(
                              color: Colors.blueGrey.shade700,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5EEFF),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '$duration day${duration > 1 ? 's' : ''}',
                              style: const TextStyle(
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Reason',
                        style: TextStyle(
                          color: Colors.blueGrey.shade700,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reasonController,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Tell us why...',
                          filled: true,
                          fillColor: const Color(0xFFF1F4F8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFD4DDE9),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFD4DDE9),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: isSheetSubmitting
                              ? null
                              : () async {
                                  if (isSheetSubmitting) return;
                                  if (_token == null || _token!.isEmpty) {
                                    _showMessage(
                                      'Session expired. Please login again.',
                                      isError: true,
                                    );
                                    return;
                                  }

                                  if (toDate.isBefore(fromDate)) {
                                    _showMessage(
                                      'End date cannot be before start date.',
                                      isError: true,
                                    );
                                    return;
                                  }

                                  setSheetState(() => isSheetSubmitting = true);

                                  final payload = LeaveApplyPayload(
                                    leaveTypeId: selectedType.leaveTypeId,
                                    startDate: fromDate,
                                    endDate: toDate,
                                    reason: reasonController?.text.trim() ?? '',
                                  );

                                  final submitResult =
                                      await LeaveService.createLeaveRequest(
                                        token: _token!,
                                        payload: payload,
                                      );

                                  if (!mounted || !ctx.mounted) return;

                                  if (!submitResult.success) {
                                    setSheetState(
                                      () => isSheetSubmitting = false,
                                    );
                                    _showMessage(
                                      submitResult.message,
                                      isError: true,
                                    );
                                    return;
                                  }

                                  if (ctx.mounted) {
                                    Navigator.of(ctx).pop();
                                  }
                                  _showMessage(submitResult.message);
                                  await _loadData();
                                },
                          child: isSheetSubmitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Submit Request',
                                  style: TextStyle(
                                    fontSize: 18 / 1.4,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      reasonController?.dispose();
      _isApplySheetOpen = false;
    }
  }

  Widget _dateField({
    required BuildContext context,
    required String label,
    required DateTime date,
    required VoidCallback onPick,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.blueGrey.shade700,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F4F8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD4DDE9)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat('MMM d, yyyy').format(date),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                Icon(
                  Icons.calendar_month_outlined,
                  color: Colors.blueGrey.shade400,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showMessage(String msg, {bool isError = false}) {
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isError
                    ? const Color(0xFFB03A2E)
                    : const Color(0xFF1A8C5B),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    isError ? Icons.error_rounded : Icons.check_circle_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      msg,
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

  @override
  Widget build(BuildContext context) {
    if (!_permissionsResolved) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final hasAnyLeaveAccess =
        _canApplyLeave || _canViewTeamRequests || _canViewMyLeaves;
    if (!hasAnyLeaveAccess) {
      return const PermissionDeniedScaffold(featureName: 'Leave Management');
    }

    final isCalendar = _segmentIndex == _calendarSegmentIndex;
    final isTeam = _canViewTeamRequests && _segmentIndex == 1;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: widget.showBackButton || Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Color(0xFF0B132B)),
                onPressed: () => Navigator.maybePop(context),
              )
            : null,
        title: Text(
          isCalendar
              ? 'Leave Calendar'
              : (isTeam ? 'Team Requests' : 'Leave History'),
          style: const TextStyle(
            color: Color(0xFF0B132B),
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_canApplyLeave)
            IconButton(
              onPressed: _openApplyLeaveSheet,
              icon: Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                  color: Color(0xFFE6ECF7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, color: Color(0xFF2563EB), size: 28),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTypePills(),
                    const SizedBox(height: 14),
                    _buildTopSegment(),
                    const SizedBox(height: 16),
                    if (_segmentIndex == 0) _buildMyRequestsTab(),
                    if (isTeam) _buildTeamRequestsTab(),
                    if (isCalendar) _buildCalendarTab(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildTypePills() {
    if (_leaveTypes.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFCED8E9)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: _leaveTypes.take(6).map((type) {
          final color = _typeColor(type);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.badge_outlined, color: color, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${_titleCase(type.typeName)} (${_remainingDaysForType(type)})',
                  style: TextStyle(
                    color: const Color(0xFF36455F),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTopSegment() {
    final labels = <String>['My Requests'];
    if (_canViewTeamRequests) labels.add('Team Requests');
    labels.add('Calendar');

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFFDCE2EC),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: List.generate(labels.length, (i) {
          final selected = _segmentIndex == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _segmentIndex = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF2563EB)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF5B6B84),
                    fontWeight: FontWeight.w700,
                    fontSize: labels.length > 2 ? 13 : 15,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  int get _calendarSegmentIndex => _canViewTeamRequests ? 2 : 1;

  Widget _buildMyRequestsTab() {
    final grouped = <String, List<LeaveRequestItem>>{};
    for (final r in _filteredRequests) {
      final keyDate = r.startDate ?? r.submittedAt ?? DateTime.now();
      final key = DateFormat('MMMM yyyy').format(keyDate).toUpperCase();
      grouped.putIfAbsent(key, () => []).add(r);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2563EB), Color(0xFF6FA6F5)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Plan your time off',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Apply for leave easily through the portal',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 14),
              if (_canApplyLeave)
                ElevatedButton(
                  onPressed: _openApplyLeaveSheet,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Apply',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _buildHistoryFilters(),
        const SizedBox(height: 12),
        _buildStatsRow(),
        const SizedBox(height: 14),
        if (grouped.isEmpty)
          _buildEmptyState('No leave history found.')
        else
          ...grouped.entries.map((entry) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: Color(0xFF8EA0B9),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Divider(color: Color(0xFFDAE2EF), thickness: 1),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...entry.value.map(_buildHistoryCard),
                const SizedBox(height: 10),
              ],
            );
          }),
      ],
    );
  }

  Widget _buildHistoryFilters() {
    final labels = ['All Time', 'This Month', 'Last 3 Months'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(labels.length, (i) {
              final selected = i == _historyFilter;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => setState(() => _historyFilter = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF2563EB)
                          : const Color(0xFFDCE3EE),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : const Color(0xFF253754),
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search history...',
            filled: true,
            fillColor: Colors.white,
            prefixIcon: const Icon(Icons.search, color: Color(0xFF8AA0BC)),
            suffixIcon: const Icon(Icons.tune, color: Color(0xFF2563EB)),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFD5DEEA)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFD5DEEA)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(
          child: _statCard(
            'Total Requests',
            _filteredRequests.length.toString(),
            const Color(0xFF0B132B),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statCard(
            'Approved',
            _approvedCount.toString(),
            const Color(0xFF2563EB),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statCard(
            'Days Taken',
            _approvedDaysTaken.toStringAsFixed(
              _approvedDaysTaken % 1 == 0 ? 0 : 1,
            ),
            const Color(0xFF0B132B),
          ),
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E8F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF627690), fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 24 / 1.2,
              fontWeight: FontWeight.w700,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(LeaveRequestItem item) {
    final statusLower = item.status.toLowerCase();
    final statusColor = statusLower == 'approved'
        ? const Color(0xFF1AA865)
        : statusLower == 'pending'
        ? const Color(0xFFCC7A00)
        : const Color(0xFFE03D52);

    final typeColor = _leaveTypes
        .where((e) => e.leaveTypeId == item.leaveTypeId)
        .map(_typeColor)
        .fold<Color>(const Color(0xFF9FB3CF), (_, c) => c);
    final canCancel = item.isPending && _canCancelLeave;
    final isCancelling = _cancellingRequestIds.contains(item.requestId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDFE7F1)),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 70,
                child: Column(
                  children: [
                    Text(
                      item.startDate != null
                          ? DateFormat('dd').format(item.startDate!)
                          : '--',
                      style: const TextStyle(
                        fontSize: 40 / 1.6,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      item.startDate != null
                          ? DateFormat(
                              'MMM yy',
                            ).format(item.startDate!).toUpperCase()
                          : '--',
                      style: const TextStyle(
                        color: Color(0xFF6F84A0),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 72, color: const Color(0xFFE3EAF4)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${_titleCase(item.typeName)} LEAVE',
                            style: TextStyle(
                              color: typeColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_statusIcon(statusLower)} ${_titleCase(item.status)}',
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _rangeText(item),
                      style: const TextStyle(
                        fontSize: 18 / 1.2,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0B132B),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Duration: ${item.computedDurationDays} day${item.computedDurationDays > 1 ? 's' : ''}',
                      style: const TextStyle(
                        color: Color(0xFF5D738E),
                        fontSize: 17 / 1.2,
                      ),
                    ),
                    if (item.reason.trim().isNotEmpty)
                      Text(
                        '"${item.reason}"',
                        style: const TextStyle(
                          color: Color(0xFF5D738E),
                          fontSize: 17 / 1.2,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Color(0xFFE3EAF4)),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                'Applied: ${item.submittedAt != null ? DateFormat('dd MMM yyyy').format(item.submittedAt!) : '--'}',
                style: const TextStyle(
                  color: Color(0xFF8A9BB2),
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              if (canCancel)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: InkWell(
                    onTap: isCancelling
                        ? null
                        : () => _confirmAndCancelLeave(item),
                    borderRadius: BorderRadius.circular(999),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFF87171), Color(0xFFE11D48)],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33E11D48),
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: isCancelling
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.cancel_outlined,
                                  color: Colors.white,
                                  size: 15,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'Cancel',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              InkWell(
                onTap: () => _showLeaveDetail(item),
                child: const Row(
                  children: [
                    Text(
                      'View Details',
                      style: TextStyle(
                        color: Color(0xFF2563EB),
                        fontWeight: FontWeight.w700,
                        fontSize: 16 / 1.2,
                      ),
                    ),
                    SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right,
                      color: Color(0xFF2563EB),
                      size: 20,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusIcon(String status) {
    if (status == 'approved') return '●';
    if (status == 'pending') return '◔';
    return '●';
  }

  String _rangeText(LeaveRequestItem item) {
    if (item.startDate == null) return '--';
    if (item.endDate == null || item.endDate == item.startDate) {
      return DateFormat('dd MMM').format(item.startDate!);
    }
    return '${DateFormat('dd MMM').format(item.startDate!)} - ${DateFormat('dd MMM').format(item.endDate!)}';
  }

  void _showLeaveDetail(LeaveRequestItem item) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) {
        final canCancel = item.isPending && _canCancelLeave;
        final isCancelling = _cancellingRequestIds.contains(item.requestId);
        final rows = [
          ['Request ID', item.requestId],
          ['Leave Type', _titleCase(item.typeName)],
          ['Status', _titleCase(item.status)],
          [
            'Start Date',
            item.startDate != null
                ? DateFormat('dd MMM yyyy').format(item.startDate!)
                : '--',
          ],
          [
            'End Date',
            item.endDate != null
                ? DateFormat('dd MMM yyyy').format(item.endDate!)
                : '--',
          ],
          ['Days Requested', item.computedDurationDays.toString()],
          [
            'Submitted At',
            item.submittedAt != null
                ? DateFormat('dd MMM yyyy, hh:mm a').format(item.submittedAt!)
                : '--',
          ],
          [
            'Approved At',
            item.approvedAt != null
                ? DateFormat('dd MMM yyyy, hh:mm a').format(item.approvedAt!)
                : '--',
          ],
          ['Reason', item.reason.trim().isEmpty ? '--' : item.reason],
          [
            'Rejection Reason',
            item.rejectionReason?.trim().isNotEmpty == true
                ? item.rejectionReason!
                : '--',
          ],
        ];

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 58,
                    height: 7,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD6DCE6),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Leave Request Details',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 14),
                ...rows.map((r) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 130,
                          child: Text(
                            r[0],
                            style: const TextStyle(
                              color: Color(0xFF647994),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r[1],
                            style: const TextStyle(
                              color: Color(0xFF0B132B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (canCancel) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: isCancelling
                          ? null
                          : () {
                              Navigator.of(ctx).pop();
                              _confirmAndCancelLeave(item);
                            },
                      icon: isCancelling
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.cancel_outlined),
                      label: Text(
                        isCancelling
                            ? 'Cancelling...'
                            : 'Cancel This Leave Request',
                      ),
                      style: ElevatedButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0xFFE11D48),
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmAndCancelLeave(LeaveRequestItem item) async {
    if (!item.isPending) {
      _showMessage('Only pending requests can be cancelled.', isError: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Cancel Leave Request?'),
          content: Text(
            'This will withdraw your request for ${_titleCase(item.typeName)} (${_rangeText(item)}). You can submit a new request later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No, Keep It'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE11D48),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Yes, Cancel'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    if (_token == null || _token!.isEmpty) {
      _showMessage('Session expired. Please login again.', isError: true);
      return;
    }

    if (mounted) {
      setState(() => _cancellingRequestIds.add(item.requestId));
    }

    final result = await LeaveService.cancelLeaveRequest(
      token: _token!,
      requestId: item.requestId,
    );

    if (!mounted) return;
    setState(() => _cancellingRequestIds.remove(item.requestId));

    _showMessage(result.message, isError: !result.success);
    if (result.success) {
      await _loadData();
    }
  }

  List<LeaveRequestItem> get _filteredTeamRequests {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _teamRequests;
    return _teamRequests.where((r) {
      final hay = [
        r.employeeName,
        r.typeName,
        r.reason,
        r.status,
        DateFormat('dd MMM yyyy').format(r.startDate ?? DateTime(1970)),
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Widget _buildTeamRequestsTab() {
    if (!_canViewTeamRequests) {
      return _buildEmptyState(
        'You do not have permission to view team leave requests.',
      );
    }

    final items = _filteredTeamRequests;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0F766E), Color(0xFF14B8A6)],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pending Team Requests',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Review and take action on ${items.length} pending request${items.length == 1 ? '' : 's'}.',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _buildHistoryFilters(),
        const SizedBox(height: 12),
        if (items.isEmpty)
          _buildEmptyState('No pending team requests found.')
        else
          ...items.map(_buildTeamRequestCard),
      ],
    );
  }

  Widget _buildTeamRequestCard(LeaveRequestItem item) {
    final isActing = _teamActionRequestIds.contains(item.requestId);
    final requesterName = item.employeeName.trim().isEmpty
        ? item.employeeId
        : item.employeeName.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDFE7F1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2FE),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.person_outline,
                  color: Color(0xFF0369A1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      requesterName,
                      style: const TextStyle(
                        color: Color(0xFF0B132B),
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      '${_titleCase(item.typeName)} · ${_rangeText(item)}',
                      style: const TextStyle(
                        color: Color(0xFF5D738E),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Pending',
                  style: TextStyle(
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (item.reason.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '"${item.reason.trim()}"',
              style: const TextStyle(
                color: Color(0xFF5D738E),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (_canRejectTeam || _canApproveTeam)
            Row(
              children: [
                if (_canRejectTeam)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isActing
                          ? null
                          : () => _confirmRejectTeamRequest(item),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Reject'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFB42318),
                        side: const BorderSide(color: Color(0xFFFCA5A5)),
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
                if (_canRejectTeam && _canApproveTeam)
                  const SizedBox(width: 10),
                if (_canApproveTeam)
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isActing
                          ? null
                          : () => _confirmApproveTeamRequest(item),
                      icon: isActing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(isActing ? 'Processing...' : 'Approve'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _confirmApproveTeamRequest(LeaveRequestItem item) async {
    if (!_canApproveTeam) {
      _showMessage('You do not have permission to approve leave requests.', isError: true);
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve Request?'),
        content: Text(
          'Approve ${_titleCase(item.typeName)} leave for ${item.employeeName.trim().isEmpty ? item.employeeId : item.employeeName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (yes != true) return;
    if (_token == null || _token!.isEmpty) {
      _showMessage('Session expired. Please login again.', isError: true);
      return;
    }

    setState(() => _teamActionRequestIds.add(item.requestId));
    final result = await LeaveService.approveLeaveRequest(
      token: _token!,
      requestId: item.requestId,
    );
    if (!mounted) return;
    setState(() => _teamActionRequestIds.remove(item.requestId));
    _showMessage(result.message, isError: !result.success);
    if (result.success) await _loadData();
  }

  Future<void> _confirmRejectTeamRequest(LeaveRequestItem item) async {
    if (!_canRejectTeam) {
      _showMessage('You do not have permission to reject leave requests.', isError: true);
      return;
    }
    final reasonController = TextEditingController();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Request?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Reject ${_titleCase(item.typeName)} leave for ${item.employeeName.trim().isEmpty ? item.employeeId : item.employeeName}?',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (yes != true) {
      reasonController.dispose();
      return;
    }

    if (_token == null || _token!.isEmpty) {
      reasonController.dispose();
      _showMessage('Session expired. Please login again.', isError: true);
      return;
    }

    setState(() => _teamActionRequestIds.add(item.requestId));
    final result = await LeaveService.rejectLeaveRequest(
      token: _token!,
      requestId: item.requestId,
      reason: reasonController.text,
    );
    reasonController.dispose();

    if (!mounted) return;
    setState(() => _teamActionRequestIds.remove(item.requestId));
    _showMessage(result.message, isError: !result.success);
    if (result.success) await _loadData();
  }

  Widget _buildCalendarTab() {
    final monthStart = DateTime(_monthFocus.year, _monthFocus.month, 1);
    final monthEnd = DateTime(_monthFocus.year, _monthFocus.month + 1, 0);
    final firstWeekday = monthStart.weekday % 7; // sunday = 0
    final totalDays = monthEnd.day;

    final cells = <DateTime?>[];
    for (var i = 0; i < firstWeekday; i++) {
      cells.add(null);
    }
    for (var d = 1; d <= totalDays; d++) {
      cells.add(DateTime(_monthFocus.year, _monthFocus.month, d));
    }

    final selectedItems = _requests.where((r) {
      final s = r.startDate;
      final e = r.endDate;
      if (s == null || e == null) return false;
      final target = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );
      final ss = DateTime(s.year, s.month, s.day);
      final ee = DateTime(e.year, e.month, e.day);
      return !target.isBefore(ss) && !target.isAfter(ee);
    }).toList();

    final upcoming =
        _requests.where((r) {
          final s = r.startDate;
          if (s == null) return false;
          return !s.isBefore(DateTime.now().subtract(const Duration(days: 1)));
        }).toList()..sort(
          (a, b) => (a.startDate ?? DateTime(1970)).compareTo(
            b.startDate ?? DateTime(1970),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() {
                _monthFocus = DateTime(
                  _monthFocus.year,
                  _monthFocus.month - 1,
                  1,
                );
              }),
              icon: const Icon(Icons.chevron_left, color: Color(0xFF2563EB)),
            ),
            Expanded(
              child: Text(
                DateFormat('MMMM yyyy').format(_monthFocus),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22 / 1.2,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0B132B),
                ),
              ),
            ),
            IconButton(
              onPressed: () => setState(() {
                _monthFocus = DateTime(
                  _monthFocus.year,
                  _monthFocus.month + 1,
                  1,
                );
              }),
              icon: const Icon(Icons.chevron_right, color: Color(0xFF2563EB)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildLegend(),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFDCE4EF)),
          ),
          child: Column(
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _WeekLabel('S'),
                  _WeekLabel('M'),
                  _WeekLabel('T'),
                  _WeekLabel('W'),
                  _WeekLabel('T'),
                  _WeekLabel('F'),
                  _WeekLabel('S'),
                ],
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: cells.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                  childAspectRatio: 1.05,
                ),
                itemBuilder: (ctx, i) {
                  final date = cells[i];
                  if (date == null) return const SizedBox.shrink();

                  final dayItems = _requests.where((r) {
                    if (r.startDate == null || r.endDate == null) return false;
                    final t = DateTime(date.year, date.month, date.day);
                    final s = DateTime(
                      r.startDate!.year,
                      r.startDate!.month,
                      r.startDate!.day,
                    );
                    final e = DateTime(
                      r.endDate!.year,
                      r.endDate!.month,
                      r.endDate!.day,
                    );
                    return !t.isBefore(s) && !t.isAfter(e);
                  }).toList();

                  final isSelected =
                      date.year == _selectedDate.year &&
                      date.month == _selectedDate.month &&
                      date.day == _selectedDate.day;
                  final isToday =
                      date.year == DateTime.now().year &&
                      date.month == DateTime.now().month &&
                      date.day == DateTime.now().day;

                  final Color markerColor = dayItems.isEmpty
                      ? Colors.transparent
                      : dayItems.any((e) => e.isApproved)
                      ? const Color(0xFF12AF7E)
                      : dayItems.any((e) => e.isPending)
                      ? const Color(0xFFF5B51E)
                      : const Color(0xFFF23B5B);

                  return GestureDetector(
                    onTap: () => setState(() => _selectedDate = date),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF2563EB)
                            : isToday
                            ? const Color(0xFFEAF0FF)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(22),
                        border: isToday && !isSelected
                            ? Border.all(
                                color: const Color(0xFF2563EB),
                                width: 1,
                              )
                            : null,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '${date.day}',
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF0B132B),
                              fontWeight: isSelected || isToday
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          if (markerColor != Colors.transparent)
                            Positioned(
                              bottom: 6,
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: markerColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Text(
              'Upcoming Leaves',
              style: TextStyle(fontSize: 22 / 1.2, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _segmentIndex = 0),
              child: const Text('See all'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (upcoming.isEmpty)
          _buildEmptyState('No upcoming leaves found.')
        else
          ...upcoming.take(3).map((e) => _buildUpcomingCard(e)),
        const SizedBox(height: 12),
        _buildSelectedDayPanel(selectedItems),
      ],
    );
  }

  Widget _buildLegend() {
    Widget item(Color color, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF546A87),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      );
    }

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        item(const Color(0xFF2563EB), 'MY LEAVE'),
        item(const Color(0xFF12AF7E), 'APPROVED'),
        item(const Color(0xFFF5B51E), 'PENDING'),
        item(const Color(0xFFF23B5B), 'REJECTED'),
      ],
    );
  }

  Widget _buildUpcomingCard(LeaveRequestItem item) {
    final statusLower = item.status.toLowerCase();
    final statusColor = statusLower == 'approved'
        ? const Color(0xFF12AF7E)
        : statusLower == 'pending'
        ? const Color(0xFFCC7A00)
        : const Color(0xFFE03D52);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E8F2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 80,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _rangeText(item),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17 / 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _titleCase(item.typeName),
                  style: const TextStyle(
                    color: Color(0xFF60738E),
                    fontSize: 16 / 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5EEFF),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${item.computedDurationDays} DAY${item.computedDurationDays > 1 ? 'S' : ''}',
                    style: const TextStyle(
                      color: Color(0xFF2563EB),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _titleCase(item.status),
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedDayPanel(List<LeaveRequestItem> items) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 54,
              height: 7,
              decoration: BoxDecoration(
                color: const Color(0xFFD6DCE6),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            DateFormat('dd MMMM yyyy • EEEE').format(_selectedDate),
            style: const TextStyle(
              fontSize: 21 / 1.2,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0B132B),
            ),
          ),
          const SizedBox(height: 10),
          if (items.isEmpty)
            const Text(
              'No leave records for this date.',
              style: TextStyle(color: Color(0xFF627690)),
            )
          else
            ...items.map((e) {
              final statusColor = e.isApproved
                  ? const Color(0xFF12AF7E)
                  : e.isPending
                  ? const Color(0xFFCC7A00)
                  : const Color(0xFFE03D52);
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5EEFF),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _titleCase(e.typeName),
                        style: const TextStyle(
                          color: Color(0xFF2563EB),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _titleCase(e.status),
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 26 / 2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE1E8F2)),
      ),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 34, color: Colors.blueGrey.shade300),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF647994),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _titleCase(String input) {
    if (input.trim().isEmpty) return '-';
    final words = input.trim().split(RegExp(r'\s+'));
    return words
        .map(
          (w) => w.isEmpty
              ? w
              : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
        )
        .join(' ');
  }
}

class _WeekLabel extends StatelessWidget {
  final String text;

  const _WeekLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF8092AA),
          fontSize: 19 / 1.3,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
