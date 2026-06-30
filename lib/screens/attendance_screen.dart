import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../widgets/permission_gate.dart';
import 'attendance_history_screen.dart';

class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  late Timer _timer;
  DateTime _currentTime = DateTime.now();

  String? _token;
  String? _shiftId;
  bool _isCheckedIn = false;
  bool _isSubmitting = false;
  DateTime? _checkInTime;
 
  // Today's sessions from the EmployeeAllAttendance API
  List<Map<String, dynamic>> _todaySessions = [];

  // Recent attendance (last ~10 grouped by day)
  List<_DayRecord> _recentRecords = [];
  bool _loadingRecent = false;

  // Filter
  DateTime? _filterFrom;
  DateTime? _filterTo;

  bool _canClockIn = false;
  bool _canClockOut = false;
  bool _canViewRecords = false;
  bool _permissionsResolved = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });
    _init();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    _token = await AuthService.getToken();
    await _loadPermissionFlags();
    await _loadTodayState();
    await _loadRecentAttendance();
  }

  Future<void> _loadPermissionFlags() async {
    final results = await Future.wait([
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockIn),
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockOut),
      PermissionService.hasPermissionByActionKey(
        PermissionKeys.myAttendanceSummary,
      ),
      PermissionService.hasPermissionByActionKey(
        PermissionKeys.attendanceRecordTable,
      ),
      PermissionService.hasPermissionByActionKey(
        PermissionKeys.recentAttendanceTable,
      ),
    ]);

    if (!mounted) return;
    setState(() {
      _canClockIn = results[0];
      _canClockOut = results[1];
      _canViewRecords = results[2] || results[3] || results[4];
      _permissionsResolved = true;
    });
  }

  Future<void> _loadTodayState() async {
    if (_token == null) return;

    final resp = await AttendanceService.getTodayAttendance(_token!);
    final data = resp?['data'];
    if (data is Map<String, dynamic>) {
      final rawShift = data['shiftId'] ?? data['ShiftId'];
      if (rawShift != null && rawShift.toString().isNotEmpty) {
        if (mounted) setState(() => _shiftId = rawShift.toString());
      }
    }

    if ((_shiftId ?? '').isEmpty) {
      final info = await AuthService.getUserInfo();
      final uid = info['userId'];
      if (uid != null && uid.isNotEmpty) {
        final sid = await AttendanceService.getEmployeeShiftId(_token!, uid);
        if (mounted && sid != null) setState(() => _shiftId = sid);
      }
    }

    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final result = await AttendanceService.getEmployeeAllAttendance(
      _token!,
      startDate: start.toUtc().toIso8601String(),
      endDate: today.toUtc().toIso8601String(),
      pageNumber: 1,
      pageSize: 50,
    );
    final sessions = (result['data'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];

    DateTime? activeStart;
    for (final s in sessions) {
      final ci = _parse(s['checkInTime']);
      final co = _parse(s['checkOutTime']);
      if (ci != null && co == null) {
        if (activeStart == null || ci.isAfter(activeStart)) activeStart = ci;
      }
    }

    if (mounted) {
      setState(() {
        _todaySessions = sessions;
        _isCheckedIn = activeStart != null;
        _checkInTime = activeStart;
      });
    }
  }

  Future<void> _loadRecentAttendance({DateTime? from, DateTime? to}) async {
    if (_token == null) return;
    setState(() => _loadingRecent = true);

    final now = DateTime.now();
    final start = from ?? now.subtract(const Duration(days: 30));
    final end = to ?? now;

    final result = await AttendanceService.getEmployeeAllAttendance(
      _token!,
      startDate: start.toUtc().toIso8601String(),
      endDate: end.toUtc().toIso8601String(),
      pageNumber: 1,
      pageSize: 50,
    );
    final sessions = (result['data'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];

    // Group by workDate
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final s in sessions) {
      final wd = s['workDate']?.toString() ?? '';
      final d = DateTime.tryParse(wd);
      if (d == null) continue;
      final key = DateFormat('yyyy-MM-dd').format(d);
      grouped.putIfAbsent(key, () => []).add(s);
    }

    final List<_DayRecord> records = [];
    grouped.forEach((dateKey, daySessions) {
      final date = DateTime.parse(dateKey);
      DateTime? firstIn;
      DateTime? lastOut;
      Duration totalWorked = Duration.zero;

      for (final s in daySessions) {
        final ci = _parse(s['checkInTime']);
        final co = _parse(s['checkOutTime']);
        if (ci != null) {
          if (firstIn == null || ci.isBefore(firstIn)) firstIn = ci;
          if (co != null) {
            totalWorked += co.difference(ci);
            if (lastOut == null || co.isAfter(lastOut)) lastOut = co;
          }
        }
      }

      String status;
      if (firstIn != null && lastOut != null) {
        status = 'PRESENT';
      } else if (firstIn != null) {
        status = 'IN PROGRESS';
      } else if (date.weekday == DateTime.saturday ||
          date.weekday == DateTime.sunday) {
        status = 'WEEKEND OFF';
      } else {
        status = 'ABSENT';
      }

      records.add(_DayRecord(
        date: date,
        firstIn: firstIn,
        lastOut: lastOut,
        totalWorked: totalWorked,
        status: status,
      ));
    });

    // Add "missing" recent dates not in the API
    final allDates = <String>{};
    for (final r in records) {
      allDates.add(DateFormat('yyyy-MM-dd').format(r.date));
    }
    for (int i = 0; i < 14; i++) {
      final d = now.subtract(Duration(days: i));
      final key = DateFormat('yyyy-MM-dd').format(d);
      if (!allDates.contains(key)) {
        String status;
        if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
          status = 'WEEKEND OFF';
        } else if (d.isAfter(DateTime(now.year, now.month, now.day))) {
          continue;
        } else {
          status = 'ABSENT';
        }
        records.add(_DayRecord(
          date: d,
          status: status,
          totalWorked: Duration.zero,
        ));
      }
    }

    records.sort((a, b) => b.date.compareTo(a.date));

    if (mounted) {
      setState(() {
        _recentRecords = records;
        _loadingRecent = false;
      });
    }
  }

  Future<void> _handleClockIn() async {
    if (!_canClockIn) {
      _showTopMessage('You do not have permission to clock in.', success: false);
      return;
    }
    if (_isSubmitting || (_shiftId ?? '').isEmpty) return;
    setState(() => _isSubmitting = true);
    final result = await AttendanceService.clockIn(_token!, _shiftId!);
    if (mounted) {
      _showTopMessage(result.message, success: result.success);
      if (result.success) await _loadTodayState();
      setState(() => _isSubmitting = false);
    }
  }

  Future<void> _handleClockOut() async {
    if (!_canClockOut) {
      _showTopMessage('You do not have permission to clock out.', success: false);
      return;
    }
    if (_isSubmitting || (_shiftId ?? '').isEmpty) return;
    setState(() => _isSubmitting = true);
    final result = await AttendanceService.clockOut(_token!, _shiftId!);
    if (mounted) {
      _showTopMessage(result.message, success: result.success);
      if (result.success) await _loadTodayState();
      setState(() => _isSubmitting = false);
    }
  }

  void _showTopMessage(String message, {bool success = true}) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).padding.top + 12,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
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
                  child: Text(message,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () {
      if (entry.mounted) entry.remove();
    });
  }

  DateTime? _parse(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString())?.toLocal();
  }

  Duration get _todayTotalWorked {
    Duration total = Duration.zero;
    for (final s in _todaySessions) {
      final ci = _parse(s['checkInTime']);
      final co = _parse(s['checkOutTime']);
      if (ci != null && co != null) {
        total += co.difference(ci);
      }
    }
    // Add live session if currently clocked in
    if (_isCheckedIn && _checkInTime != null) {
      total += _currentTime.difference(_checkInTime!);
    }
    return total;
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        if (isFrom) {
          _filterFrom = picked;
        } else {
          _filterTo = picked;
        }
      });
    }
  }

  // ────────────────────── BUILD ──────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_permissionsResolved) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_canClockIn && !_canClockOut && !_canViewRecords) {
      return const PermissionDeniedScaffold(featureName: 'Attendance');
    }

    final formattedDate =
        DateFormat('EEEE, d MMMM yyyy').format(_currentTime);
    final timeStr = DateFormat('HH : mm : ss').format(_currentTime);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Attendance',
            style: TextStyle(
                color: Colors.black87, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined, size: 22),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const AttendanceHistoryScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            _buildClockHeader(formattedDate, timeStr),
            if (_canClockIn || _canClockOut) ...[
              const SizedBox(height: 16),
              _buildClockButtons(),
            ],
            if (_canViewRecords) ...[
              const SizedBox(height: 20),
              _buildTodaySessions(),
              const SizedBox(height: 20),
              _buildFilterSection(),
              const SizedBox(height: 20),
              _buildRecentAttendance(),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── CLOCK HEADER (blue gradient with live time) ──
  Widget _buildClockHeader(String date, String time) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B7DED), Color(0xFF2563EB), Color(0xFF1D4FD7)],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        children: [
          Text(date,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 8),
          Text(
            time,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 48,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: _isCheckedIn
                  ? Colors.green.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isCheckedIn ? Colors.greenAccent : Colors.white70,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isCheckedIn ? 'Clocked In' : 'Not Clocked In',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── CLOCK IN / OUT BUTTONS ──
  Widget _buildClockButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Clock In
            if (_canClockIn)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed:
                      (!_isCheckedIn && !_isSubmitting) ? _handleClockIn : null,
                  icon: const Icon(Icons.login_rounded, size: 20),
                  label: Text(_isSubmitting && !_isCheckedIn
                      ? 'Clocking In...'
                      : 'Clock In'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _isCheckedIn
                        ? Colors.grey.shade200
                        : const Color(0xFF2563EB),
                    disabledForegroundColor:
                        _isCheckedIn ? Colors.grey.shade400 : Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                ),
              ),
            if (_canClockIn && _canClockOut) const SizedBox(height: 12),
            // Clock Out
            if (_canClockOut)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed:
                      (_isCheckedIn && !_isSubmitting) ? _handleClockOut : null,
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  label: Text(_isSubmitting && _isCheckedIn
                      ? 'Clocking Out...'
                      : 'Clock Out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        _isCheckedIn ? Colors.grey.shade700 : Colors.grey.shade300,
                    side: BorderSide(
                      color: _isCheckedIn
                          ? Colors.grey.shade300
                          : Colors.grey.shade200,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── TODAY'S SESSIONS ──
  Widget _buildTodaySessions() {
    final h = _todayTotalWorked.inHours;
    final m = _todayTotalWorked.inMinutes.remainder(60);
    final totalStr = '${h}h ${m}m';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Today's Sessions",
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (_todaySessions.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCE8FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('Total: $totalStr',
                        style: const TextStyle(
                            color: Color(0xFF2563EB),
                            fontWeight: FontWeight.w600,
                            fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_todaySessions.isEmpty)
              _buildEmptySessions()
            else
              ..._todaySessions.asMap().entries.map((e) {
                final i = e.key;
                final s = e.value;
                return _buildSessionTile(s, i + 1);
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySessions() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.access_time_rounded,
                  color: Colors.grey.shade400, size: 36),
            ),
            const SizedBox(height: 14),
            const Text('No sessions yet today',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: Colors.black87)),
            const SizedBox(height: 4),
            Text('Clock in to start your session',
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(Map<String, dynamic> session, int index) {
    final ci = _parse(session['checkInTime']);
    final co = _parse(session['checkOutTime']);
    final inStr = ci != null ? DateFormat('HH:mm').format(ci) : '--:--';
    final outStr = co != null ? DateFormat('HH:mm').format(co) : 'ongoing';

    Duration dur = Duration.zero;
    if (ci != null) {
      dur = (co ?? _currentTime).difference(ci);
    }
    final durStr = '${dur.inHours}h ${dur.inMinutes.remainder(60)}m';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFFDCE8FF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text('#$index',
                    style: const TextStyle(
                        color: Color(0xFF2563EB),
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$inStr → $outStr',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(durStr,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: co != null
                    ? const Color(0xFFD5F5E3)
                    : const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                co != null ? 'Done' : 'Active',
                style: TextStyle(
                  color: co != null
                      ? const Color(0xFF27AE60)
                      : const Color(0xFFF39C12),
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── FILTER SECTION ──
  Widget _buildFilterSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Filter Records',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _buildDateField(
                    label: 'FROM',
                    value: _filterFrom,
                    onTap: () => _pickDate(isFrom: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildDateField(
                    label: 'TO',
                    value: _filterTo,
                    onTap: () => _pickDate(isFrom: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                onPressed: () {
                  _loadRecentAttendance(from: _filterFrom, to: _filterTo);
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF2563EB),
                  side: const BorderSide(color: Color(0xFF2563EB)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Apply Filter',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateField({
    required String label,
    required DateTime? value,
    required VoidCallback onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 16, color: Colors.grey.shade400),
                const SizedBox(width: 8),
                Text(
                  value != null
                      ? DateFormat('d MMM yyyy').format(value)
                      : label == 'FROM'
                          ? 'Start Date'
                          : 'End Date',
                  style: TextStyle(
                    color:
                        value != null ? Colors.black87 : Colors.grey.shade400,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── RECENT ATTENDANCE ──
  Widget _buildRecentAttendance() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Recent Attendance',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AttendanceHistoryScreen()),
                ),
                child: const Text('View All',
                    style: TextStyle(
                        color: Color(0xFF2563EB),
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loadingRecent)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ))
          else if (_recentRecords.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text('No records found',
                    style: TextStyle(color: Colors.grey.shade400)),
              ),
            )
          else
            ..._recentRecords.take(10).map(_buildDayTile),
        ],
      ),
    );
  }

  Widget _buildDayTile(_DayRecord r) {
    final month = DateFormat('MMM').format(r.date).toUpperCase();
    final day = r.date.day.toString().padLeft(2, '0');
    final dayName = DateFormat('EEEE, d MMMM').format(r.date);

    String subtitle;
    if (r.firstIn != null && r.lastOut != null) {
      final h = r.totalWorked.inHours;
      final m = r.totalWorked.inMinutes.remainder(60);
      subtitle =
          '${DateFormat('HH:mm').format(r.firstIn!)} - ${DateFormat('HH:mm').format(r.lastOut!)} (${h}h ${m}m)';
    } else if (r.firstIn != null) {
      subtitle = 'In: -- Out: --';
    } else if (r.status == 'WEEKEND OFF') {
      subtitle = 'Weekend Holiday';
    } else {
      subtitle = 'No records found';
    }

    Color statusColor;
    Color statusBg;
    switch (r.status) {
      case 'PRESENT':
        statusColor = const Color(0xFF27AE60);
        statusBg = const Color(0xFFD5F5E3);
        break;
      case 'IN PROGRESS':
        statusColor = const Color(0xFF2563EB);
        statusBg = const Color(0xFFDCE8FF);
        break;
      case 'WEEKEND OFF':
        statusColor = Colors.grey.shade600;
        statusBg = Colors.grey.shade100;
        break;
      default: // ABSENT
        statusColor = const Color(0xFFE74C3C);
        statusBg = const Color(0xFFFDEDED);
    }

    Color dateBg;
    switch (r.status) {
      case 'PRESENT':
        dateBg = const Color(0xFF27AE60);
        break;
      case 'IN PROGRESS':
        dateBg = const Color(0xFF2563EB);
        break;
      case 'WEEKEND OFF':
        dateBg = Colors.grey.shade400;
        break;
      default:
        dateBg = const Color(0xFFE74C3C);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Date badge
            Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: dateBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Text(month,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                  Text(day,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dayName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: statusBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(r.status,
                  style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayRecord {
  final DateTime date;
  final DateTime? firstIn;
  final DateTime? lastOut;
  final Duration totalWorked;
  final String status;

  _DayRecord({
    required this.date,
    this.firstIn,
    this.lastOut,
    required this.totalWorked,
    required this.status,
  });
}
