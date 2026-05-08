import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/auth_model.dart';
import 'permission_service.dart';

class AuthService {
  static const String baseUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Auth';
  static const String uploadsBaseUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/uploads';
  static const String _profileUrlKeyPrefix = 'user_profile_url_';
  static const String _profileTsKeyPrefix = 'user_profile_url_ts_';

  static Future<AuthResponse> login(LoginRequest request) async {
    final response = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(request.toJson()),
    );

    final data = jsonDecode(response.body);

    if (response.statusCode == 200 && data['success'] == true) {
      final authResponse = AuthResponse.fromJson(data['data']);
      await _saveToken(
        authResponse.token,
        authResponse.refreshToken,
        authResponse.tokenExpiration,
      );
      await saveUserInfo(authResponse);
      // Fetch and cache permissions post-login
      if (authResponse.userId != null && authResponse.userId!.isNotEmpty) {
        await PermissionService.fetchAndStore(authResponse.userId!);
      }
      return authResponse;
    } else {
      throw Exception(data['message'] ?? 'Login failed');
    }
  }

  // Token storage
  static Future<void> _saveToken(
    String token,
    String refreshToken,
    DateTime expiration,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('refresh_token', refreshToken);
    await prefs.setString('token_expiry', expiration.toIso8601String());
  }

  static Future<void> saveUserInfo(AuthResponse user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_first_name', user.firstName);
    await prefs.setString('user_last_name', user.lastName);
    await prefs.setString('user_email', user.email);
    await prefs.setString('user_role', user.roleName);
    await prefs.setString('user_organization', user.organizationName);
    if (user.userId != null) {
      await prefs.setString('user_id', user.userId!);
    }

    final incoming = user.profileImage?.trim() ?? '';
    final cacheKey = _profileUrlKey(user.userId, user.email);
    final cached = prefs.getString(cacheKey) ?? '';
    final finalUrl = incoming.isNotEmpty ? incoming : cached;
    await _cacheProfileUrl(finalUrl, userId: user.userId, email: user.email);
  }

  static Future<Map<String, String>> getUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'firstName': prefs.getString('user_first_name') ?? '',
      'lastName': prefs.getString('user_last_name') ?? '',
      'email': prefs.getString('user_email') ?? '',
      'role': prefs.getString('user_role') ?? '',
      'organization': prefs.getString('user_organization') ?? '',
      'userId': prefs.getString('user_id') ?? '',
      'profileUrl': prefs.getString('user_profile_url') ?? '',
    };
  }

  static Future<Map<String, dynamic>?> getCurrentUser() async {
    final token = await getToken();
    if (token == null || token.isEmpty) return null;

    final response = await http.get(
      Uri.parse('$baseUrl/me'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) return null;
    final data = body['data'];
    if (data is! Map<String, dynamic>) return null;
    return data;
  }

  static Future<String?> getProfilePictureUrl({bool refresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = await _getCachedProfileUrl(prefs);
    if (!refresh && cached.trim().isNotEmpty) {
      return cached;
    }

    final me = await getCurrentUser();
    if (me == null) return cached.trim().isEmpty ? null : cached;

    final profile =
        (me['profilePictureUrl'] ??
                me['ProfilePictureUrl'] ??
                me['profileImage'] ??
                me['profileurl'] ??
                me['photoUrl'])
            ?.toString();

    if (profile != null && profile.trim().isNotEmpty) {
      await _cacheProfileUrl(profile);
      return profile;
    }

    return cached.trim().isEmpty ? null : cached;
  }

  static Future<String?> getProfilePictureDisplayUrl({
    bool refresh = false,
  }) async {
    final raw = await getProfilePictureUrl(refresh: refresh);
    if (raw == null || raw.trim().isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final identity = await _getIdentity(prefs);
    final tsKey = _profileTsKey(identity['userId'], identity['email']);
    final ts = prefs.getInt(tsKey) ?? 0;
    if (ts == 0) return raw;

    final separator = raw.contains('?') ? '&' : '?';
    return '$raw${separator}v=$ts';
  }

  static Future<String> uploadProfilePic(File file) async {
    final token = await getToken();
    final fileBytes = await file.readAsBytes();

    Future<http.Response> sendMultipart(String fieldName) async {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$uploadsBaseUrl/files'),
      );
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      request.files.add(
        http.MultipartFile.fromBytes(
          fieldName,
          fileBytes,
          filename: 'profile.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
      final streamed = await request.send();
      return http.Response.fromStream(streamed);
    }

    dynamic decodeBody(String raw) {
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }

    String? extractUploadedUrl(dynamic body) {
      if (body is! Map<String, dynamic>) return null;
      final direct = body['url'];
      if (direct is String && direct.trim().isNotEmpty) return direct;

      final data = body['data'];
      if (data is String && data.trim().isNotEmpty) return data;
      if (data is Map<String, dynamic>) {
        final dataUrl = data['url'];
        if (dataUrl is String && dataUrl.trim().isNotEmpty) return dataUrl;
      }
      return null;
    }

    String extractErrorMessage(dynamic body, int statusCode) {
      if (body is Map<String, dynamic>) {
        final error = body['error']?.toString();
        if (error != null && error.trim().isNotEmpty) return error.trim();

        final message = body['message']?.toString();
        if (message != null && message.trim().isNotEmpty) return message.trim();

        final title = body['title']?.toString();
        if (title != null && title.trim().isNotEmpty) return title.trim();

        final errors = body['errors'];
        if (errors is Map) {
          final parts = <String>[];
          errors.forEach((_, value) {
            if (value is List && value.isNotEmpty) {
              parts.add(value.first.toString());
            } else if (value != null) {
              parts.add(value.toString());
            }
          });
          if (parts.isNotEmpty) return parts.join(' ');
        }
      }
      return 'Upload failed ($statusCode).';
    }

    var response = await sendMultipart('file');
    var body = decodeBody(response.body);

    if (response.statusCode == 400) {
      final message = extractErrorMessage(
        body,
        response.statusCode,
      ).toLowerCase();
      final suggestsAltField =
          message.contains('files') ||
          message.contains('file is required') ||
          message.contains('no file uploaded');
      if (suggestsAltField) {
        response = await sendMultipart('files');
        body = decodeBody(response.body);
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorMsg = extractErrorMessage(body, response.statusCode);
      throw Exception(errorMsg);
    }

    final uploadedUrl = extractUploadedUrl(body);
    if (uploadedUrl == null) {
      throw Exception('Upload failed: invalid server response.');
    }

    return uploadedUrl;
  }

  static Future<void> deleteUploadedFile(String fileUrl) async {
    final token = await getToken();
    final response = await http.delete(
      Uri.parse('$uploadsBaseUrl/files'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'fileUrl': fileUrl}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to delete uploaded file');
    }
  }

  static Future<void> updateProfilePictureUrl(String profileUrl) async {
    await _cacheProfileUrl(profileUrl);

    final token = await getToken();
    if (token == null || token.isEmpty) return;

    Future<http.Response> sendMultipart(
      String bearerToken,
      Map<String, dynamic>? employee,
    ) async {
      final request = http.MultipartRequest(
        'PUT',
        Uri.parse('$baseUrl/profile'),
      );
      request.headers['Authorization'] = 'Bearer $bearerToken';

      void addField(String key, Object? value) {
        if (value == null) return;
        final text = value.toString().trim();
        if (text.isEmpty || text == 'null') return;
        request.fields[key] = text;
      }

      if (employee != null) {
        addField('EmployeeNumber', employee['employeeNumber']);
        addField('FirstName', employee['firstName']);
        addField('LastName', employee['lastName']);
        addField('Email', employee['email']);
        addField('Phone', employee['phone']);
        addField('DateOfBirth', employee['dateOfBirth']);
        addField('HireDate', employee['hireDate']);
        addField('DepartmentId', employee['departmentId']);
        addField('PositionId', employee['positionId']);
        addField('BasicSalary', employee['basicSalary']);
        addField('ReportingManagerId', employee['reportingManagerId']);
        addField('WorkLocation', employee['workLocation']);
        addField('Gender', employee['gender']);
        addField(
          'MaritalStatus',
          employee['maritalstatus'] ?? employee['maritalStatus'],
        );
        addField('Nationality', employee['nationality']);

        final address = employee['address'];
        if (address is Map) {
          addField('Address', jsonEncode(address));
        }

        final emergency =
            employee['emergencycontact'] ?? employee['emergencyContact'];
        if (emergency is Map) {
          addField('EmergencyContact', jsonEncode(emergency));
        }
      }

      addField('profileurl', profileUrl);

      final streamed = await request.send();
      return http.Response.fromStream(streamed);
    }

    Map<String, dynamic>? decodeBody(String rawBody) {
      try {
        final decoded = jsonDecode(rawBody);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
      return null;
    }

    final employee = await _getEmployeeProfile(token);
    http.Response response = await sendMultipart(token, employee);
    decodeBody(response.body);

    if (response.statusCode == 401) {
      final refreshed = await _reauthenticateFromSavedAccount();
      if (refreshed) {
        final freshToken = await getToken();
        if (freshToken != null && freshToken.isNotEmpty) {
          final refreshedEmployee = await _getEmployeeProfile(freshToken);
          response = await sendMultipart(freshToken, refreshedEmployee);
          decodeBody(response.body);
        }
      }
    }
  }

  static Future<Map<String, dynamic>?> _getEmployeeProfile(
    String bearerToken,
  ) async {
    final me = await getCurrentUser();
    final userId = me?['userId']?.toString();
    if (userId == null || userId.isEmpty) return null;

    final response = await http.get(
      Uri.parse(
        'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Employee/$userId',
      ),
      headers: {
        'Authorization': 'Bearer $bearerToken',
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> &&
          body['data'] is Map<String, dynamic>) {
        return body['data'] as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> _reauthenticateFromSavedAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final savedAccountsRaw = prefs.getString('saved_accounts');
    if (savedAccountsRaw == null || savedAccountsRaw.trim().isEmpty) {
      return false;
    }

    try {
      final decoded = jsonDecode(savedAccountsRaw);
      if (decoded is! List || decoded.isEmpty) return false;

      final first = decoded.first;
      if (first is! Map<String, dynamic>) return false;

      final email = first['email']?.toString().trim() ?? '';
      final password = first['password']?.toString() ?? '';
      if (email.isEmpty || password.isEmpty) return false;

      await login(LoginRequest(email: email, password: password));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('refresh_token');
    await prefs.remove('token_expiry');
    // Clear cached permissions so next user starts clean
    await PermissionService.clear();
  }

  static String _profileUrlKey(String? userId, String? email) {
    final key = (userId ?? '').trim().isNotEmpty
        ? userId!.trim()
        : (email ?? '').trim();
    return '$_profileUrlKeyPrefix${key.isEmpty ? 'current' : key}';
  }

  static String _profileTsKey(String? userId, String? email) {
    final key = (userId ?? '').trim().isNotEmpty
        ? userId!.trim()
        : (email ?? '').trim();
    return '$_profileTsKeyPrefix${key.isEmpty ? 'current' : key}';
  }

  static Future<Map<String, String>> _getIdentity(
    SharedPreferences prefs,
  ) async {
    return {
      'userId': prefs.getString('user_id') ?? '',
      'email': prefs.getString('user_email') ?? '',
    };
  }

  static Future<void> _cacheProfileUrl(
    String url, {
    String? userId,
    String? email,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final identity = await _getIdentity(prefs);
    final resolvedUserId = userId ?? identity['userId'];
    final resolvedEmail = email ?? identity['email'];
    final key = _profileUrlKey(resolvedUserId, resolvedEmail);
    final tsKey = _profileTsKey(resolvedUserId, resolvedEmail);
    await prefs.setString('user_profile_url', url);
    await prefs.setString(key, url);
    await prefs.setInt(
      tsKey,
      url.trim().isEmpty ? 0 : DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<String> _getCachedProfileUrl(SharedPreferences prefs) async {
    final identity = await _getIdentity(prefs);
    final key = _profileUrlKey(identity['userId'], identity['email']);
    final cached = prefs.getString(key) ?? '';
    if (cached.trim().isNotEmpty) return cached;
    return prefs.getString('user_profile_url') ?? '';
  }
}
