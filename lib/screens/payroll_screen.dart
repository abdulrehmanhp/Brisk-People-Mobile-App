import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../widgets/permission_gate.dart';

class PayrollScreen extends StatefulWidget {
  const PayrollScreen({super.key});

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  bool _loading = true;
  bool _canViewPayslip = false;
  bool _hasAnyPayrollAccess = false;

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    final results = await Future.wait([
      PermissionService.hasPermissionByActionKey(PermissionKeys.myPayslip),
      PermissionService.hasMenuParentPermission('Payroll'),
      PermissionService.hasAnyPermissionByActionKeys(
        PermissionKeys.payrollNavActionKeys,
      ),
    ]);

    if (!mounted) return;
    setState(() {
      _canViewPayslip = results[0];
      _hasAnyPayrollAccess = results[1] || results[2];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_hasAnyPayrollAccess) {
      return const PermissionDeniedScaffold(featureName: 'Payroll');
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text(
          'Payroll',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF2563EB),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.receipt_long, size: 80, color: Colors.grey.shade300),
              const SizedBox(height: 16),
              Text(
                _canViewPayslip ? 'My Payslip' : 'Payroll',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _canViewPayslip
                    ? 'Payslip viewing is enabled for your role. Full payslip download will be available in a future update.'
                    : 'You have payroll access but not payslip viewing. Use the web app for other payroll features.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
