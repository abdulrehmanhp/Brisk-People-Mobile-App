import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/auth_model.dart';

class AuthService {
  static const String baseUrl =
      'https://hrmsapplicationcodifiedlabs-production.up.railway.app/api/Auth';        

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
      return authResponse;
    } else {
      throw Exception(data['message'] ?? 'Login failed');
    }
  }

  // ── TOKEN STORAGE ──
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
    };
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
  }
}
