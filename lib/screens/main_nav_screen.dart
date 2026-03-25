import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'leave_screen.dart';
import 'payroll_screen.dart';
import 'profile_screen.dart';

class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  int _currentIndex = 0;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(
        key: _homeKey,
        onClockAction: _handleClockAction,
        onClockStatusChanged: () => setState(() {}),
      ),
      const LeaveScreen(),
      const SizedBox.shrink(), // Placeholder for center button
      const PayrollScreen(),
      const ProfileScreen(),
    ];
  }

  void _handleClockAction() {
    _homeKey.currentState?.handleAttendance();
  }

  void _onTabTapped(int index) {
    if (index == 2) {
      // Center clock button - trigger clock in/out
      _handleClockAction();
      // Switch to home tab to show the result
      setState(() => _currentIndex = 0);
      return;
    }
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final homeState = _homeKey.currentState;
    final isCheckedIn = homeState?.isCheckedIn ?? false;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex == 2 ? 0 : _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: _buildBottomNav(isCheckedIn),
      floatingActionButton: _buildCenterButton(isCheckedIn),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
    );
  }

  Widget _buildCenterButton(bool isCheckedIn) {
    return GestureDetector(
      onTap: () => _onTabTapped(2),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3B7DED), Color(0xFF2563EB)],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(Icons.access_time_filled, color: Colors.white, size: 26),
      ),
    );
  }

  Widget _buildBottomNav(bool isCheckedIn) {
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 8,
      color: Colors.white,
      elevation: 12,
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(Icons.home, 'Home', 0),
            _buildNavItem(Icons.calendar_month, 'Leave', 1),
            _buildClockLabel(),
            _buildNavItem(Icons.receipt_long, 'Payroll', 3),
            _buildNavItem(Icons.person, 'Profile', 4),
          ],
        ),
      ),
    );
  }

  Widget _buildClockLabel() {
    final homeState = _homeKey.currentState;
    final isCheckedIn = homeState?.isCheckedIn ?? false;
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const SizedBox(height: 28),
          Text(
            isCheckedIn ? 'Clock Out' : 'Clock In',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => _onTabTapped(index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                color: isSelected
                    ? const Color(0xFF2563EB)
                    : Colors.grey.shade400,
                size: 24),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: isSelected
                        ? const Color(0xFF2563EB)
                        : Colors.grey.shade400,
                    fontSize: 11,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal)),
            if (isSelected)
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: Color(0xFF2563EB),
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
