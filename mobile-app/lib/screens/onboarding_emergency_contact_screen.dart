import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/profile_repository.dart';
import '../theme/sentra_design.dart';

class OnboardingEmergencyContactScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingEmergencyContactScreen({
    super.key,
    required this.onComplete,
  });

  @override
  State<OnboardingEmergencyContactScreen> createState() =>
      _OnboardingEmergencyContactScreenState();
}

class _OnboardingEmergencyContactScreenState
    extends State<OnboardingEmergencyContactScreen> {
  final _formKey          = GlobalKey<FormState>();
  final _nameController   = TextEditingController();
  final _numberController = TextEditingController();

  String? _selectedRelationship;
  bool _isSaving = false;

  static const List<String> _relationships = [
    'Mother',
    'Father',
    'Sister',
    'Brother',
    'Spouse / Partner',
    'Friend',
    'Guardian',
    'Other',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _numberController.dispose();
    super.dispose();
  }

  /// E.164 normalisation — same logic as LoginScreen to stay consistent.
  String? _formatPhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('+')) {
      final digits = trimmed.substring(1).replaceAll(RegExp(r'\D'), '');
      return digits.length >= 8 ? '+$digits' : null;
    }
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '+91$digits';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _showError('Session expired. Please sign in again.');
      return;
    }

    final formatted = _formatPhone(_numberController.text);
    if (formatted == null) {
      _showError('Enter a valid phone number.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ProfileRepository.instance.saveEmergencyContact(
        userId: userId,
        contactName: _nameController.text.trim(),
        contactNumber: formatted,
        relationship: _selectedRelationship!,
      );
      if (!mounted) return;
      widget.onComplete();
    } on PostgrestException catch (e) {
      if (mounted) _showError(e.message);
    } catch (_) {
      if (mounted) _showError('Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SentraDesign.pureWhite,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _FieldLabel('Contact name'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        decoration: const InputDecoration(
                            hintText: 'Full name of trusted person'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel('Phone number'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _numberController,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9+\s\-]')),
                        ],
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        decoration: const InputDecoration(
                            hintText: '+91 or 10-digit number'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          if (_formatPhone(v) == null) {
                            return 'Enter a valid phone number';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel('Relationship'),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: _selectedRelationship,
                        decoration: const InputDecoration(hintText: 'Select'),
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        items: _relationships
                            .map((r) => DropdownMenuItem(
                                  value: r,
                                  child: Text(r),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _selectedRelationship = v),
                        validator: (v) =>
                            v == null ? 'Select a relationship' : null,
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _isSaving ? null : _save,
                          child: _isSaving
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: SentraDesign.pureWhite,
                                  ),
                                )
                              : const Text('Finish setup'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              _StepDot(active: false),
              SizedBox(width: 6),
              _StepDot(active: true),
            ],
          ),
          const SizedBox(height: 20),
          Text('Emergency contact', style: SentraDesign.displayHeadline()),
          const SizedBox(height: 8),
          Text(
            'Someone who will be notified immediately if an SOS is triggered.',
            style: SentraDesign.body(),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ── Shared small widgets ──────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text, style: SentraDesign.caption());
}

class _StepDot extends StatelessWidget {
  final bool active;
  const _StepDot({required this.active});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: active ? 24 : 8,
        height: 8,
        decoration: BoxDecoration(
          color: active ? SentraDesign.uberBlack : SentraDesign.chipGray,
          borderRadius: BorderRadius.circular(4),
        ),
      );
}
