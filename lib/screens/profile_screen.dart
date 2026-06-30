import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import 'login_screen.dart';
import 'permissions_debug_screen.dart';

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
  String _profileImageUrl = '';
  bool _isPhotoBusy = false;
  // Whether the user has permission to edit announcements — resolved via the
  // permissions API instead of hard-coding role strings.
  bool _canEditAnnouncement = false;
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
        _profileImageUrl = info['profileUrl'] ?? '';
      });
    }

    final refreshed = await AuthService.getProfilePictureDisplayUrl(
      refresh: true,
    );
    if (mounted && refreshed != null) {
      setState(() => _profileImageUrl = refreshed);
    }

    // Resolve announcement-edit permission from the permissions API.
    // The action key 'admin_dashboard' under Admin Dashboard → Admin Dashboard
    // is used by the web frontend to gate admin-only features such as editing
    // announcements. We mirror that check here instead of hard-coding roles.
    final canEdit = await PermissionService.hasPermissionByActionKey(
      PermissionKeys.adminDashboard,
    );
    if (mounted) {
      setState(() => _canEditAnnouncement = canEdit);
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

  Future<void> _uploadOrChangeProfilePicture() async {
    if (_isPhotoBusy) return;
    final wasEmpty = _profileImageUrl.trim().isEmpty;
    setState(() => _isPhotoBusy = true);

    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1800,
        maxHeight: 1800,
      );
    } on MissingPluginException {
      if (!mounted) return;
      _showTopMessage(
        'Image picker is not ready yet. Please fully restart the app and try again.',
        success: false,
      );
      return;
    } on PlatformException catch (_) {
      if (!mounted) return;

      final granted = await _requestGalleryPermission();
      if (!granted) {
        await _showGalleryPermissionDialog();
        return;
      }

      try {
        picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 1800,
          maxHeight: 1800,
        );
      } on PlatformException catch (_) {
        if (!mounted) return;
        await _showGalleryPermissionDialog();
        return;
      }
    } catch (e) {
      if (!mounted) return;
      _showTopMessage(
        'Unable to open gallery right now. Please try again.',
        success: false,
      );
      return;
    }

    try {
      if (picked == null) return;

      final selectedFile = File(picked.path);
      final uploadFile = await _prepareImageForUpload(selectedFile);
      final uploadedUrl = await AuthService.uploadProfilePic(uploadFile);
      await AuthService.updateProfilePictureUrl(uploadedUrl);
      final displayUrl = await AuthService.getProfilePictureDisplayUrl();

      if (!mounted) return;
      setState(() => _profileImageUrl = displayUrl ?? uploadedUrl);
      _showTopMessage(
        wasEmpty
            ? 'Profile picture uploaded successfully.'
            : 'Profile picture updated successfully.',
      );
    } catch (e) {
      if (!mounted) return;
      _showTopMessage(
        e.toString().replaceFirst('Exception: ', '').trim(),
        success: false,
      );
    } finally {
      if (mounted) setState(() => _isPhotoBusy = false);
    }
  }

  Future<File> _prepareImageForUpload(File selectedFile) async {
    final rawBytes = await selectedFile.readAsBytes();
    final decoded = img.decodeImage(rawBytes);

    if (decoded == null) {
      throw Exception(
        'Selected file is not a valid image. Please choose JPG or PNG.',
      );
    }

    final jpgBytes = img.encodeJpg(decoded, quality: 90);
    final tempFile = File(
      '${Directory.systemTemp.path}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await tempFile.writeAsBytes(jpgBytes, flush: true);
    return tempFile;
  }

  Future<bool> _requestGalleryPermission() async {
    if (Platform.isIOS) {
      final photos = await Permission.photos.request();
      return photos.isGranted || photos.isLimited;
    }

    if (Platform.isAndroid) {
      final photos = await Permission.photos.request();
      if (photos.isGranted || photos.isLimited) return true;

      final storage = await Permission.storage.request();
      return storage.isGranted;
    }

    return true;
  }

  Future<void> _showGalleryPermissionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Allow Photo Access'),
          content: const Text(
            'To upload a profile picture, allow gallery/photo library access. Tap Allow Access to open settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Not Now'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await openAppSettings();
              },
              child: const Text('Allow Access'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteProfilePicture() async {
    if (_isPhotoBusy) return;
    if (_profileImageUrl.trim().isEmpty) {
      _showTopMessage('No profile picture found to delete.', success: false);
      return;
    }

    setState(() => _isPhotoBusy = true);
    try {
      try {
        await AuthService.deleteUploadedFile(_profileImageUrl);
      } catch (_) {}

      try {
        await AuthService.updateProfilePictureUrl('');
      } catch (_) {}

      if (!mounted) return;
      setState(() => _profileImageUrl = '');
      _showTopMessage('Profile picture removed successfully.');
    } finally {
      if (mounted) setState(() => _isPhotoBusy = false);
    }
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
                      const Text(
                        'Profile',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      CircleAvatar(
                        radius: 44,
                        backgroundColor: Colors.white24,
                        backgroundImage: _profileImageUrl.trim().isNotEmpty
                            ? NetworkImage(_profileImageUrl)
                            : null,
                        child: _profileImageUrl.trim().isEmpty
                            ? Text(
                                _getInitials(name),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _isPhotoBusy
                                ? null
                                : _uploadOrChangeProfilePicture,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white70),
                            ),
                            icon: _isPhotoBusy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
                                    _profileImageUrl.trim().isEmpty
                                        ? Icons.upload_rounded
                                        : Icons.photo_camera_outlined,
                                  ),
                            label: const Text('Upload Picture'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isPhotoBusy
                                ? null
                                : _deleteProfilePicture,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white70),
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete Picture'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        name.isEmpty ? 'Employee' : name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _role.isEmpty ? 'Role' : _role,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
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
                  if (_canEditAnnouncement) ...[
                    const SizedBox(height: 8),
                    _buildAnnouncementEditor(),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const PermissionsDebugScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.security),
                      label: const Text('View My Permissions'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF2563EB),
                        side: const BorderSide(color: Color(0xFF2563EB)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
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
                              builder: (_) => const LoginScreen(),
                            ),
                            (route) => false,
                          );
                        }
                      },
                      icon: const Icon(Icons.logout, color: Colors.white),
                      label: const Text(
                        'Logout',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE74C3C),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
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
              Text(
                label,
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value.isEmpty ? '—' : value,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
