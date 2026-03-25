import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class LeaveTypeItem {
  final String leaveTypeId;
  final String typeName;
  final String? description;
  final int maxDaysPerYear;
  final bool isPaid;
  final bool carryForwardAllowed;
  final int maxCarryForwardDays;
  final String color;
  final bool isActive;

  const LeaveTypeItem({
    required this.leaveTypeId,
    required this.typeName,
    required this.description,
    required this.maxDaysPerYear,
    required this.isPaid,
    required this.carryForwardAllowed,
    required this.maxCarryForwardDays,
    required this.color,
    required this.isActive,
  });

  factory LeaveTypeItem.fromJson(Map<String, dynamic> json) {
    return LeaveTypeItem(
      leaveTypeId: (json['leaveTypeId'] ?? '').toString(),
      typeName: (json['typeName'] ?? '').toString(),
      description: json['description']?.toString(),
      maxDaysPerYear: (json['maxDaysPerYear'] as num?)?.toInt() ?? 0,
      isPaid: json['isPaid'] == true,
      carryForwardAllowed: json['carryForwardAllowed'] == true,
      maxCarryForwardDays: (json['maxCarryForwardDays'] as num?)?.toInt() ?? 0,
      color: (json['color'] ?? '#2563EB').toString(),
      isActive: json['isActive'] == true,
    );
  }

  ColorValue get parsedColor => ColorValue.fromHex(color);
}

class LeaveRequestItem {
  final String requestId;
  final String employeeId;
  final String employeeName;
  final String leaveTypeId;
  final String typeName;
  final DateTime? startDate;
  final DateTime? endDate;
  final double daysRequested;
  final String reason;
  final String status;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final String? approvedBy;
  final String? rejectionReason;

  const LeaveRequestItem({
    required this.requestId,
    required this.employeeId,
    required this.employeeName,
    required this.leaveTypeId,
    required this.typeName,
    required this.startDate,
    required this.endDate,
    required this.daysRequested,
    required this.reason,
    required this.status,
    required this.submittedAt,
    required this.approvedAt,
    required this.approvedBy,
    required this.rejectionReason,
  });

  factory LeaveRequestItem.fromJson(Map<String, dynamic> json) {
    return LeaveRequestItem(
      requestId: (json['requestId'] ?? '').toString(),
      employeeId: (json['employeeId'] ??
              json['EmployeeId'] ??
              json['employeeID'] ??
              json['EmployeeID'] ??
              '')
          .toString(),
      employeeName: (json['employeeName'] ??
          json['employeeFullName'] ??
          json['employee'] ??
          json['requestedBy'] ??
          json['employeeUserName'] ??
          '')
        .toString(),
      leaveTypeId: (json['leaveTypeId'] ?? '').toString(),
      typeName: (json['typename'] ?? json['leaveTypeName'] ?? '').toString(),
      startDate: DateTime.tryParse(
        (json['startDate'] ?? '').toString(),
      )?.toLocal(),
      endDate: DateTime.tryParse((json['endDate'] ?? '').toString())?.toLocal(),
      daysRequested: (json['daysRequested'] as num?)?.toDouble() ?? 0,
      reason: (json['reason'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      submittedAt: DateTime.tryParse(
        (json['submittedAt'] ?? '').toString(),
      )?.toLocal(),
      approvedAt: DateTime.tryParse(
        (json['approvedAt'] ?? '').toString(),
      )?.toLocal(),
      approvedBy: json['approvedBy']?.toString(),
      rejectionReason: json['rejectionReason']?.toString(),
    );
  }

  int get computedDurationDays {
    if (daysRequested > 0) {
      return daysRequested.ceil();
    }
    if (startDate == null || endDate == null) return 0;
    return endDate!.difference(startDate!).inDays + 1;
  }

  bool get isApproved => status.toLowerCase() == 'approved';
  bool get isRejected => status.toLowerCase() == 'rejected';
  bool get isPending => status.toLowerCase() == 'pending';
  bool get isCancelled {
    final s = status.toLowerCase();
    return s == 'cancelled' || s == 'canceled' || s.contains('cancel');
  }

  // Business rule: leave balance is reserved as soon as a request is applied.
  // Rejected/cancelled requests release the reserved days back.
  bool get consumesBalance => !isRejected && !isCancelled;
}

class LeaveApplyPayload {
  final String leaveTypeId;
  final DateTime startDate;
  final DateTime endDate;
  final String reason;

  const LeaveApplyPayload({
    required this.leaveTypeId,
    required this.startDate,
    required this.endDate,
    required this.reason,
  });

  Map<String, dynamic> toJson() {
    final normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final normalizedEnd = DateTime(endDate.year, endDate.month, endDate.day);
    final dayCount = normalizedEnd.difference(normalizedStart).inDays + 1;
    String asApiDateTime(DateTime date) {
      final mm = date.month.toString().padLeft(2, '0');
      final dd = date.day.toString().padLeft(2, '0');
      return '${date.year}-$mm-${dd}T00:00:00';
    }

    return {
      'leaveTypeId': leaveTypeId,
      // Send date-time without timezone offset to match backend examples.
      'startDate': asApiDateTime(normalizedStart),
      'endDate': asApiDateTime(normalizedEnd),
      'daysRequested': dayCount < 1 ? 1 : dayCount,
      'reason': reason,
    };
  }
}

class LeaveSubmitResult {
  final bool success;
  final String message;
  final LeaveRequestItem? request;

  const LeaveSubmitResult({
    required this.success,
    required this.message,
    required this.request,
  });
}

class LeaveActionResult {
  final bool success;
  final String message;

  const LeaveActionResult({
    required this.success,
    required this.message,
  });
}

class LeaveService {
  static const String _apiBase =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Leave';

  static Future<List<LeaveTypeItem>> getLeaveTypesForRequest(
    String token,
  ) async {
    final url = '$_apiBase/typesforrequest';
    try {
      final response = await http.get(Uri.parse(url), headers: _headers(token));

      final body = _safeDecode(response.body);
      _logApi(
        method: 'GET',
        url: url,
        statusCode: response.statusCode,
        responseBody: response.body,
      );

      if (response.statusCode != 200 || body['success'] != true) return [];

      final data = body['data'];
      if (data is! List) return [];
      return data
          .whereType<Map<String, dynamic>>()
          .map(LeaveTypeItem.fromJson)
          .where((e) => e.isActive)
          .toList();
    } catch (e, s) {
      _logException('GET', url, e, s);
      return [];
    }
  }

  static Future<List<LeaveRequestItem>> getMyLeaveRequests(
    String token, {
    String? currentEmployeeId,
  }) async {
    final urls = [
      '$_apiBase/getleaverequestbyemployeeid',
      '$_apiBase/my-requests',
      '$_apiBase/requests/me',
    ];

    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: _headers(token),
        );
        final body = _safeDecode(response.body);
        if (response.statusCode != 200 || body['success'] != true) {
          continue;
        }

        final data = body['data'];
        if (data is List) {
          final parsed = data
              .whereType<Map<String, dynamic>>()
              .map(LeaveRequestItem.fromJson)
              .toList();
          return _filterByEmployee(
            parsed,
            currentEmployeeId: currentEmployeeId,
          );
        }

        if (data is Map<String, dynamic>) {
          final listCandidate =
              data['items'] ?? data['data'] ?? data['results'];
          if (listCandidate is List) {
            final parsed = listCandidate
                .whereType<Map<String, dynamic>>()
                .map(LeaveRequestItem.fromJson)
                .toList();
            return _filterByEmployee(
              parsed,
              currentEmployeeId: currentEmployeeId,
            );
          }
        }
      } catch (_) {
        continue;
      }
    }

    return [];
  }

  static Future<List<LeaveRequestItem>> getTeamLeaveRequests(
    String token, {
    String? currentEmployeeId,
  }) async {
    final urls = [
      '$_apiBase/getleaverequestbymanagerid',
      '$_apiBase/teamrequests',
      '$_apiBase/team-requests',
      '$_apiBase/manager/requests',
      '$_apiBase/requests',
    ];

    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: _headers(token),
        );
        final body = _safeDecode(response.body);
        if (response.statusCode != 200 || body['success'] != true) {
          continue;
        }

        final data = body['data'];
        if (data is List) {
          final parsed = data
              .whereType<Map<String, dynamic>>()
              .map(LeaveRequestItem.fromJson)
              .toList();
          return _teamPendingOnly(
            parsed,
            currentEmployeeId: currentEmployeeId,
          );
        }

        if (data is Map<String, dynamic>) {
          final listCandidate =
              data['items'] ?? data['data'] ?? data['results'];
          if (listCandidate is List) {
            final parsed = listCandidate
                .whereType<Map<String, dynamic>>()
                .map(LeaveRequestItem.fromJson)
                .toList();
            return _teamPendingOnly(
              parsed,
              currentEmployeeId: currentEmployeeId,
            );
          }
        }
      } catch (_) {
        continue;
      }
    }

    return [];
  }

  static List<LeaveRequestItem> _filterByEmployee(
    List<LeaveRequestItem> list, {
    String? currentEmployeeId,
  }) {
    final id = (currentEmployeeId ?? '').trim();
    if (id.isEmpty) return list;

    final hasEmployeeIds = list.any((e) => e.employeeId.trim().isNotEmpty);
    if (!hasEmployeeIds) {
      // If API does not include employeeId, keep original behavior.
      return list;
    }

    final filtered = list.where((e) => e.employeeId.trim() == id).toList();

    // If IDs are of different domains (e.g., userId vs employeeId), do not
    // hide data that API already scoped correctly.
    if (filtered.isEmpty) return list;
    return filtered;
  }

  static List<LeaveRequestItem> _teamPendingOnly(
    List<LeaveRequestItem> list, {
    String? currentEmployeeId,
  }) {
    final myId = (currentEmployeeId ?? '').trim();
    final teamOnly = myId.isEmpty
        ? list
        : list.where((e) => e.employeeId.trim() != myId).toList();
    return teamOnly.where((e) => e.isPending).toList();
  }

  static Future<bool?> checkOverlap({
    required String token,
    required DateTime startDate,
    required DateTime endDate,
    String? excludeRequestId,
  }) async {
    final start = _toApiDate(startDate);
    final end = _toApiDate(endDate);
    var url = '$_apiBase/check-overlap?startDate=$start&endDate=$end';
    if (excludeRequestId != null && excludeRequestId.isNotEmpty) {
      url += '&excludeRequestId=$excludeRequestId';
    }

    try {
      final response = await http.get(Uri.parse(url), headers: _headers(token));
      final body = _safeDecode(response.body);
      _logApi(
        method: 'GET',
        url: url,
        statusCode: response.statusCode,
        responseBody: response.body,
      );
      if (response.statusCode != 200 || body['success'] != true) return null;

      final data = body['data'];
      if (data is bool) return data;
      if (data is String) return data.toLowerCase() == 'true';
      return null;
    } catch (e, s) {
      _logException('GET', url, e, s);
      return null;
    }
  }

  static Future<LeaveSubmitResult> createLeaveRequest({
    required String token,
    required LeaveApplyPayload payload,
  }) async {
    final url = '$_apiBase/requests';
    final requestBody = jsonEncode(payload.toJson());
    try {
      final response = await http.post(
        Uri.parse(url),
        headers: _headers(token),
        body: requestBody,
      );

      final body = _safeDecode(response.body);
      _logApi(
        method: 'POST',
        url: url,
        statusCode: response.statusCode,
        requestBody: requestBody,
        responseBody: response.body,
      );

      final statusOk = response.statusCode == 200 || response.statusCode == 201;
      final apiSuccess = body['success'] == true;
      final isSuccessfulSubmit =
          statusOk && (apiSuccess || response.statusCode == 201);

      if (!isSuccessfulSubmit) {
        final message = _extractMessage(
          body,
          fallback: 'Unable to submit leave request.',
        );
        return LeaveSubmitResult(
          success: false,
          message: message,
          request: null,
        );
      }

      final successMessage = _extractMessage(
        body,
        fallback: 'Leave request submitted successfully.',
      );

      final data = body['data'];
      if (data is Map<String, dynamic>) {
        return LeaveSubmitResult(
          success: true,
          message: successMessage,
          request: LeaveRequestItem.fromJson(data),
        );
      }

      // Some successful responses may omit/reshape data. Treat as success.
      return LeaveSubmitResult(
        success: true,
        message: successMessage,
        request: null,
      );
    } catch (e, s) {
      _logException('POST', url, e, s);
      return const LeaveSubmitResult(
        success: false,
        message: 'Network error while submitting leave request.',
        request: null,
      );
    }
  }

  static Future<LeaveActionResult> cancelLeaveRequest({
    required String token,
    required String requestId,
  }) async {
    if (requestId.trim().isEmpty) {
      return const LeaveActionResult(
        success: false,
        message: 'Invalid leave request id.',
      );
    }

    final encodedId = Uri.encodeComponent(requestId);
    final attempts = [
      (
        method: 'POST',
        url: '$_apiBase/requests/$encodedId/cancel',
        body: null,
      ),
      (
        method: 'PUT',
        url: '$_apiBase/requests/$encodedId/cancel',
        body: null,
      ),
      (
        method: 'POST',
        url: '$_apiBase/cancel/$encodedId',
        body: null,
      ),
      (
        method: 'DELETE',
        url: '$_apiBase/requests/$encodedId',
        body: null,
      ),
    ];

    String? lastFailure;
    for (final attempt in attempts) {
      try {
        late http.Response response;
        final uri = Uri.parse(attempt.url);
        if (attempt.method == 'POST') {
          response = await http.post(
            uri,
            headers: _headers(token),
            body: attempt.body,
          );
        } else if (attempt.method == 'PUT') {
          response = await http.put(
            uri,
            headers: _headers(token),
            body: attempt.body,
          );
        } else {
          response = await http.delete(
            uri,
            headers: _headers(token),
          );
        }

        final body = _safeDecode(response.body);
        _logApi(
          method: attempt.method,
          url: attempt.url,
          statusCode: response.statusCode,
          requestBody: attempt.body,
          responseBody: response.body,
        );

        final statusOk =
            response.statusCode == 200 ||
            response.statusCode == 201 ||
            response.statusCode == 204;
        final apiSuccess = body['success'] == true;

        if (statusOk && (apiSuccess || response.statusCode == 204)) {
          return LeaveActionResult(
            success: true,
            message: _extractMessage(
              body,
              fallback: 'Leave request cancelled successfully.',
            ),
          );
        }

        if (response.statusCode == 404 || response.statusCode == 405) {
          continue;
        }

        lastFailure = _extractMessage(
          body,
          fallback: 'Unable to cancel leave request.',
        );
        return LeaveActionResult(success: false, message: lastFailure);
      } catch (e, s) {
        _logException(attempt.method, attempt.url, e, s);
        lastFailure ??= 'Network error while cancelling leave request.';
      }
    }

    return LeaveActionResult(
      success: false,
      message: lastFailure ??
          'Cancel request is not available for your account at the moment.',
    );
  }

  static Future<LeaveActionResult> approveLeaveRequest({
    required String token,
    required String requestId,
  }) async {
    if (requestId.trim().isEmpty) {
      return const LeaveActionResult(
        success: false,
        message: 'Invalid leave request id.',
      );
    }

    final encodedId = Uri.encodeComponent(requestId);
    final url = '$_apiBase/requests/$encodedId/approve';
    try {
      final response = await http.put(Uri.parse(url), headers: _headers(token));
      final body = _safeDecode(response.body);
      _logApi(
        method: 'PUT',
        url: url,
        statusCode: response.statusCode,
        responseBody: response.body,
      );

      final statusOk = response.statusCode == 200 || response.statusCode == 204;
      final apiSuccess = body['success'] == true;
      if (statusOk && (apiSuccess || response.statusCode == 204)) {
        return LeaveActionResult(
          success: true,
          message: _extractMessage(
            body,
            fallback: 'Leave request approved successfully.',
          ),
        );
      }

      return LeaveActionResult(
        success: false,
        message: _extractMessage(body, fallback: 'Unable to approve leave request.'),
      );
    } catch (e, s) {
      _logException('PUT', url, e, s);
      return const LeaveActionResult(
        success: false,
        message: 'Network error while approving leave request.',
      );
    }
  }

  static Future<LeaveActionResult> rejectLeaveRequest({
    required String token,
    required String requestId,
    String? reason,
  }) async {
    if (requestId.trim().isEmpty) {
      return const LeaveActionResult(
        success: false,
        message: 'Invalid leave request id.',
      );
    }

    final encodedId = Uri.encodeComponent(requestId);
    final payload = jsonEncode({
      'status': 'rejected',
      'rejectionReason': (reason ?? '').trim(),
    });
    final url = '$_apiBase/requests/$encodedId/reject';
    try {
      final response = await http.put(
        Uri.parse(url),
        headers: _headers(token),
        body: payload,
      );
      final body = _safeDecode(response.body);
      _logApi(
        method: 'PUT',
        url: url,
        statusCode: response.statusCode,
        requestBody: payload,
        responseBody: response.body,
      );

      final statusOk = response.statusCode == 200 || response.statusCode == 204;
      final apiSuccess = body['success'] == true;
      if (statusOk && (apiSuccess || response.statusCode == 204)) {
        return LeaveActionResult(
          success: true,
          message: _extractMessage(
            body,
            fallback: 'Leave request rejected successfully.',
          ),
        );
      }

      return LeaveActionResult(
        success: false,
        message: _extractMessage(body, fallback: 'Unable to reject leave request.'),
      );
    } catch (e, s) {
      _logException('PUT', url, e, s);
      return const LeaveActionResult(
        success: false,
        message: 'Network error while rejecting leave request.',
      );
    }
  }

  static Map<String, String> _headers(String token) {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static String _toApiDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  static String _extractMessage(
    Map<String, dynamic> body, {
    required String fallback,
  }) {
    final message = body['message']?.toString();
    if (message != null && message.trim().isNotEmpty) return message;

    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first.toString().trim();
      if (first.isNotEmpty) return first;
    }

    if (errors is String && errors.trim().isNotEmpty) {
      return errors.trim();
    }

    return fallback;
  }

  static Map<String, dynamic> _safeDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return {};
    }
    return {};
  }

  static void _logApi({
    required String method,
    required String url,
    required int statusCode,
    String? requestBody,
    String? responseBody,
  }) {
    if (!kDebugMode) return;
    debugPrint('[LeaveService] $method $url -> $statusCode');
    if (requestBody != null && requestBody.isNotEmpty) {
      debugPrint('[LeaveService] request: $requestBody');
    }
    if (responseBody != null && responseBody.isNotEmpty) {
      debugPrint('[LeaveService] response: $responseBody');
    }
  }

  static void _logException(
    String method,
    String url,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!kDebugMode) return;
    debugPrint('[LeaveService] $method $url threw: $error');
    debugPrint(stackTrace.toString());
  }
}

class ColorValue {
  final int value;

  const ColorValue(this.value);

  static ColorValue fromHex(String hex) {
    var clean = hex.trim().replaceAll('#', '');
    if (clean.length == 6) clean = 'FF$clean';
    final parsed = int.tryParse(clean, radix: 16) ?? 0xFF2563EB;
    return ColorValue(parsed);
  }
}
