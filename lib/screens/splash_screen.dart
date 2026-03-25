import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart';
import 'main_nav_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _dotController;
  int _activeDot = 0;

  @override
  void initState() {
    super.initState();

    _dotController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 600),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            setState(() => _activeDot = (_activeDot + 1) % 3);
            _dotController.forward(from: 0);
          }
        });
    _dotController.forward();

    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(seconds: 3));

    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final expiry = prefs.getString('token_expiry');

    bool isLoggedIn = false;
    if (token != null && token.isNotEmpty) {
      if (expiry != null) {
        final expiryDate = DateTime.tryParse(expiry);
        if (expiryDate != null && DateTime.now().isBefore(expiryDate)) {
          isLoggedIn = true;
        } else {
          await prefs.remove('auth_token');
          await prefs.remove('refresh_token');
          await prefs.remove('token_expiry');
        }
      } else {
        isLoggedIn = true;
      }
    }

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => isLoggedIn ? const MainNavScreen() : const LoginScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3B7DED), Color(0xFF2563EB), Color(0xFF1D4FD7)],
          ),
        ),
        child: Stack(
          children: [
            // Diagonal stripes overlay
            CustomPaint(
              size: MediaQuery.of(context).size,
              painter: _DiagonalStripesPainter(),
            ),

            // Content
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 3),

                  // Logo icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'B',
                        style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // App name
                  const Text(
                    'BriskPeople',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),

                  const SizedBox(height: 4),

                  // Subtitle
                  Text(
                    'H R M S',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.75),
                      letterSpacing: 8,
                    ),
                  ),

                  const Spacer(flex: 3),

                  // Loading dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (i) {
                      final isActive = i == _activeDot;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isActive
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.4),
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 16),

                  // Status text
                  Text(
                    'Setting up your workspace...',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Version
                  Text(
                    'v1.0.0',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagonalStripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    const spacing = 18.0;
    final maxDimension = max(size.width, size.height) * 2;

    for (double i = -maxDimension; i < maxDimension; i += spacing) {
      canvas.drawLine(
        Offset(i, 0),
        Offset(i + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
