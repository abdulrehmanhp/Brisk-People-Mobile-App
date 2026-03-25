import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/attendance_service.dart';
import '../services/auth_service.dart';

class ShiftSwapScreen extends StatefulWidget {
  final bool openCreateSheetOnLoad;
  final bool showBackButton;
  final int initialSegmentIndex;

  const ShiftSwapScreen({
    super.key,
    this.openCreateSheetOnLoad = false,
    this.showBackButton = false,
    this.initialSegmentIndex = 0,
  });

  @override
  State<ShiftSwapScreen> createState() => _ShiftSwapScreenState();
}

class _ShiftSwapScreenState extends State<ShiftSwapScreen> {
  bool _isLoading = true;
  bool _hasAutoOpened = false;
  String? _token;
  String _userId = '';
  String _role = '';
  String? _currentShiftId;

  int _segmentIndex = 0;

  List<ShiftInfo> _shifts = [];
  List<ShiftSwapRequestItem> _myRequests = [];
  List<ShiftSwapRequestItem> _teamPendingRequests = [];

  final Set<String> _processingIds = <String>{};
  bool _isSheetOpen = false;

  bool get _canManageTeam {
    final r = _role.toLowerCase();
    return r.contains('manager') || r.contains('admin') || r.contains('hr');
  }

  @override
  void initState() {
    super.initState();
    _segmentIndex = widget.initialSegmentIndex.clamp(0, 1);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    _token ??= await AuthService.getToken();
    final info = await AuthService.getUserInfo();
    _userId = (info['userId'] ?? '').trim();
    _role = (info['role'] ?? '').trim();

    if (_token == null || _token!.isEmpty || _userId.isEmpty) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showMessage('Session expired. Please login again.', isError: true);
      return;
    }

    final today = await AttendanceService.getTodayAttendance(_token!);
    final data = today?['data'];
    if (data is Map<String, dynamic>) {
      _currentShiftId =
          (data['shiftId'] ?? data['ShiftId'] ?? _currentShiftId)?.toString();
    }
    if ((_currentShiftId ?? '').isEmpty) {
      _currentShiftId =
          await AttendanceService.getEmployeeShiftId(_token!, _userId);
    }

    final futures = <Future<dynamic>>[
      AttendanceService.getShifts(_token!),
      AttendanceService.getShiftSwapRequestsByEmployee(_token!, _userId),
    ];
    if (_canManageTeam) {
      futures.add(AttendanceService.getPendingShiftSwapRequests(_token!));
    }

    final results = await Future.wait<dynamic>(futures);
    final shifts = results[0] as List<ShiftInfo>;
    final myRequests = results[1] as List<ShiftSwapRequestItem>;
    final teamPending = _canManageTeam
        ? (results[2] as List<ShiftSwapRequestItem>)
        : <ShiftSwapRequestItem>[];

    if (!mounted) return;
    setState(() {
      _shifts = shifts;
      _myRequests = myRequests;
      _teamPendingRequests = teamPending;
      _isLoading = false;
    });

    if (widget.openCreateSheetOnLoad && !_hasAutoOpened) {
      _hasAutoOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCreateShiftSwapSheet();
      });
    }
  }

  void _showMessage(String msg, {bool isError = false}) {
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isError
                    ? const Color(0xFFB03A2E)
                    : const Color(0xFF1A8C5B),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    isError ? Icons.error_rounded : Icons.check_circle_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      msg,
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

  Future<void> _openCreateShiftSwapSheet() async {
    if (_isSheetOpen) return;
    _isSheetOpen = true;

    try {
      if (_token == null || _token!.isEmpty || _userId.isEmpty) {
        _showMessage('Session expired. Please login again.', isError: true);
        return;
      }

      if (_shifts.isEmpty) {
        final shifts = await AttendanceService.getShifts(_token!);
        if (!mounted) return;
        setState(() => _shifts = shifts);
      }
      if (_shifts.isEmpty) {
        _showMessage('No shifts found to request swap.', isError: true);
        return;
      }

      final candidates =
          _shifts.where((e) => e.shiftId != (_currentShiftId ?? '')).toList();
      final uniqueCandidates = candidates
          .where((e) => e.shiftId.trim().isNotEmpty)
          .fold<List<ShiftInfo>>(<ShiftInfo>[], (acc, item) {
            if (acc.any((e) => e.shiftId == item.shiftId)) return acc;
            acc.add(item);
            return acc;
          });

      if (uniqueCandidates.isEmpty) {
        _showMessage('No alternate shifts available for swap.', isError: true);
        return;
      }

      if (!mounted) return;

      // ✅ Use showModalBottomSheet with a return value (_ShiftSwapResult)
      // No shared TextEditingController — the sheet owns it internally
      final result = await showModalBottomSheet<_ShiftSwapResult>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _CreateShiftSwapSheet(
          uniqueCandidates: uniqueCandidates,
          initialShift: uniqueCandidates.first.shiftId,
          // ✅ The submit logic runs INSIDE the sheet and returns result to us
          onSubmit: (chosenShiftId, reason) async {
            return AttendanceService.createShiftSwapRequest(
              _token!,
              employeeId: _userId,
              currentShiftId: _currentShiftId,
              requestedShiftId: chosenShiftId,
              reason: reason,
            );
          },
        ),
      );

      // Sheet is fully closed here — safe to use outer context
      if (!mounted) return;

      if (result != null) {
        _showMessage(result.message, isError: !result.success);
        if (result.success) await _loadData();
      }
    } finally {
      _isSheetOpen = false;
    }
  }

  Future<void> _handleTeamDecision(
    ShiftSwapRequestItem item,
    bool isApproved,
  ) async {
    final reasonController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isApproved ? 'Approve Shift Swap?' : 'Reject Shift Swap?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${item.employeeName.isEmpty ? item.employeeId : item.employeeName}'
              ': ${item.currentShiftName} -> ${item.requestedShiftName}',
            ),
            if (!isApproved) ...[
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Rejection reason',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isApproved ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );

    if (ok != true) {
      reasonController.dispose();
      return;
    }

    if (_token == null || _token!.isEmpty || _userId.isEmpty) {
      reasonController.dispose();
      _showMessage('Session expired. Please login again.', isError: true);
      return;
    }

    setState(() => _processingIds.add(item.requestId));
    final result = await AttendanceService.approveShiftSwapRequest(
      _token!,
      requestId: item.requestId,
      approvedBy: _userId,
      isApproved: isApproved,
      rejectionReason: isApproved ? null : reasonController.text,
    );
    reasonController.dispose();

    if (!mounted) return;
    setState(() => _processingIds.remove(item.requestId));
    _showMessage(result.message, isError: !result.success);
    if (result.success) await _loadData();
  }

  Widget _buildRequestCard(ShiftSwapRequestItem item, {bool isTeam = false}) {
    final status = item.status.toLowerCase();
    final statusColor = status == 'approved'
        ? const Color(0xFF1AA865)
        : status == 'pending'
            ? const Color(0xFFCC7A00)
            : const Color(0xFFE03D52);

    final isProcessing = _processingIds.contains(item.requestId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E8F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.swap_horiz, color: Color(0xFF8E44AD)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${item.currentShiftName} -> ${item.requestedShiftName}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0B132B),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  toBeginningOfSentenceCase(status) ?? status,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (item.employeeName.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Employee: ${item.employeeName}',
              style: const TextStyle(color: Color(0xFF627690), fontSize: 12),
            ),
          ],
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFD),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE6ECF5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current Shift: ${item.currentShiftName.isEmpty ? '--' : item.currentShiftName}',
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Requested Shift: ${item.requestedShiftName.isEmpty ? '--' : item.requestedShiftName}',
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (item.reason.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Reason: ${item.reason}',
              style: const TextStyle(color: Color(0xFF627690), fontSize: 12),
            ),
          ],
          if (isTeam && item.isPending) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: isProcessing
                        ? null
                        : () => _handleTeamDecision(item, false),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: isProcessing
                        ? null
                        : () => _handleTeamDecision(item, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F766E),
                      foregroundColor: Colors.white,
                    ),
                    child: Text(isProcessing ? 'Processing...' : 'Approve'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: widget.showBackButton || Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Color(0xFF0B132B)),
                onPressed: () => Navigator.maybePop(context),
              )
            : null,
        title: const Text(
          'Shift Swap Requests',
          style: TextStyle(
            color: Color(0xFF0B132B),
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _openCreateShiftSwapSheet,
            icon: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: Color(0xFFE6ECF7),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.add, color: Color(0xFF8E44AD), size: 28),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_canManageTeam)
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCE2EC),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() => _segmentIndex = 0),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _segmentIndex == 0
                                        ? const Color(0xFF8E44AD)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    'My Requests',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _segmentIndex == 0
                                          ? Colors.white
                                          : const Color(0xFF5B6B84),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() => _segmentIndex = 1),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _segmentIndex == 1
                                        ? const Color(0xFF8E44AD)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    'Team Requests',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _segmentIndex == 1
                                          ? Colors.white
                                          : const Color(0xFF5B6B84),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_canManageTeam) const SizedBox(height: 12),
                    if (!_canManageTeam || _segmentIndex == 0)
                      _myRequests.isEmpty
                          ? const Text('No shift swap requests found.')
                          : Column(
                              children: _myRequests
                                  .map((e) => _buildRequestCard(e))
                                  .toList(),
                            ),
                    if (_canManageTeam && _segmentIndex == 1)
                      _teamPendingRequests.isEmpty
                          ? const Text(
                              'No pending team shift swap requests.')
                          : Column(
                              children: _teamPendingRequests
                                  .map((e) =>
                                      _buildRequestCard(e, isTeam: true))
                                  .toList(),
                            ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Simple result object so the sheet can return data without shared state
// ─────────────────────────────────────────────────────────────────────────────
class _ShiftSwapResult {
  final bool success;
  final String message;
  const _ShiftSwapResult({required this.success, required this.message});
}

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained sheet widget — owns its own TextEditingController
// No shared controllers, no cross-context calls during async gaps
// ─────────────────────────────────────────────────────────────────────────────
class _CreateShiftSwapSheet extends StatefulWidget {
  final List<ShiftInfo> uniqueCandidates;
  final String initialShift;

  /// Returns the raw service result — sheet pops itself on success
  final Future<dynamic> Function(String chosenShiftId, String reason) onSubmit;

  const _CreateShiftSwapSheet({
    required this.uniqueCandidates,
    required this.initialShift,
    required this.onSubmit,
  });

  @override
  State<_CreateShiftSwapSheet> createState() => _CreateShiftSwapSheetState();
}

class _CreateShiftSwapSheetState extends State<_CreateShiftSwapSheet> {
  late String _selectedShift;
  bool _submitting = false;

  // ✅ Controller owned HERE — created and disposed in this State only
  final TextEditingController _reasonController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedShift = widget.initialShift;
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    // Snapshot values before await
    final chosenShift = _selectedShift;
    final reason = _reasonController.text;

    try {
      final raw = await widget.onSubmit(chosenShift, reason);

      // raw is whatever AttendanceService returns — adapt to your type
      final success = raw?.success as bool? ?? false;
      final message = raw?.message as String? ?? '';

      if (!mounted) return;

      // ✅ Pop with result — parent handles toast + reload AFTER sheet is gone
      Navigator.of(context).pop(
        _ShiftSwapResult(success: success, message: message),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // Surface unexpected errors without crashing
      Navigator.of(context).pop(
        _ShiftSwapResult(success: false, message: e.toString()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final viewPadding = MediaQuery.of(context).viewPadding.bottom;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: viewInsets + viewPadding + 28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Create Shift Swap Request',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),

              // ✅ Plain DropdownButton — zero GlobalKey involvement
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: DropdownButton<String>(
                  value: _selectedShift,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: widget.uniqueCandidates
                      .map(
                        (e) => DropdownMenuItem<String>(
                          value: e.shiftId,
                          child: Text(e.shiftName),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedShift = v);
                  },
                ),
              ),
              const SizedBox(height: 10),

              TextField(
                controller: _reasonController,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.swap_horiz),
                  label:
                      Text(_submitting ? 'Submitting...' : 'Submit Request'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}