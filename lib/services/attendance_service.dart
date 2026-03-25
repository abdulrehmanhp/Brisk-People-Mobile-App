import 'dart:convert';
import 'package:http/http.dart' as http;

class AttendanceActionResult {
  final bool success;
  final String message;

  const AttendanceActionResult({required this.success, required this.message});
}

class ShiftInfo {
  final String shiftId;
  final String shiftName;

  const ShiftInfo({required this.shiftId, required this.shiftName});

  factory ShiftInfo.fromJson(Map<String, dynamic> json) {
    return ShiftInfo(
      shiftId: (json['shiftId'] ?? json['ShiftId'] ?? json['id'] ?? '').toString(),
      shiftName: (json['shiftName'] ?? json['ShiftName'] ?? json['name'] ?? 'Shift')
          .toString(),
    );
  }
}

class ShiftSwapRequestItem {
  final String requestId;
  final String employeeId;
  final String employeeName;
  final String? currentShiftId;
  final String currentShiftName;
  final String requestedShiftId;
  final String requestedShiftName;
  final String reason;
  final String status;
  final DateTime? requestDate;
  final DateTime? submittedAt;

  const ShiftSwapRequestItem({
    required this.requestId,
    required this.employeeId,
    required this.employeeName,
    required this.currentShiftId,
    required this.currentShiftName,
    required this.requestedShiftId,
    required this.requestedShiftName,
    required this.reason,
    required this.status,
    required this.requestDate,
    required this.submittedAt,
  });

  factory ShiftSwapRequestItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseAnyDate(dynamic raw) {
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString())?.toLocal();
    }

    return ShiftSwapRequestItem(
      requestId: (json['requestId'] ?? json['RequestId'] ?? '').toString(),
      employeeId: (json['employeeId'] ?? json['EmployeeId'] ?? '').toString(),
      employeeName: (json['employeeName'] ?? json['EmployeeName'] ?? '').toString(),
      currentShiftId: (json['currentShiftId'] ?? json['CurrentShiftId'])?.toString(),
      currentShiftName: (json['currentShiftName'] ?? json['CurrentShiftName'] ?? '')
          .toString(),
      requestedShiftId:
          (json['requestedShiftId'] ?? json['RequestedShiftId'] ?? '').toString(),
      requestedShiftName:
          (json['requestedShiftName'] ?? json['RequestedShiftName'] ?? '')
              .toString(),
      reason: (json['reason'] ?? json['Reason'] ?? '').toString(),
      status: (json['status'] ?? json['Status'] ?? '').toString(),
      requestDate: parseAnyDate(
        json['requestDate'] ??
            json['RequestDate'] ??
            json['date'] ??
            json['Date'] ??
            json['shiftDate'] ??
            json['ShiftDate'] ??
            json['workDate'] ??
            json['WorkDate'],
      ),
      submittedAt: parseAnyDate(
        json['submittedAt'] ??
            json['SubmittedAt'] ??
            json['createdAt'] ??
            json['CreatedAt'] ??
            json['updatedAt'] ??
            json['UpdatedAt'],
      ),
    );
  }

  bool get isPending => status.toLowerCase() == 'pending';
}

class AttendanceService {
  static const String _apiBase =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api';
  static const String baseUrl = '$_apiBase/Attendance';

  static Future<AttendanceActionResult> clockIn(
    String token,
    String shiftId,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/clock-in'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'action': 'in',
        'location': {},
        'notes': 'Clock in from mobile',
        'shiftId': shiftId,
      }),
    );

    final Map<String, dynamic> body = _safeDecode(response.body);
    final bool apiSuccess = body['success'] == true;
    final String message =
        (body['message'] as String?) ?? 'Unable to clock in from mobile app.';

    return AttendanceActionResult(
      success: response.statusCode == 200 && apiSuccess,
      message: message,
    );
  }

  static Future<AttendanceActionResult> clockOut(
    String token,
    String shiftId,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/clock-out'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'action': 'out',
        'location': {},
        'notes': 'Clock out from mobile',
        'shiftId': shiftId,
      }),
    );

    final Map<String, dynamic> body = _safeDecode(response.body);
    final bool apiSuccess = body['success'] == true;
    final String message =
        (body['message'] as String?) ?? 'Unable to clock out from mobile app.';

    return AttendanceActionResult(
      success: response.statusCode == 200 && apiSuccess,
      message: message,
    );
  }

  static Future<Map<String, dynamic>?> getTodayAttendance(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/today'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) {
      return null;
    }

    return _safeDecode(response.body);
  }

  /// Fetch the employee's currently assigned shift via
  /// GET /api/Attendance/CurrentShift/{employeeId}
  static Future<String?> getEmployeeShiftId(
    String token,
    String employeeId,
  ) async {
    // 1) Try the employee-specific shift endpoint
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/CurrentShift/$employeeId'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        final body = _safeDecode(response.body);
        final data = body['data'];
        if (data is Map<String, dynamic>) {
          final id =
              data['shiftId'] ?? data['ShiftId'] ?? data['id'] ?? data['Id'];
          if (id != null && id.toString().isNotEmpty) {
            return id.toString();
          }
        }
      }
    } catch (_) {}

    // 2) Fallback: fetch all org shifts and use the first one
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/shifts'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode == 200) {
        final body = _safeDecode(res.body);
        final data = body['data'];
        if (data is List && data.isNotEmpty) {
          final first = data[0];
          if (first is Map<String, dynamic>) {
            final id =
                first['shiftId'] ?? first['ShiftId'] ?? first['id'] ?? first['Id'];
            if (id != null && id.toString().isNotEmpty) {
              return id.toString();
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static Map<String, dynamic> _safeDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Return empty map so callers can handle a malformed payload gracefully.
    }
    return <String, dynamic>{};
  }

  /// Fetch attendance records for a date range.
  /// Tries /api/Attendance/range?startDate=...&endDate=...
  static Future<List<Map<String, dynamic>>> getAttendanceRange(
    String token,
    String startDate,
    String endDate,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/range?startDate=$startDate&endDate=$endDate'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (response.statusCode == 200) {
        final body = _safeDecode(response.body);
        final data = body['data'];
        if (data is List) {
          return data
              .whereType<Map<String, dynamic>>()
              .toList();
        }
      }
    } catch (_) {}
    return [];
  }

  /// Fetch all attendance entries for today (multiple clock-in/out sessions).
  /// Tries /api/Attendance/today/details
  static Future<List<Map<String, dynamic>>> getTodayDetails(
    String token,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/today/details'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (response.statusCode == 200) {
        final body = _safeDecode(response.body);
        final data = body['data'];
        if (data is List) {
          return data.whereType<Map<String, dynamic>>().toList();
        }
      }
    } catch (_) {}
    return [];
  }

  /// Fetch paginated employee attendance sessions using EmployeeAllAttendance API.
  /// Returns { 'data': [...], 'totalCount': int, 'page': int, 'pageSize': int }
  static Future<Map<String, dynamic>> getEmployeeAllAttendance(
    String token, {
    required String startDate,
    required String endDate,
    int pageNumber = 1,
    int pageSize = 10,
  }) async {
    try {
      final uri = Uri.parse(
        '$baseUrl/EmployeeAllAttendance'
        '?startDate=$startDate&endDate=$endDate'
        '&pageNumber=$pageNumber&pageSize=$pageSize',
      );
      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (response.statusCode == 200) {
        final body = _safeDecode(response.body);
        final outerData = body['data'];
        if (outerData is Map<String, dynamic>) {
          return outerData;
        }
      }
    } catch (_) {}
    return {'data': [], 'totalCount': 0, 'page': pageNumber, 'pageSize': pageSize};
  }

  static Future<List<ShiftInfo>> getShifts(String token) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/shifts'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode != 200) return [];
      final body = _safeDecode(res.body);
      final data = body['data'];
      if (data is! List) return [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(ShiftInfo.fromJson)
          .where((e) => e.shiftId.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<AttendanceActionResult> createShiftSwapRequest(
    String token, {
    required String employeeId,
    String? currentShiftId,
    required String requestedShiftId,
    String? reason,
  }) async {
    final body = jsonEncode({
      'employeeId': employeeId,
      'currentShiftId': (currentShiftId ?? '').trim().isEmpty ? null : currentShiftId,
      'requestedShiftId': requestedShiftId,
      'reason': (reason ?? '').trim(),
    });
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/shiftswap'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: body,
      );
      final payload = _safeDecode(res.body);
      final statusOk = res.statusCode >= 200 && res.statusCode < 300;
      final apiSuccess = payload['success'];
      final ok = statusOk && (apiSuccess == null || apiSuccess == true);
      return AttendanceActionResult(
        success: ok,
        message: (payload['message'] ??
                (ok
                    ? 'Shift swap request created successfully.'
                    : 'Failed to create shift swap request.'))
            .toString(),
      );
    } catch (_) {
      return const AttendanceActionResult(
        success: false,
        message: 'Network error while creating shift swap request.',
      );
    }
  }

  static Future<AttendanceActionResult> approveShiftSwapRequest(
    String token, {
    required String requestId,
    required String approvedBy,
    required bool isApproved,
    String? rejectionReason,
  }) async {
    final body = jsonEncode({
      'requestId': requestId,
      'approvedBy': approvedBy,
      'isApproved': isApproved,
      'rejectionReason': (rejectionReason ?? '').trim(),
    });
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/shiftswap/approve'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: body,
      );
      final payload = _safeDecode(res.body);
      final statusOk = res.statusCode >= 200 && res.statusCode < 300;
      final apiSuccess = payload['success'];
      final ok = statusOk && (apiSuccess == null || apiSuccess == true);
      return AttendanceActionResult(
        success: ok,
        message: (payload['message'] ??
                (ok ? 'Shift swap request processed successfully.' : 'Failed to process shift swap request.'))
            .toString(),
      );
    } catch (_) {
      return const AttendanceActionResult(
        success: false,
        message: 'Network error while processing shift swap request.',
      );
    }
  }

  static Future<List<ShiftSwapRequestItem>> getPendingShiftSwapRequests(
    String token,
  ) async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/shiftswap/pending'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode != 200) return [];
      final payload = _safeDecode(res.body);
      if (payload['success'] != true) return [];
      final data = payload['data'];
      if (data is! List) return [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(ShiftSwapRequestItem.fromJson)
          .where((e) => e.isPending)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<ShiftSwapRequestItem>> getShiftSwapRequestsByEmployee(
    String token,
    String employeeId,
  ) async {
    final urls = [
      '$baseUrl/shiftswap/eemployeeShifts/$employeeId',
      '$baseUrl/shiftswap/employeeShifts/$employeeId',
    ];
    for (final url in urls) {
      try {
        final res = await http.get(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        );
        if (res.statusCode != 200) continue;
        final payload = _safeDecode(res.body);
        if (payload['success'] != true) continue;
        final data = payload['data'];
        if (data is! List) continue;
        return data
            .whereType<Map<String, dynamic>>()
            .map(ShiftSwapRequestItem.fromJson)
            .toList();
      } catch (_) {
        continue;
      }
    }
    return [];
  }
}
