import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'auth_service.dart';
import 'face_verification_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result wrappers
// ─────────────────────────────────────────────────────────────────────────────

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
      shiftId: (json['shiftId'] ?? json['ShiftId'] ?? json['id'] ?? '')
          .toString(),
      shiftName:
          (json['shiftName'] ?? json['ShiftName'] ?? json['name'] ?? 'Shift')
              .toString(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shift-swap model (unchanged from original)
// ─────────────────────────────────────────────────────────────────────────────

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
      employeeName: (json['employeeName'] ?? json['EmployeeName'] ?? '')
          .toString(),
      currentShiftId: (json['currentShiftId'] ?? json['CurrentShiftId'])
          ?.toString(),
      currentShiftName:
          (json['currentShiftName'] ?? json['CurrentShiftName'] ?? '')
              .toString(),
      requestedShiftId:
          (json['requestedShiftId'] ?? json['RequestedShiftId'] ?? '')
              .toString(),
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

// ─────────────────────────────────────────────────────────────────────────────
// AttendanceService
// ─────────────────────────────────────────────────────────────────────────────

class AttendanceService {
  static const String _apiBase =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api';
  static const String baseUrl = '$_apiBase/Attendance';
  static const String geoFenceBaseUrl = '$_apiBase/GeoFence';

  // ── Public clock entry-points ────────────────────────────────────────────

  static Future<AttendanceActionResult> clockIn(
    String token,
    String shiftId,
  ) async {
    return _smartClock(token: token, shiftId: shiftId, action: 'in');
  }

  static Future<AttendanceActionResult> clockOut(
    String token,
    String shiftId,
  ) async {
    return _smartClock(token: token, shiftId: shiftId, action: 'out');
  }

  // ── Core routing: check geofence first, then branch ─────────────────────

  /// Decides whether this shift uses geofencing.
  ///
  ///  • No geofence attached  → use the legacy clock-in/out endpoint.
  ///    The backend already returns "late by Xh Ym" / "left early by..." in the
  ///    message, so we just surface that message to the user.
  ///
  ///  • Geofence attached → request location permission, get the device
  ///    position, then call the GeoFence/clock endpoint which validates that
  ///    the user is inside the fence radius BEFORE recording attendance.
  static Future<AttendanceActionResult> _smartClock({
    required String token,
    required String shiftId,
    required String action,
  }) async {
    // 1. Resolve geofence requirements for this shift.
    final geoFenceLookup = await _getGeoFenceRequirementForShift(
      token,
      shiftId,
    );

    // If geofence requirement cannot be determined, block the action to avoid
    // bypassing location validation for geo-fenced shifts.
    if (!geoFenceLookup.resolved) {
      return AttendanceActionResult(
        success: false,
        message: geoFenceLookup.errorMessage,
      );
    }

    if (!geoFenceLookup.requiresGeoFence) {
      // ── PATH A: No geofence — normal clock (with late/early message from backend)
      return _legacyClock(token, shiftId, action);
    }

    // ── PATH B: Geofence exists — location is mandatory
    // 2. Ensure location services + permission.
    final locationCheck = await _ensureLocationPermission();
    if (!locationCheck.granted) {
      return AttendanceActionResult(
        success: false,
        message: locationCheck.errorMessage,
      );
    }

    // 3. Get the current device position.
    final position = await _getCurrentPosition();
    if (position == null) {
      return const AttendanceActionResult(
        success: false,
        message:
            'Unable to get your current location. Please ensure GPS is enabled and try again.',
      );
    }

    // 4. Validate coordinates against geofence center/radius on mobile.
    final rangeCheck = await _validateDeviceWithinGeoFence(
      token,
      geoFenceLookup.geoFenceId!,
      position,
    );
    if (!rangeCheck.allowed) {
      return AttendanceActionResult(
        success: false,
        message: rangeCheck.message,
      );
    }

    // 5. Face verification is mandatory for geo-fenced shifts.
    final profilePicture = await AuthService.getProfilePictureUrl(
      refresh: true,
    );
    if (profilePicture == null || profilePicture.trim().isEmpty) {
      return const AttendanceActionResult(
        success: false,
        message:
            'Profile picture not uploaded. Please upload profile photo before clock in/out for geo-fenced shifts.',
      );
    }

    final faceResult = await FaceVerificationService.verifyAgainstProfile(
      profilePicture,
    );
    if (!faceResult.success) {
      return AttendanceActionResult(
        success: false,
        message: faceResult.message,
      );
    }

    // 6. Call the geofence-aware clock endpoint.
    //    The backend (fn_clock_in_out_geo) validates that the user is within
    //    the fence radius and blocks the request if they are outside.
    return _geoClock(
      token: token,
      shiftId: shiftId,
      geoFenceId: geoFenceLookup.geoFenceId!,
      action: action,
      position: position,
      context: _GeoClockContext.fromFaceResult(faceResult),
    );
  }

  // ── PATH A: Legacy (no geofence) ─────────────────────────────────────────

  static Future<AttendanceActionResult> _legacyClock(
    String token,
    String shiftId,
    String action,
  ) async {
    try {
      final endpoint = action == 'in' ? 'clock-in' : 'clock-out';
      final response = await http.post(
        Uri.parse('$baseUrl/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'action': action,
          'location': {},
          'notes': action == 'in'
              ? 'Clock in from mobile'
              : 'Clock out from mobile',
          'shiftId': shiftId,
        }),
      );

      final Map<String, dynamic> body = _safeDecode(response.body);
      final bool apiSuccess = body['success'] == true;

      // The backend AttendanceService already builds messages like:
      //   "Clocked in successfully, but you are late by 0h 15m"
      //   "Clocked out successfully, but you left early by 1h 3m"
      // We surface those verbatim so the user sees timing info.
      final String message =
          (body['message'] as String?) ??
          (action == 'in'
              ? 'Clocked in successfully.'
              : 'Clocked out successfully.');

      return AttendanceActionResult(
        success: response.statusCode == 200 && apiSuccess,
        message: message,
      );
    } catch (e) {
      return AttendanceActionResult(
        success: false,
        message:
            'Network error: unable to ${action == 'in' ? 'clock in' : 'clock out'}.',
      );
    }
  }

  // ── PATH B: Geofence-aware clock ─────────────────────────────────────────

  static Future<AttendanceActionResult> _geoClock({
    required String token,
    required String shiftId,
    required String geoFenceId,
    required String action,
    required Position position,
    required _GeoClockContext context,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$geoFenceBaseUrl/clock'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'action': action,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'geoFenceId': geoFenceId,
          'faceDescriptor': context.faceDescriptor,
          'confidenceScore': context.confidenceScore,
          'distanceScore': context.distanceScore,
          'matchResult': context.matchResult,
          'notes': action == 'in'
              ? 'Clock in from mobile app'
              : 'Clock out from mobile app',
          'deviceInfo': jsonEncode({'platform': 'flutter_mobile'}),
        }),
      );

      final body = _safeDecode(response.body);

      // The GeoFence/clock response wraps the GeoClockInResponse in data:
      // { success: bool, message: str, data: { success: bool, message: str,
      //     locationStatus: str, distanceMeters: num, ... } }
      final outerSuccess = body['success'] == true;
      final data = body['data'];
      final innerSuccess = data is Map<String, dynamic>
          ? data['success'] == true
          : outerSuccess;

      // Prefer the inner message (set by the DB function — contains distance
      // info and geofence violation reason), fall back to outer message.
      final String message = _pickBestMessage(data, body, action);

      final locationStatus = _extractLocationStatus(data, body);
      if (_isDeniedGeoStatus(locationStatus)) {
        return AttendanceActionResult(success: false, message: message);
      }

      final statusOk = response.statusCode >= 200 && response.statusCode < 300;

      if (statusOk && outerSuccess && innerSuccess) {
        return AttendanceActionResult(success: true, message: message);
      }

      return AttendanceActionResult(success: false, message: message);
    } catch (_) {
      return AttendanceActionResult(
        success: false,
        message:
            'Unable to validate geo-fence for this shift right now. Please try again.',
      );
    }
  }

  /// Picks the most informative message from the layered API response.
  static String _pickBestMessage(
    dynamic data,
    Map<String, dynamic> outer,
    String action,
  ) {
    if (data is Map<String, dynamic>) {
      final inner = (data['message'] as String?)?.trim();
      if (inner != null && inner.isNotEmpty) return inner;
    }
    final outerMsg = (outer['message'] as String?)?.trim();
    if (outerMsg != null && outerMsg.isNotEmpty) return outerMsg;
    return action == 'in'
        ? 'Clocked in successfully.'
        : 'Clocked out successfully.';
  }

  // ── Location helpers ─────────────────────────────────────────────────────

  static Future<_LocationCheckResult> _ensureLocationPermission() async {
    // Is the device's location service (GPS) enabled at all?
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return _LocationCheckResult(
        granted: false,
        errorMessage:
            'Location services are disabled on your device. '
            'Please enable GPS and try again.',
      );
    }

    // Check / request app-level permission.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return _LocationCheckResult(
        granted: false,
        errorMessage:
            'Location permission is permanently denied. '
            'Please allow it from device Settings to clock in/out '
            'for a geo-fenced shift.',
      );
    }

    if (permission == LocationPermission.denied) {
      return _LocationCheckResult(
        granted: false,
        errorMessage:
            'Location permission is required to clock in/out '
            'for this shift because it has a geo-fence.',
      );
    }

    return _LocationCheckResult(granted: true, errorMessage: '');
  }

  static Future<Position?> _getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (_) {
      // Last-known is better than nothing for a quick fallback.
      return Geolocator.getLastKnownPosition();
    }
  }

  static Future<_GeoFenceRangeCheckResult> _validateDeviceWithinGeoFence(
    String token,
    String geoFenceId,
    Position position,
  ) async {
    final details = await _getGeoFenceDetails(token, geoFenceId);
    if (details == null) {
      return const _GeoFenceRangeCheckResult(
        allowed: false,
        message:
            'Unable to load geo-fence coordinates for this shift. Please try again.',
      );
    }

    final distanceMeters = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      details.centerLatitude,
      details.centerLongitude,
    );

    if (distanceMeters > details.radiusMeters) {
      return _GeoFenceRangeCheckResult(
        allowed: false,
        message:
            'You are outside the shift geo-fence. Current distance is ${distanceMeters.toStringAsFixed(0)}m and allowed radius is ${details.radiusMeters.toStringAsFixed(0)}m.',
      );
    }

    return const _GeoFenceRangeCheckResult(allowed: true, message: '');
  }

  static Future<_GeoFenceDetails?> _getGeoFenceDetails(
    String token,
    String geoFenceId,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$geoFenceBaseUrl/$geoFenceId'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final payload = _safeDecode(response.body);
      final raw = payload['data'] ?? payload['Data'] ?? payload;
      if (raw is! Map<String, dynamic>) return null;

      final lat = _toDouble(raw['centerLatitude'] ?? raw['CenterLatitude']);
      final lng = _toDouble(raw['centerLongitude'] ?? raw['CenterLongitude']);
      final radius = _toDouble(raw['radiusMeters'] ?? raw['RadiusMeters']);

      if (lat == null || lng == null || radius == null || radius <= 0) {
        return null;
      }

      return _GeoFenceDetails(
        centerLatitude: lat,
        centerLongitude: lng,
        radiusMeters: radius,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Geofence lookup ──────────────────────────────────────────────────────

  /// Resolves whether the shift has an active geofence and returns its ID.
  ///
  /// `resolved=false` means the app could not determine requirement safely.
  static Future<_GeoFenceLookupResult> _getGeoFenceRequirementForShift(
    String token,
    String shiftId,
  ) async {
    try {
      final response = await http.get(
        Uri.parse('$geoFenceBaseUrl/shift/$shiftId'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 404) {
        return const _GeoFenceLookupResult.none();
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _GeoFenceLookupResult.unresolved(
          'Unable to verify geo-fence settings for your shift. Please try again.',
        );
      }

      final payload = _safeDecode(response.body);
      dynamic list = payload['data'] ?? payload['Data'];
      if (list is! List) {
        if (payload is List) {
          list = payload;
        } else {
          return const _GeoFenceLookupResult.none();
        }
      }

      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        final bool isActive = (raw['isActive'] ?? raw['IsActive']) != false;
        if (!isActive) continue;

        final nestedGeo = raw['geoFence'] ?? raw['GeoFence'];
        final id =
            raw['geoFenceId'] ??
            raw['GeoFenceId'] ??
            (nestedGeo is Map<String, dynamic>
                ? (nestedGeo['geoFenceId'] ??
                      nestedGeo['GeoFenceId'] ??
                      nestedGeo['id'] ??
                      nestedGeo['Id'])
                : null);

        if (id != null && id.toString().isNotEmpty) {
          return _GeoFenceLookupResult.required(id.toString());
        }
      }

      return const _GeoFenceLookupResult.none();
    } catch (_) {
      return const _GeoFenceLookupResult.unresolved(
        'Unable to verify geo-fence settings for your shift. Please check network and try again.',
      );
    }
  }

  static String? _extractLocationStatus(
    dynamic data,
    Map<String, dynamic> body,
  ) {
    if (data is Map<String, dynamic>) {
      final direct = data['locationStatus'] ?? data['LocationStatus'];
      if (direct != null && direct.toString().trim().isNotEmpty) {
        return direct.toString().trim();
      }
    }

    final top = body['locationStatus'] ?? body['LocationStatus'];
    if (top != null && top.toString().trim().isNotEmpty) {
      return top.toString().trim();
    }
    return null;
  }

  static bool _isDeniedGeoStatus(String? status) {
    if (status == null || status.trim().isEmpty) return false;
    final normalized = status.toLowerCase().replaceAll('-', '_').trim();
    return normalized == 'outside' ||
        normalized == 'out_of_range' ||
        normalized == 'outside_geofence' ||
        normalized == 'out_of_geofence' ||
        normalized == 'violation' ||
        normalized == 'denied';
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  // ── General attendance queries (unchanged from original) ─────────────────

  static Future<Map<String, dynamic>?> getTodayAttendance(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/today'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) return null;
    return _safeDecode(response.body);
  }

  static Future<String?> getEmployeeShiftId(
    String token,
    String employeeId,
  ) async {
    // Use only the employee-specific shift endpoint. Falling back to an
    // arbitrary org shift can send attendance against the wrong shift.
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

    return null;
  }

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
    return {
      'data': [],
      'totalCount': 0,
      'page': pageNumber,
      'pageSize': pageSize,
    };
  }

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
          return data.whereType<Map<String, dynamic>>().toList();
        }
      }
    } catch (_) {}
    return [];
  }

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

  // ── Shift-swap methods (unchanged from original) ─────────────────────────

  static Future<AttendanceActionResult> createShiftSwapRequest(
    String token, {
    required String employeeId,
    String? currentShiftId,
    required String requestedShiftId,
    String? reason,
  }) async {
    final body = jsonEncode({
      'employeeId': employeeId,
      'currentShiftId': (currentShiftId ?? '').trim().isEmpty
          ? null
          : currentShiftId,
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
        message:
            (payload['message'] ??
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
        message:
            (payload['message'] ??
                    (ok
                        ? 'Shift swap request processed successfully.'
                        : 'Failed to process shift swap request.'))
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

  // ── Utility ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _safeDecode(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

class _LocationCheckResult {
  final bool granted;
  final String errorMessage;
  const _LocationCheckResult({
    required this.granted,
    required this.errorMessage,
  });
}

class _GeoFenceLookupResult {
  final bool resolved;
  final bool requiresGeoFence;
  final String? geoFenceId;
  final String errorMessage;

  const _GeoFenceLookupResult._({
    required this.resolved,
    required this.requiresGeoFence,
    required this.geoFenceId,
    required this.errorMessage,
  });

  const _GeoFenceLookupResult.none()
    : this._(
        resolved: true,
        requiresGeoFence: false,
        geoFenceId: null,
        errorMessage: '',
      );

  const _GeoFenceLookupResult.required(String geoFenceId)
    : this._(
        resolved: true,
        requiresGeoFence: true,
        geoFenceId: geoFenceId,
        errorMessage: '',
      );

  const _GeoFenceLookupResult.unresolved(String message)
    : this._(
        resolved: false,
        requiresGeoFence: false,
        geoFenceId: null,
        errorMessage: message,
      );
}

class _GeoFenceDetails {
  final double centerLatitude;
  final double centerLongitude;
  final double radiusMeters;

  const _GeoFenceDetails({
    required this.centerLatitude,
    required this.centerLongitude,
    required this.radiusMeters,
  });
}

class _GeoFenceRangeCheckResult {
  final bool allowed;
  final String message;

  const _GeoFenceRangeCheckResult({
    required this.allowed,
    required this.message,
  });
}

class _GeoClockContext {
  final String faceDescriptor;
  final double confidenceScore;
  final double distanceScore;
  final String matchResult;

  const _GeoClockContext({
    required this.faceDescriptor,
    required this.confidenceScore,
    required this.distanceScore,
    required this.matchResult,
  });

  factory _GeoClockContext.fromFaceResult(FaceVerificationResult result) {
    return _GeoClockContext(
      faceDescriptor: result.descriptorJson ?? '[]',
      confidenceScore: result.confidenceScore ?? 0,
      distanceScore: result.distanceScore ?? 1,
      matchResult: result.matchResult,
    );
  }
}

// import 'dart:convert';
// import 'package:http/http.dart' as http;
// import 'package:geolocator/geolocator.dart';

// class AttendanceActionResult {
//   final bool success;
//   final String message;

//   const AttendanceActionResult({required this.success, required this.message});
// }

// class ShiftInfo {
//   final String shiftId;
//   final String shiftName;

//   const ShiftInfo({required this.shiftId, required this.shiftName});

//   factory ShiftInfo.fromJson(Map<String, dynamic> json) {
//     return ShiftInfo(
//       shiftId: (json['shiftId'] ?? json['ShiftId'] ?? json['id'] ?? '').toString(),
//       shiftName: (json['shiftName'] ?? json['ShiftName'] ?? json['name'] ?? 'Shift')
//           .toString(),
//     );
//   }
// }

// class ShiftSwapRequestItem {
//   final String requestId;
//   final String employeeId;
//   final String employeeName;
//   final String? currentShiftId;
//   final String currentShiftName;
//   final String requestedShiftId;
//   final String requestedShiftName;
//   final String reason;
//   final String status;
//   final DateTime? requestDate;
//   final DateTime? submittedAt;

//   const ShiftSwapRequestItem({
//     required this.requestId,
//     required this.employeeId,
//     required this.employeeName,
//     required this.currentShiftId,
//     required this.currentShiftName,
//     required this.requestedShiftId,
//     required this.requestedShiftName,
//     required this.reason,
//     required this.status,
//     required this.requestDate,
//     required this.submittedAt,
//   });

//   factory ShiftSwapRequestItem.fromJson(Map<String, dynamic> json) {
//     DateTime? parseAnyDate(dynamic raw) {
//       if (raw == null) return null;
//       return DateTime.tryParse(raw.toString())?.toLocal();
//     }

//     return ShiftSwapRequestItem(
//       requestId: (json['requestId'] ?? json['RequestId'] ?? '').toString(),
//       employeeId: (json['employeeId'] ?? json['EmployeeId'] ?? '').toString(),
//       employeeName: (json['employeeName'] ?? json['EmployeeName'] ?? '').toString(),
//       currentShiftId: (json['currentShiftId'] ?? json['CurrentShiftId'])?.toString(),
//       currentShiftName: (json['currentShiftName'] ?? json['CurrentShiftName'] ?? '')
//           .toString(),
//       requestedShiftId:
//           (json['requestedShiftId'] ?? json['RequestedShiftId'] ?? '').toString(),
//       requestedShiftName:
//           (json['requestedShiftName'] ?? json['RequestedShiftName'] ?? '')
//               .toString(),
//       reason: (json['reason'] ?? json['Reason'] ?? '').toString(),
//       status: (json['status'] ?? json['Status'] ?? '').toString(),
//       requestDate: parseAnyDate(
//         json['requestDate'] ??
//             json['RequestDate'] ??
//             json['date'] ??
//             json['Date'] ??
//             json['shiftDate'] ??
//             json['ShiftDate'] ??
//             json['workDate'] ??
//             json['WorkDate'],
//       ),
//       submittedAt: parseAnyDate(
//         json['submittedAt'] ??
//             json['SubmittedAt'] ??
//             json['createdAt'] ??
//             json['CreatedAt'] ??
//             json['updatedAt'] ??
//             json['UpdatedAt'],
//       ),
//     );
//   }

//   bool get isPending => status.toLowerCase() == 'pending';
// }

// class AttendanceService {
//   static const String _apiBase =
//       'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api';
//   static const String baseUrl = '$_apiBase/Attendance';
//   static const String geoFenceBaseUrl = '$_apiBase/GeoFence';

//   static Future<AttendanceActionResult> clockIn(
//     String token,
//     String shiftId,
//   ) async {
//     return _geoClock(token: token, shiftId: shiftId, action: 'in');
//   }

//   static Future<AttendanceActionResult> clockOut(
//     String token,
//     String shiftId,
//   ) async {
//     return _geoClock(token: token, shiftId: shiftId, action: 'out');
//   }

//   static Future<AttendanceActionResult> _geoClock({
//     required String token,
//     required String shiftId,
//     required String action,
//   }) async {
//     final geoFenceId = await _getPrimaryGeoFenceIdForShift(token, shiftId);
//     if (geoFenceId == null || geoFenceId.isEmpty) {
//       return _legacyClock(token, shiftId, action);
//     }

//     final hasLocationPermission = await _ensureLocationPermission();
//     if (!hasLocationPermission) {
//       return const AttendanceActionResult(
//         success: false,
//         message:
//             'Location permission is required for geo-fence clock in/out.',
//       );
//     }

//     final position = await _getCurrentPosition();
//     if (position == null) {
//       return const AttendanceActionResult(
//         success: false,
//         message: 'Unable to fetch your current location.',
//       );
//     }

//     try {
//       final response = await http.post(
//         Uri.parse('$geoFenceBaseUrl/clock'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//         body: jsonEncode({
//           'action': action,
//           'latitude': position.latitude,
//           'longitude': position.longitude,
//           'geoFenceId': geoFenceId,
//           'matchResult': 'not_checked',
//           'notes': action == 'in'
//               ? 'Clock in from mobile app'
//               : 'Clock out from mobile app',
//           'deviceInfo': jsonEncode({'platform': 'flutter_mobile'})
//         }),
//       );

//       final body = _safeDecode(response.body);
//       final data = body['data'];
//       final bool apiSuccess = body['success'] == true;
//       final bool businessSuccess =
//           data is Map<String, dynamic> ? data['success'] == true : apiSuccess;

//       final String message =
//           (data is Map<String, dynamic> ? data['message'] as String? : null) ??
//               (body['message'] as String?) ??
//               'Unable to ${action == 'in' ? 'clock in' : 'clock out'} from mobile app.';

//       final statusOk = response.statusCode >= 200 && response.statusCode < 300;
//       if (statusOk && apiSuccess && businessSuccess) {
//         return AttendanceActionResult(success: true, message: message);
//       }

//       // Compatibility fallback for environments still using legacy endpoints.
//       if (response.statusCode == 404 || response.statusCode == 405) {
//         return _legacyClock(token, shiftId, action);
//       }

//       return AttendanceActionResult(success: false, message: message);
//     } catch (_) {
//       return _legacyClock(token, shiftId, action);
//     }
//   }

//   static Future<AttendanceActionResult> _legacyClock(
//     String token,
//     String shiftId,
//     String action,
//   ) async {
//     final endpoint = action == 'in' ? 'clock-in' : 'clock-out';
//     final response = await http.post(
//       Uri.parse('$baseUrl/$endpoint'),
//       headers: {
//         'Content-Type': 'application/json',
//         'Authorization': 'Bearer $token',
//       },
//       body: jsonEncode({
//         'action': action,
//         'location': {},
//         'notes': action == 'in'
//             ? 'Clock in from mobile'
//             : 'Clock out from mobile',
//         'shiftId': shiftId,
//       }),
//     );

//     final Map<String, dynamic> body = _safeDecode(response.body);
//     final bool apiSuccess = body['success'] == true;
//     final String message = (body['message'] as String?) ??
//         'Unable to ${action == 'in' ? 'clock in' : 'clock out'} from mobile app.';

//     return AttendanceActionResult(
//       success: response.statusCode == 200 && apiSuccess,
//       message: message,
//     );
//   }

//   static Future<bool> _ensureLocationPermission() async {
//     final serviceEnabled = await Geolocator.isLocationServiceEnabled();
//     if (!serviceEnabled) return false;

//     var permission = await Geolocator.checkPermission();
//     if (permission == LocationPermission.denied) {
//       permission = await Geolocator.requestPermission();
//     }

//     return permission == LocationPermission.always ||
//         permission == LocationPermission.whileInUse;
//   }

//   static Future<Position?> _getCurrentPosition() async {
//     try {
//       return await Geolocator.getCurrentPosition(
//         locationSettings: const LocationSettings(
//           accuracy: LocationAccuracy.high,
//           timeLimit: Duration(seconds: 10),
//         ),
//       );
//     } catch (_) {
//       return Geolocator.getLastKnownPosition();
//     }
//   }

//   static Future<String?> _getPrimaryGeoFenceIdForShift(
//     String token,
//     String shiftId,
//   ) async {
//     try {
//       final response = await http.get(
//         Uri.parse('$geoFenceBaseUrl/shift/$shiftId'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );

//       if (response.statusCode < 200 || response.statusCode >= 300) {
//         return null;
//       }

//       final payload = _safeDecode(response.body);
//       dynamic list = payload['data'];
//       if (list is! List) {
//         if (payload is List) {
//           list = payload;
//         } else {
//           return null;
//         }
//       }

//       for (final raw in list) {
//         if (raw is! Map<String, dynamic>) continue;
//         final bool isActive = (raw['isActive'] ?? raw['IsActive']) != false;
//         if (!isActive) continue;

//         final id = raw['geoFenceId'] ?? raw['GeoFenceId'];
//         if (id != null && id.toString().isNotEmpty) {
//           return id.toString();
//         }
//       }
//     } catch (_) {
//       return null;
//     }
//     return null;
//   }

//   static Future<Map<String, dynamic>?> getTodayAttendance(String token) async {
//     final response = await http.get(
//       Uri.parse('$baseUrl/today'),
//       headers: {
//         'Content-Type': 'application/json',
//         'Authorization': 'Bearer $token',
//       },
//     );

//     if (response.statusCode != 200) {
//       return null;
//     }

//     return _safeDecode(response.body);
//   }

//   /// Fetch the employee's currently assigned shift via
//   /// GET /api/Attendance/CurrentShift/{employeeId}
//   static Future<String?> getEmployeeShiftId(
//     String token,
//     String employeeId,
//   ) async {
//     // 1) Try the employee-specific shift endpoint
//     try {
//       final response = await http.get(
//         Uri.parse('$baseUrl/CurrentShift/$employeeId'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );

//       if (response.statusCode == 200) {
//         final body = _safeDecode(response.body);
//         final data = body['data'];
//         if (data is Map<String, dynamic>) {
//           final id =
//               data['shiftId'] ?? data['ShiftId'] ?? data['id'] ?? data['Id'];
//           if (id != null && id.toString().isNotEmpty) {
//             return id.toString();
//           }
//         }
//       }
//     } catch (_) {}

//     // 2) Fallback: fetch all org shifts and use the first one
//     try {
//       final res = await http.get(
//         Uri.parse('$baseUrl/shifts'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (res.statusCode == 200) {
//         final body = _safeDecode(res.body);
//         final data = body['data'];
//         if (data is List && data.isNotEmpty) {
//           final first = data[0];
//           if (first is Map<String, dynamic>) {
//             final id =
//                 first['shiftId'] ?? first['ShiftId'] ?? first['id'] ?? first['Id'];
//             if (id != null && id.toString().isNotEmpty) {
//               return id.toString();
//             }
//           }
//         }
//       }
//     } catch (_) {}

//     return null;
//   }

//   static Map<String, dynamic> _safeDecode(String source) {
//     try {
//       final decoded = jsonDecode(source);
//       if (decoded is Map<String, dynamic>) {
//         return decoded;
//       }
//     } catch (_) {
//       // Return empty map so callers can handle a malformed payload gracefully.
//     }
//     return <String, dynamic>{};
//   }

//   /// Fetch attendance records for a date range.
//   /// Tries /api/Attendance/range?startDate=...&endDate=...
//   static Future<List<Map<String, dynamic>>> getAttendanceRange(
//     String token,
//     String startDate,
//     String endDate,
//   ) async {
//     try {
//       final response = await http.get(
//         Uri.parse('$baseUrl/range?startDate=$startDate&endDate=$endDate'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (response.statusCode == 200) {
//         final body = _safeDecode(response.body);
//         final data = body['data'];
//         if (data is List) {
//           return data
//               .whereType<Map<String, dynamic>>()
//               .toList();
//         }
//       }
//     } catch (_) {}
//     return [];
//   }

//   /// Fetch all attendance entries for today (multiple clock-in/out sessions).
//   /// Tries /api/Attendance/today/details
//   static Future<List<Map<String, dynamic>>> getTodayDetails(
//     String token,
//   ) async {
//     try {
//       final response = await http.get(
//         Uri.parse('$baseUrl/today/details'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (response.statusCode == 200) {
//         final body = _safeDecode(response.body);
//         final data = body['data'];
//         if (data is List) {
//           return data.whereType<Map<String, dynamic>>().toList();
//         }
//       }
//     } catch (_) {}
//     return [];
//   }

//   /// Fetch paginated employee attendance sessions using EmployeeAllAttendance API.
//   /// Returns { 'data': [...], 'totalCount': int, 'page': int, 'pageSize': int }
//   static Future<Map<String, dynamic>> getEmployeeAllAttendance(
//     String token, {
//     required String startDate,
//     required String endDate,
//     int pageNumber = 1,
//     int pageSize = 10,
//   }) async {
//     try {
//       final uri = Uri.parse(
//         '$baseUrl/EmployeeAllAttendance'
//         '?startDate=$startDate&endDate=$endDate'
//         '&pageNumber=$pageNumber&pageSize=$pageSize',
//       );
//       final response = await http.get(
//         uri,
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (response.statusCode == 200) {
//         final body = _safeDecode(response.body);
//         final outerData = body['data'];
//         if (outerData is Map<String, dynamic>) {
//           return outerData;
//         }
//       }
//     } catch (_) {}
//     return {'data': [], 'totalCount': 0, 'page': pageNumber, 'pageSize': pageSize};
//   }

//   static Future<List<ShiftInfo>> getShifts(String token) async {
//     try {
//       final res = await http.get(
//         Uri.parse('$baseUrl/shifts'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (res.statusCode != 200) return [];
//       final body = _safeDecode(res.body);
//       final data = body['data'];
//       if (data is! List) return [];
//       return data
//           .whereType<Map<String, dynamic>>()
//           .map(ShiftInfo.fromJson)
//           .where((e) => e.shiftId.trim().isNotEmpty)
//           .toList();
//     } catch (_) {
//       return [];
//     }
//   }

//   static Future<AttendanceActionResult> createShiftSwapRequest(
//     String token, {
//     required String employeeId,
//     String? currentShiftId,
//     required String requestedShiftId,
//     String? reason,
//   }) async {
//     final body = jsonEncode({
//       'employeeId': employeeId,
//       'currentShiftId': (currentShiftId ?? '').trim().isEmpty ? null : currentShiftId,
//       'requestedShiftId': requestedShiftId,
//       'reason': (reason ?? '').trim(),
//     });
//     try {
//       final res = await http.post(
//         Uri.parse('$baseUrl/shiftswap'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//         body: body,
//       );
//       final payload = _safeDecode(res.body);
//       final statusOk = res.statusCode >= 200 && res.statusCode < 300;
//       final apiSuccess = payload['success'];
//       final ok = statusOk && (apiSuccess == null || apiSuccess == true);
//       return AttendanceActionResult(
//         success: ok,
//         message: (payload['message'] ??
//                 (ok
//                     ? 'Shift swap request created successfully.'
//                     : 'Failed to create shift swap request.'))
//             .toString(),
//       );
//     } catch (_) {
//       return const AttendanceActionResult(
//         success: false,
//         message: 'Network error while creating shift swap request.',
//       );
//     }
//   }

//   static Future<AttendanceActionResult> approveShiftSwapRequest(
//     String token, {
//     required String requestId,
//     required String approvedBy,
//     required bool isApproved,
//     String? rejectionReason,
//   }) async {
//     final body = jsonEncode({
//       'requestId': requestId,
//       'approvedBy': approvedBy,
//       'isApproved': isApproved,
//       'rejectionReason': (rejectionReason ?? '').trim(),
//     });
//     try {
//       final res = await http.post(
//         Uri.parse('$baseUrl/shiftswap/approve'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//         body: body,
//       );
//       final payload = _safeDecode(res.body);
//       final statusOk = res.statusCode >= 200 && res.statusCode < 300;
//       final apiSuccess = payload['success'];
//       final ok = statusOk && (apiSuccess == null || apiSuccess == true);
//       return AttendanceActionResult(
//         success: ok,
//         message: (payload['message'] ??
//                 (ok ? 'Shift swap request processed successfully.' : 'Failed to process shift swap request.'))
//             .toString(),
//       );
//     } catch (_) {
//       return const AttendanceActionResult(
//         success: false,
//         message: 'Network error while processing shift swap request.',
//       );
//     }
//   }

//   static Future<List<ShiftSwapRequestItem>> getPendingShiftSwapRequests(
//     String token,
//   ) async {
//     try {
//       final res = await http.get(
//         Uri.parse('$baseUrl/shiftswap/pending'),
//         headers: {
//           'Content-Type': 'application/json',
//           'Authorization': 'Bearer $token',
//         },
//       );
//       if (res.statusCode != 200) return [];
//       final payload = _safeDecode(res.body);
//       if (payload['success'] != true) return [];
//       final data = payload['data'];
//       if (data is! List) return [];
//       return data
//           .whereType<Map<String, dynamic>>()
//           .map(ShiftSwapRequestItem.fromJson)
//           .where((e) => e.isPending)
//           .toList();
//     } catch (_) {
//       return [];
//     }
//   }

//   static Future<List<ShiftSwapRequestItem>> getShiftSwapRequestsByEmployee(
//     String token,
//     String employeeId,
//   ) async {
//     final urls = [
//       '$baseUrl/shiftswap/eemployeeShifts/$employeeId',
//       '$baseUrl/shiftswap/employeeShifts/$employeeId',
//     ];
//     for (final url in urls) {
//       try {
//         final res = await http.get(
//           Uri.parse(url),
//           headers: {
//             'Content-Type': 'application/json',
//             'Authorization': 'Bearer $token',
//           },
//         );
//         if (res.statusCode != 200) continue;
//         final payload = _safeDecode(res.body);
//         if (payload['success'] != true) continue;
//         final data = payload['data'];
//         if (data is! List) continue;
//         return data
//             .whereType<Map<String, dynamic>>()
//             .map(ShiftSwapRequestItem.fromJson)
//             .toList();
//       } catch (_) {
//         continue;
//       }
//     }
//     return [];
//   }
// }
