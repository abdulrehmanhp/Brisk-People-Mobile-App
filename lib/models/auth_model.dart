class LoginRequest {
  final String email;
  final String password;

  const LoginRequest({required this.email, required this.password});

  factory LoginRequest.fromJson(Map<String, dynamic> json) =>
      LoginRequest(email: json['email'], password: json['password']);

  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class AuthResponse {
  final String? userId;
  final String email;
  final String firstName;
  final String lastName;
  final String roleName;
  final String organizationName;
  final String? profileImage;
  final String token;
  final String refreshToken;
  final DateTime tokenExpiration;

  AuthResponse({
    this.userId,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.roleName,
    required this.organizationName,
    this.profileImage,
    required this.token,
    required this.refreshToken,
    required this.tokenExpiration,
  });

  factory AuthResponse.fromJson(Map<String, dynamic> json) => AuthResponse(
    userId: json['userId'],
    email: json['email'],
    firstName: json['firstName'],
    lastName: json['lastName'],
    roleName: json['roleName'],
    organizationName: json['organizationName'],
    profileImage:
        (json['profileImage'] ??
                json['profilePictureUrl'] ??
                json['profileurl'])
            ?.toString(),
    token: json['token'],
    refreshToken: json['refreshToken'],
    tokenExpiration:
        DateTime.tryParse(json['tokenExpiration'] ?? '') ?? DateTime.now(),
  );
}
