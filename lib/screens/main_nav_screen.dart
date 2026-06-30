// import 'package:flutter/material.dart';
// import 'home_screen.dart';
// import 'leave_screen.dart';
// import 'payroll_screen.dart';
// import 'profile_screen.dart';

// class MainNavScreen extends StatefulWidget {
//   const MainNavScreen({super.key});

//   @override
//   State<MainNavScreen> createState() => _MainNavScreenState();
// }

// class _MainNavScreenState extends State<MainNavScreen> {
//   int _currentIndex = 0;
//   final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

//   late final List<Widget> _screens;

//   @override
//   void initState() {
//     super.initState();
//     _screens = [
//       HomeScreen(
//         key: _homeKey,
//         onClockAction: _handleClockAction,
//         onClockStatusChanged: () => setState(() {}),
//       ),
//       const LeaveScreen(),
//       const SizedBox.shrink(), // Placeholder for center button
//       const PayrollScreen(),
//       const ProfileScreen(),
//     ];
//   }

//   void _handleClockAction() {
//     _homeKey.currentState?.handleAttendance();
//   }

//   void _onTabTapped(int index) {
//     if (index == 2) {
//       // Center clock button - trigger clock in/out
//       _handleClockAction();
//       // Switch to home tab to show the result
//       setState(() => _currentIndex = 0);
//       return;
//     }
//     setState(() => _currentIndex = index);
//   }

//   @override
//   Widget build(BuildContext context) {
//     final homeState = _homeKey.currentState;
//     final isCheckedIn = homeState?.isCheckedIn ?? false;

//     return Scaffold(
//       body: IndexedStack(
//         index: _currentIndex == 2 ? 0 : _currentIndex,
//         children: _screens,
//       ),
//       bottomNavigationBar: _buildBottomNav(isCheckedIn),
//       floatingActionButton: _buildCenterButton(isCheckedIn),
//       floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
//     );
//   }

//   Widget _buildCenterButton(bool isCheckedIn) {
//     return GestureDetector(
//       onTap: () => _onTabTapped(2),
//       child: Container(
//         width: 56,
//         height: 56,
//         decoration: BoxDecoration(
//           gradient: const LinearGradient(
//             begin: Alignment.topLeft,
//             end: Alignment.bottomRight,
//             colors: [Color(0xFF3B7DED), Color(0xFF2563EB)],
//           ),
//           shape: BoxShape.circle,
//           boxShadow: [
//             BoxShadow(
//               color: const Color(0xFF2563EB).withValues(alpha: 0.3),
//               blurRadius: 12,
//               offset: const Offset(0, 4),
//             ),
//           ],
//         ),
//         child: const Icon(Icons.access_time_filled, color: Colors.white, size: 26),
//       ),
//     );
//   }

//   Widget _buildBottomNav(bool isCheckedIn) {
//     return BottomAppBar(
//       shape: const CircularNotchedRectangle(),
//       notchMargin: 8,
//       color: Colors.white,
//       elevation: 12,
//       child: SizedBox(
//         height: 60,
//         child: Row(
//           mainAxisAlignment: MainAxisAlignment.spaceAround,
//           children: [
//             _buildNavItem(Icons.home, 'Home', 0),
//             _buildNavItem(Icons.calendar_month, 'Leave', 1),
//             _buildClockLabel(),
//             _buildNavItem(Icons.receipt_long, 'Payroll', 3),
//             _buildNavItem(Icons.person, 'Profile', 4),
//           ],
//         ),
//       ),
//     );
//   }

//   Widget _buildClockLabel() {
//     final homeState = _homeKey.currentState;
//     final isCheckedIn = homeState?.isCheckedIn ?? false;
//     return SizedBox(
//       width: 56,
//       child: Column(
//         mainAxisSize: MainAxisSize.min,
//         mainAxisAlignment: MainAxisAlignment.end,
//         children: [
//           const SizedBox(height: 28),
//           Text(
//             isCheckedIn ? 'Clock Out' : 'Clock In',
//             style: TextStyle(
//               color: Colors.grey.shade500,
//               fontSize: 11,
//             ),
//           ),
//         ],
//       ),
//     );
//   }

//   Widget _buildNavItem(IconData icon, String label, int index) {
//     final isSelected = _currentIndex == index;
//     return GestureDetector(
//       onTap: () => _onTabTapped(index),
//       behavior: HitTestBehavior.opaque,
//       child: SizedBox(
//         width: 64,
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           mainAxisAlignment: MainAxisAlignment.center,
//           children: [
//             Icon(icon,
//                 color: isSelected
//                     ? const Color(0xFF2563EB)
//                     : Colors.grey.shade400,
//                 size: 24),
//             const SizedBox(height: 2),
//             Text(label,
//                 style: TextStyle(
//                     color: isSelected
//                         ? const Color(0xFF2563EB)
//                         : Colors.grey.shade400,
//                     fontSize: 11,
//                     fontWeight:
//                         isSelected ? FontWeight.w600 : FontWeight.normal)),
//             if (isSelected)
//               Container(
//                 margin: const EdgeInsets.only(top: 2),
//                 width: 4,
//                 height: 4,
//                 decoration: const BoxDecoration(
//                   color: Color(0xFF2563EB),
//                   shape: BoxShape.circle,
//                 ),
//               ),
//           ],
//         ),
//       ),
//     );
//   }
// }



import 'dart:async';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import 'home_screen.dart';
import 'leave_screen.dart';
import 'payroll_screen.dart';
import 'profile_screen.dart';

/// Describes one bottom-navigation destination. Built dynamically in
/// [_MainNavScreenState] based on the logged-in user's role permissions so
/// that a tab simply does not exist for someone who has zero permissions
/// under that menu — mirroring how the web sidebar hides menu items the
/// role can't access at all.
class _NavTab {
  final String label;
  final IconData icon;
  final Widget screen;

  const _NavTab({required this.label, required this.icon, required this.screen});
}

class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();

  // Fail-closed until permissions resolve from cache/API.
  bool _canSeeLeaveTab = false;
  bool _canSeePayrollTab = false;
  bool _canClock = false;
  bool _permissionsResolved = false;

  late List<_NavTab> _tabs;
  StreamSubscription<int>? _permissionSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rebuildTabs();
    _loadPermissionFlags();
    AuthService.startPermissionListener();
    _permissionSubscription = PermissionService.onChanged.listen((_) {
      _loadPermissionFlags(refreshFromApi: false);
    });
  }

  @override
  void dispose() {
    _permissionSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPermissionFlags();
      AuthService.startPermissionListener();
    }
  }

  Future<void> _loadPermissionFlags({bool refreshFromApi = true}) async {
    if (refreshFromApi) {
      await AuthService.refreshPermissions();
    }

    final results = await Future.wait([
      PermissionService.hasMenuParentPermission('Leave Management'),
      PermissionService.hasMenuParentPermission('Payroll').then((byMenu) async {
        if (byMenu) return true;
        return PermissionService.hasAnyPermissionByActionKeys(
          PermissionKeys.payrollNavActionKeys,
        );
      }),
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockIn),
      PermissionService.hasPermissionByActionKey(PermissionKeys.clockOut),
    ]);

    if (!mounted) return;
    setState(() {
      _canSeeLeaveTab = results[0];
      _canSeePayrollTab = results[1];
      _canClock = results[2] || results[3];
      _permissionsResolved = true;
      _rebuildTabs();
      if (_currentIndex >= _tabs.length) {
        _currentIndex = 0;
      }
    });

    _homeKey.currentState?.reloadPermissions();
  }

  void _rebuildTabs() {
    final pv = PermissionService.version;
    _tabs = [
      _NavTab(
        label: 'Home',
        icon: Icons.home,
        screen: HomeScreen(
          key: _homeKey,
          onClockAction: _handleClockAction,
          onClockStatusChanged: () => setState(() {}),
        ),
      ),
      if (_canSeeLeaveTab)
        _NavTab(
          label: 'Leave',
          icon: Icons.calendar_month,
          screen: LeaveScreen(key: ValueKey('leave-$pv')),
        ),
      if (_canSeePayrollTab)
        _NavTab(
          label: 'Payroll',
          icon: Icons.receipt_long,
          screen: PayrollScreen(key: ValueKey('payroll-$pv')),
        ),
      _NavTab(
        label: 'Profile',
        icon: Icons.person,
        screen: ProfileScreen(key: ValueKey('profile-$pv')),
      ),
    ];
  }

  void _handleClockAction() {
    _homeKey.currentState?.handleAttendance();
  }

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
  }

  void _onClockTapped() {
    _handleClockAction();
    // Switch to the Home tab (always index 0) to show the result.
    setState(() => _currentIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsResolved) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final homeState = _homeKey.currentState;
    final isCheckedIn = homeState?.isCheckedIn ?? false;

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs.map((t) => t.screen).toList(),
      ),
      bottomNavigationBar: _buildBottomNav(isCheckedIn),
      floatingActionButton: _canClock ? _buildCenterButton(isCheckedIn) : null,
      floatingActionButtonLocation: _canClock
          ? FloatingActionButtonLocation.centerDocked
          : null,
    );
  }

  Widget _buildCenterButton(bool isCheckedIn) {
    return GestureDetector(
      onTap: _onClockTapped,
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
    final items = <Widget>[];

    // Left: Home, then Leave (when permitted).
    items.add(_buildNavItem(_tabs[0].icon, _tabs[0].label, 0));

    final leaveIndex = _tabIndexForLabel('Leave');
    if (leaveIndex >= 0) {
      items.add(_buildNavItem(
        _tabs[leaveIndex].icon,
        _tabs[leaveIndex].label,
        leaveIndex,
      ));
    }

    // Center: clock label sits under the FAB notch.
    if (_canClock) {
      items.add(_buildClockLabel(isCheckedIn));
    }

    // Right: Payroll (when permitted), then Profile.
    final payrollIndex = _tabIndexForLabel('Payroll');
    if (payrollIndex >= 0) {
      items.add(_buildNavItem(
        _tabs[payrollIndex].icon,
        _tabs[payrollIndex].label,
        payrollIndex,
      ));
    }

    final profileIndex = _tabs.length - 1;
    items.add(_buildNavItem(
      _tabs[profileIndex].icon,
      _tabs[profileIndex].label,
      profileIndex,
    ));

    return BottomAppBar(
      shape: _canClock ? const CircularNotchedRectangle() : null,
      notchMargin: 8,
      color: Colors.white,
      elevation: 12,
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: items,
        ),
      ),
    );
  }

  int _tabIndexForLabel(String label) {
    return _tabs.indexWhere((t) => t.label == label);
  }

  Widget _buildClockLabel(bool isCheckedIn) {
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