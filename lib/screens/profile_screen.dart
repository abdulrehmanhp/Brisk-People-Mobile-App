import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _firstName = '';
  String _lastName = '';
  String _email = '';
  String _role = '';
  String _organization = '';
  final TextEditingController _announcementTitleController =
      TextEditingController();
  final TextEditingController _announcementBodyController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadAnnouncementDraft();
  }

  @override
  void dispose() {
    _announcementTitleController.dispose();
    _announcementBodyController.dispose();
    super.dispose();
  }

  Future<void> _loadUserInfo() async {
    final info = await AuthService.getUserInfo();
    if (mounted) {
      setState(() {
        _firstName = info['firstName'] ?? '';
        _lastName = info['lastName'] ?? '';
        _email = info['email'] ?? '';
        _role = info['role'] ?? '';
        _organization = info['organization'] ?? '';
      });
    }
  }

  Future<void> _loadAnnouncementDraft() async {
    final prefs = await SharedPreferences.getInstance();
    _announcementTitleController.text =
        prefs.getString('announcement_title') ?? 'Office closed on 23 March';
    _announcementBodyController.text =
        prefs.getString('announcement_body') ??
        'Public Holiday observation. Enjoy your day off!';
  }

  bool get _isSuperAdmin {
    final role = _role.toLowerCase();
    return role == 'super admin' ||
        role.contains('superadmin') ||
        role.contains('super admin');
  }

  Future<void> _saveAnnouncement() async {
    final title = _announcementTitleController.text.trim();
    final body = _announcementBodyController.text.trim();
    if (title.isEmpty || body.isEmpty) {
      _showTopMessage('Title and body are required.', success: false);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('announcement_title', title);
    await prefs.setString('announcement_body', body);
    _showTopMessage('Announcement updated successfully.');
  }

  void _showTopMessage(String message, {bool success = true}) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final screenWidth = MediaQuery.of(ctx).size.width;
        final toastWidth = screenWidth > 440 ? 360.0 : (screenWidth - 24);
        return Positioned(
          top: MediaQuery.of(ctx).padding.top + 12,
          right: 12,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: toastWidth,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: success
                    ? const Color(0xFF1A8C5B)
                    : const Color(0xFFB03A2E),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 16,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    success ? Icons.check_circle_rounded : Icons.error_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 3), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = '$_firstName $_lastName'.trim();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
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
                  bottomLeft: Radius.circular(24),
                  bottomRight: Radius.circular(24),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: Column(
                    children: [
                      const Text('Profile',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 24),
                      CircleAvatar(
                        radius: 40,
                        backgroundColor: Colors.white24,
                        child: Text(
                          _getInitials(name),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(name.isEmpty ? 'Employee' : name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(_role.isEmpty ? 'Role' : _role,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Info cards
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _buildInfoTile(Icons.email, 'Email', _email),
                  _buildInfoTile(Icons.business, 'Organization', _organization),
                  _buildInfoTile(Icons.badge, 'Role', _role),
                  if (_isSuperAdmin) ...[
                    const SizedBox(height: 8),
                    _buildAnnouncementEditor(),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await AuthService.logout();
                        if (context.mounted) {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const LoginScreen()),
                            (route) => false,
                          );
                        }
                      },
                      icon: const Icon(Icons.logout, color: Colors.white),
                      label: const Text('Logout',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE74C3C),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
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

  Widget _buildInfoTile(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF2563EB), size: 22),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value.isEmpty ? '—' : value,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnnouncementEditor() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD8E2F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF3B7DED), Color(0xFF1D4FD7)],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.campaign_rounded, color: Colors.white),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Announcement Studio (Super Admin)',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _announcementTitleController,
            onChanged: (_) {
              if (mounted) setState(() {});
            },
            decoration: InputDecoration(
              labelText: 'Announcement title',
              filled: true,
              fillColor: const Color(0xFFF6F9FF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _announcementBodyController,
            onChanged: (_) {
              if (mounted) setState(() {});
            },
            minLines: 3,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: 'Announcement body',
              filled: true,
              fillColor: const Color(0xFFF6F9FF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFD),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2EAF6)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Preview',
                  style: TextStyle(
                    color: Color(0xFF647994),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _announcementTitleController.text.trim().isEmpty
                      ? 'Announcement title'
                      : _announcementTitleController.text.trim(),
                  style: const TextStyle(
                    color: Color(0xFF0B132B),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _announcementBodyController.text.trim().isEmpty
                      ? 'Announcement body'
                      : _announcementBodyController.text.trim(),
                  style: const TextStyle(
                    color: Color(0xFF5D738E),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saveAnnouncement,
              icon: const Icon(Icons.save_rounded, color: Colors.white),
              label: const Text(
                'Save Announcement',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}
