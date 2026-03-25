import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/auth_model.dart';
import '../services/auth_service.dart';
import 'main_nav_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _rememberMe = false;
  bool _enableBiometric = false;
  final LocalAuthentication _localAuth = LocalAuthentication();

  // All saved accounts: list of {email, password}
  List<Map<String, String>> _savedAccounts = [];
  bool _showEmailSuggestion = false;
  bool _showPasswordSuggestion = false;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString('saved_accounts');
    if (encoded != null) {
      try {
        final List<dynamic> decoded = jsonDecode(encoded);
        setState(() {
          _savedAccounts = decoded
              .map((e) => Map<String, String>.from(e as Map))
              .toList();
        });
      } catch (_) {
        // Migration from old single-account format
        final oldEmail = prefs.getString('saved_email');
        final oldPassword = prefs.getString('saved_password');
        if (oldEmail != null && oldPassword != null) {
          setState(() {
            _savedAccounts = [
              {'email': oldEmail, 'password': oldPassword},
            ];
          });
          await prefs.setString('saved_accounts', jsonEncode(_savedAccounts));
          await prefs.remove('saved_email');
          await prefs.remove('saved_password');
          await prefs.remove('remember_me');
        }
      }
    } else {
      // Migration from old single-account format
      final oldEmail = prefs.getString('saved_email');
      final oldPassword = prefs.getString('saved_password');
      if (oldEmail != null && oldPassword != null) {
        setState(() {
          _savedAccounts = [
            {'email': oldEmail, 'password': oldPassword},
          ];
        });
        await prefs.setString('saved_accounts', jsonEncode(_savedAccounts));
        await prefs.remove('saved_email');
        await prefs.remove('saved_password');
        await prefs.remove('remember_me');
      }
    }
    // Keep method async work complete; no UI state is needed here.
  }

  Future<void> _saveCredentials() async {
    if (!_rememberMe) return; // Don't touch saved accounts if not checked
    final prefs = await SharedPreferences.getInstance();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    // Remove existing entry for this email (update it)
    _savedAccounts.removeWhere((a) => a['email'] == email);
    // Add at the top (most recent first)
    _savedAccounts.insert(0, {'email': email, 'password': password});
    await prefs.setString('saved_accounts', jsonEncode(_savedAccounts));
  }

  Future<void> _saveBiometricAccount() async {
    if (!_enableBiometric) return;
    final prefs = await SharedPreferences.getInstance();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    await prefs.setString('biometric_email', email);
    await prefs.setString('biometric_password', password);
  }

  Future<void> _login() async {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await AuthService.login(
        LoginRequest(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        ),
      );
      await AuthService.saveUserInfo(response);
      await _saveCredentials();
      await _saveBiometricAccount();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainNavScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _biometricLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final bioEmail = prefs.getString('biometric_email');
    final bioPassword = prefs.getString('biometric_password');

    if (bioEmail == null || bioPassword == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Please login first and check "Enable Biometric" to set up biometric login.',
            ),
          ),
        );
      }
      return;
    }

    final account = {'email': bioEmail, 'password': bioPassword};

    try {
      final canAuth = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (!canAuth || !isDeviceSupported) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Biometric authentication is not available.'),
            ),
          );
        }
        return;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to sign in to BriskPeople',
      );

      if (authenticated) {
        setState(() => _isLoading = true);
        try {
          final response = await AuthService.login(
            LoginRequest(
              email: account['email']!,
              password: account['password']!,
            ),
          );
          await AuthService.saveUserInfo(response);
          if (mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const MainNavScreen()),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(e.toString().replaceAll('Exception: ', '')),
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _isLoading = false);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biometric authentication failed.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // ── Blue header with logo ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 60, bottom: 40),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF3B7DED),
                    Color(0xFF2563EB),
                    Color(0xFF1D4FD7),
                  ],
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(32),
                  bottomRight: Radius.circular(32),
                ),
              ),
              child: Column(
                children: [
                  // Logo
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'B',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'BriskPeople',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            // ── Form section ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Welcome text
                  const Text(
                    'Welcome Back 👋',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Sign in to your account',
                    style: TextStyle(fontSize: 15, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 28),

                  // Email field with saved credential suggestions
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        onTap: () {
                          if (_savedAccounts.isNotEmpty &&
                              _emailController.text.isEmpty) {
                            setState(() {
                              _showEmailSuggestion = true;
                              _showPasswordSuggestion = false;
                            });
                          }
                        },
                        onChanged: (val) {
                          setState(() {
                            _showEmailSuggestion =
                                _savedAccounts.isNotEmpty && val.isEmpty;
                            _showPasswordSuggestion = false;
                          });
                        },
                        decoration: InputDecoration(
                          labelText: 'Email Address',
                          labelStyle: const TextStyle(
                            color: Color(0xFF2563EB),
                            fontSize: 14,
                          ),
                          prefixIcon: const Icon(
                            Icons.alternate_email,
                            color: Color(0xFF2563EB),
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF2563EB),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                      if (_showEmailSuggestion && _savedAccounts.isNotEmpty)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF2563EB),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: _savedAccounts.map((account) {
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _emailController.text = account['email']!;
                                    _passwordController.text =
                                        account['password'] ?? '';
                                    _showEmailSuggestion = false;
                                  });
                                },
                                borderRadius: BorderRadius.circular(10),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.person_outline,
                                        size: 20,
                                        color: Color(0xFF2563EB),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              account['email']!,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF1E293B),
                                              ),
                                            ),
                                            const Text(
                                              'Saved account',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF94A3B8),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Icon(
                                        Icons.arrow_forward_ios,
                                        size: 14,
                                        color: Color(0xFF94A3B8),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Password field with saved credential suggestions
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
                        onTap: () {
                          if (_savedAccounts.isNotEmpty &&
                              _passwordController.text.isEmpty) {
                            setState(() {
                              _showPasswordSuggestion = true;
                              _showEmailSuggestion = false;
                            });
                          }
                        },
                        onChanged: (val) {
                          setState(() {
                            _showPasswordSuggestion =
                                _savedAccounts.isNotEmpty && val.isEmpty;
                            _showEmailSuggestion = false;
                          });
                        },
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: const TextStyle(
                            color: Color(0xFF2563EB),
                            fontSize: 14,
                          ),
                          prefixIcon: const Icon(
                            Icons.lock_outline,
                            color: Color(0xFF2563EB),
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: const Color(0xFF94A3B8),
                            ),
                            onPressed: () {
                              setState(
                                () => _obscurePassword = !_obscurePassword,
                              );
                            },
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF2563EB),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                      if (_showPasswordSuggestion && _savedAccounts.isNotEmpty)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF2563EB),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: _savedAccounts.map((account) {
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _emailController.text = account['email']!;
                                    _passwordController.text =
                                        account['password'] ?? '';
                                    _showPasswordSuggestion = false;
                                  });
                                },
                                borderRadius: BorderRadius.circular(10),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.key,
                                        size: 20,
                                        color: Color(0xFF2563EB),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              account['email']!,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF1E293B),
                                              ),
                                            ),
                                            const Text(
                                              'Use saved password',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF94A3B8),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Icon(
                                        Icons.arrow_forward_ios,
                                        size: 14,
                                        color: Color(0xFF94A3B8),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Remember me + Enable biometric row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _rememberMe,
                              activeColor: const Color(0xFF2563EB),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                              onChanged: (v) {
                                setState(() => _rememberMe = v ?? false);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Remember me',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _enableBiometric,
                              activeColor: const Color(0xFF2563EB),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                              onChanged: (v) {
                                setState(() => _enableBiometric = v ?? false);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Enable Biometric',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Sign In button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        disabledBackgroundColor: const Color(0xFF93B4F5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 0,
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Sign In',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Icon(
                                  Icons.arrow_forward,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── or divider ──
                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'or',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey.shade300)),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Biometric buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Fingerprint
                      GestureDetector(
                        onTap: _biometricLogin,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: const Icon(
                            Icons.fingerprint,
                            size: 30,
                            color: Color(0xFF2563EB),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Face ID
                      GestureDetector(
                        onTap: _biometricLogin,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: const Icon(
                            Icons.face,
                            size: 30,
                            color: Color(0xFF2563EB),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Use biometric login',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Bottom text
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Don't have an account?  ",
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Contact your admin to create an account.',
                              ),
                            ),
                          );
                        },
                        child: const Text(
                          'Contact Admin',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2563EB),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
