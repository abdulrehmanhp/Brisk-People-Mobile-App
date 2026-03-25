import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/attendance_service.dart';

class MonthViewScreen extends StatefulWidget {
  final Map<String, String> weeklyAttendance;
  final String? token;

  const MonthViewScreen({
    super.key,
    required this.weeklyAttendance,
    this.token,
  });

  @override
  State<MonthViewScreen> createState() => _MonthViewScreenState();
}

class _MonthViewScreenState extends State<MonthViewScreen> {
  late DateTime _displayedMonth;
  Map<String, String> _monthAttendance = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _displayedMonth = DateTime(DateTime.now().year, DateTime.now().month);
    _monthAttendance = Map.from(widget.weeklyAttendance);
    _loadMonthData();
  }

  Future<void> _loadMonthData() async {
    if (widget.token == null) return;
    setState(() => _isLoading = true);

    final firstDay = DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final lastDay = DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0);

    final result = await AttendanceService.getEmployeeAllAttendance(
      widget.token!,
      startDate: firstDay.toUtc().toIso8601String(),
      endDate: DateTime(lastDay.year, lastDay.month, lastDay.day, 23, 59, 59)
          .toUtc()
          .toIso8601String(),
      pageNumber: 1,
      pageSize: 500,
    );
    final sessions = (result['data'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];

    final Map<String, String> monthly = {};
    for (final s in sessions) {
      final wd = s['workDate']?.toString() ?? '';
      final d = DateTime.tryParse(wd);
      if (d != null) {
        final key = DateFormat('yyyy-MM-dd').format(d);
        final ci = s['checkInTime'] ?? s['CheckInTime'];
        if (ci != null) monthly[key] = 'present';
      }
    }

    // Mark weekends
    for (int day = 1; day <= lastDay.day; day++) {
      final date = DateTime(_displayedMonth.year, _displayedMonth.month, day);
      final key = DateFormat('yyyy-MM-dd').format(date);
      if (!monthly.containsKey(key) &&
          (date.weekday == DateTime.saturday ||
              date.weekday == DateTime.sunday)) {
        monthly[key] = 'weekend';
      }
    }

    _monthAttendance = Map.from(widget.weeklyAttendance);
    _monthAttendance.addAll(monthly);

    if (mounted) setState(() => _isLoading = false);
  }

  void _previousMonth() {
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month - 1);
    });
    _loadMonthData();
  }

  void _nextMonth() {
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month + 1);
    });
    _loadMonthData();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final firstDayOfMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final lastDayOfMonth =
        DateTime(_displayedMonth.year, _displayedMonth.month + 1, 0);
    final daysInMonth = lastDayOfMonth.day;
    final startWeekday = firstDayOfMonth.weekday; // 1=Mon, 7=Sun

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Attendance Calendar',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF2563EB),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          // Month navigation
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    onPressed: _previousMonth,
                    icon: const Icon(Icons.chevron_left)),
                Text(
                  DateFormat('MMMM yyyy').format(_displayedMonth),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
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
                                  color: Colors.grey.shade500)),
                        ),
                      ))
                  .toList(),
            ),
          ),

          const SizedBox(height: 8),

          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(),
            ),

          // Calendar grid
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.builder(
                itemCount: daysInMonth + startWeekday - 1,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  childAspectRatio: 1,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
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
                  final isFuture = date.isAfter(now);
                  final isWeekend = date.weekday == DateTime.saturday ||
                      date.weekday == DateTime.sunday;

                  Color bgColor;
                  Color textColor = Colors.black87;

                  if (isToday) {
                    bgColor = const Color(0xFF2563EB);
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
                      child: Text(
                        day.toString(),
                        style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Legend
          Padding(
            padding: const EdgeInsets.all(16),
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
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }
}
