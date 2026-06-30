import 'dart:convert';

/// Lightweight JWT payload reader — no signature verification (client-side
/// claim extraction only; the server still validates the token).
class JwtUtils {
  JwtUtils._();

  static String? getClaim(String token, String claimName) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;

      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decoded);
      if (map is! Map<String, dynamic>) return null;

      if (map.containsKey(claimName)) {
        return map[claimName]?.toString();
      }

      final target = claimName.toLowerCase();
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() == target ||
            entry.key.toLowerCase().endsWith('/$target')) {
          return entry.value?.toString();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
