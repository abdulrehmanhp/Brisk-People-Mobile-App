import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../widgets/permission_gate.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  State<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  String? _token;
  late DateTime _displayedMonth;
  bool _isLoading = false;

  // date key -> status
  Map<String, String> _monthAttendance = {};
  // All sessions for the displayed month
  List<_DayRecord> _monthRecords = [];
  bool _canViewRecords = false;
  bool _permissionsResolved = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _displayedMonth = DateTime(now.year, now.month);
    _init();
  }

  Future<void> _init() async {
    _token = await AuthService.getToken();
    await _loadPermissionFlags();
    if (_canViewRecords) {
      await _loadMonth();
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPermissionFlags() async {
    final allowed = await PermissionService.hasAnyPermissionByActionKeys([
      PermissionKeys.myAttendanceSummary,
      PermissionKeys.attendanceRecordTable,
      PermissionKeys.recentAttendanceTable,
    ]);
    if (!mounted) return;
    setState(() {
      _canViewRecords = allowed;
      _permissionsResolved = true;
    });
  }

  Future<void> _loadMonth() async {
    if (_token == null) return;
    setState(() => _isLoading = true);

    final first = DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final last = DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0);

    final result = await AttendanceService.getEmployeeAllAttendance(
      _token!,
      startDate: first.toUtc().toIso8601String(),
      endDate:
          DateTime(last.year, last.month, last.day, 23, 59, 59)
              .toUtc()
              .toIso8601String(),
      pageNumber: 1,
      pageSize: 500,
    );

    final sessions = (result['data'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];

    // Group sessions by workDate
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final s in sessions) {
      final wd = s['workDate']?.toString() ?? '';
      final d = DateTime.tryParse(wd);
      if (d == null) continue;
      final key = DateFormat('yyyy-MM-dd').format(d);
      grouped.putIfAbsent(key, () => []).add(s);
    }

    final Map<String, String> attendance = {};
    final List<_DayRecord> records = [];
    final now = DateTime.now();

    // Process days in the month
    for (int d = 1; d <= last.day; d++) {
      final date = DateTime(_displayedMonth.year, _displayedMonth.month, d);
      final key = DateFormat('yyyy-MM-dd').format(date);
      final isWeekend =
          date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
      final isFuture = date.isAfter(DateTime(now.year, now.month, now.day));

      if (isFuture) continue;

      final daySessions = grouped[key];

      if (daySessions != null && daySessions.isNotEmpty) {
        DateTime? firstIn;
        DateTime? lastOut;
        Duration total = Duration.zero;

        for (final s in daySessions) {
          final ci = _parse(s['checkInTime']);
          final co = _parse(s['checkOutTime']);
          if (ci != null) {
            if (firstIn == null || ci.isBefore(firstIn)) firstIn = ci;
            if (co != null) {
              total += co.difference(ci);
              if (lastOut == null || co.isAfter(lastOut)) lastOut = co;
            }
          }
        }

        if (firstIn != null && lastOut != null) {
          attendance[key] = 'present';
        } else if (firstIn != null) {
          attendance[key] = 'present'; // in-progress is still present
        }

        records.add(_DayRecord(
          date: date,
          firstIn: firstIn,
          lastOut: lastOut,
          totalWorked: total,
          status: lastOut != null
              ? 'PRESENT'
              : firstIn != null
                  ? 'IN PROGRESS'
                  : 'ABSENT',
          sessions: daySessions,
        ));
      } else {
        if (isWeekend) {
          attendance[key] = 'weekend';
          records.add(_DayRecord(
            date: date,
            totalWorked: Duration.zero,
            status: 'WEEKEND OFF',
          ));
        } else {
          attendance[key] = 'absent';
          records.add(_DayRecord(
            date: date,
            totalWorked: Duration.zero,
            status: 'ABSENT',
          ));
        }
      }
    }

    records.sort((a, b) => b.date.compareTo(a.date));

    if (mounted) {
      setState(() {
        _monthAttendance = attendance;
        _monthRecords = records;
        _isLoading = false;
      });
    }
  }

  void _prevMonth() {
    setState(() => _displayedMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month - 1));
    _loadMonth();
  }

  void _nextMonth() {
    setState(() => _displayedMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month + 1));
    _loadMonth();
  }

  DateTime? _parse(dynamic v) {
    if (v == null) return null;
    return DateTime.tryParse(v.toString())?.toLocal();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsResolved) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_canViewRecords) {
      return const PermissionDeniedScaffold(
        featureName: 'Attendance History',
      );
    }

    final now = DateTime.now();
    final firstOfMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final lastOfMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0);
    final daysInMonth = lastOfMonth.day;
    final startWeekday = firstOfMonth.weekday; // 1=Mon

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Attendance History',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF2563EB),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          // Month navigation
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    onPressed: _prevMonth,
                    icon: const Icon(Icons.chevron_left)),
                Text(DateFormat('MMMM yyyy').format(_displayedMonth),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(
                    onPressed: _nextMonth,
                    icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Weekday headers
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN']
                  .map((d) => SizedBox(
                      width: 40,
                      child: Center(
                          child: Text(d,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500)))))
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          if (_isLoading)
            const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator()),
          // Calendar grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: daysInMonth + startWeekday - 1,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemBuilder: (context, index) {
                if (index < startWeekday - 1) {
                  return const SizedBox.shrink();
                }
                final day = index - startWeekday + 2;
                final date = DateTime(
                    _displayedMonth.year, _displayedMonth.month, day);
                final key = DateFormat('yyyy-MM-dd').format(date);
                final isToday = date.day == now.day &&
                    date.month == now.month &&
                    date.year == now.year;
                final status = _monthAttendance[key];
                final isFuture =
                    date.isAfter(DateTime(now.year, now.month, now.day));
                final isWeekend = date.weekday == DateTime.saturday ||
                    date.weekday == DateTime.sunday;

                Color bgColor;
                Color textColor = Colors.black87;

                if (isToday) {
                  if (status == 'present') {
                    bgColor = const Color(0xFF27AE60);
                  } else {
                    bgColor = const Color(0xFF2563EB);
                  }
                  textColor = Colors.white;
                } else if (isFuture) {
                  bgColor = Colors.grey.shade50;
                  textColor = Colors.grey.shade400;
                } else if (status == 'present') {
                  bgColor = const Color(0xFF27AE60);
                  textColor = Colors.white;
                } else if (status == 'absent') {
                  bgColor = const Color(0xFFE74C3C);
                  textColor = Colors.white;
                } else if (status == 'weekend' || isWeekend) {
                  bgColor = Colors.grey.shade200;
                  textColor = Colors.grey.shade600;
                } else {
                  bgColor = Colors.grey.shade100;
                }

                return Container(
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(day.toString(),
                        style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Legend
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildLegend(const Color(0xFF27AE60), 'Present'),
                _buildLegend(const Color(0xFFE74C3C), 'Absent'),
                _buildLegend(const Color(0xFF2563EB), 'Today'),
                _buildLegend(Colors.grey.shade200, 'Weekend'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Records list
          Expanded(
            child: _monthRecords.isEmpty && !_isLoading
                ? Center(
                    child: Text('No records for this month',
                        style: TextStyle(color: Colors.grey.shade400)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _monthRecords.length,
                    itemBuilder: (_, i) => _buildDayTile(_monthRecords[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
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
    Color dateBg;
    switch (r.status) {
      case 'PRESENT':
        statusColor = const Color(0xFF27AE60);
        statusBg = const Color(0xFFD5F5E3);
        dateBg = const Color(0xFF27AE60);
        break;
      case 'IN PROGRESS':
        statusColor = const Color(0xFF2563EB);
        statusBg = const Color(0xFFDCE8FF);
        dateBg = const Color(0xFF2563EB);
        break;
      case 'WEEKEND OFF':
        statusColor = Colors.grey.shade600;
        statusBg = Colors.grey.shade100;
        dateBg = Colors.grey.shade400;
        break;
      default: // ABSENT
        statusColor = const Color(0xFFE74C3C);
        statusBg = const Color(0xFFFDEDED);
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
  final List<Map<String, dynamic>>? sessions;

  _DayRecord({
    required this.date,
    this.firstIn,
    this.lastOut,
    required this.totalWorked,
    required this.status,
    this.sessions,
  });
}
