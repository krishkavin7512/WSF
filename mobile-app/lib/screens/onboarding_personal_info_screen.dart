import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/profile_repository.dart';
import '../theme/sentra_design.dart';

class OnboardingPersonalInfoScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingPersonalInfoScreen({super.key, required this.onComplete});

  @override
  State<OnboardingPersonalInfoScreen> createState() =>
      _OnboardingPersonalInfoScreenState();
}

class _OnboardingPersonalInfoScreenState
    extends State<OnboardingPersonalInfoScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController    = TextEditingController();
  final _ageController     = TextEditingController();
  final _addressController = TextEditingController();

  String? _selectedBloodGroup;
  bool _isSaving = false;

  static const List<String> _bloodGroups = [
    'A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−',
  ];

  @override
  void initState() {
    super.initState();
    final meta = Supabase.instance.client.auth.currentUser?.userMetadata;
    final metaName = meta?['full_name'] as String?;
    if (metaName != null && metaName.isNotEmpty) {
      _nameController.text = metaName;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _showError('Session expired. Please sign in again.');
      return;
    }

    setState(() => _isSaving = true);
    try {
      await ProfileRepository.instance.savePersonalInfo(
        userId: userId,
        fullName: _nameController.text.trim(),
        age: int.parse(_ageController.text.trim()),
        bloodGroup: _selectedBloodGroup!,
        homeAddress: _addressController.text.trim(),
        phone: Supabase.instance.client.auth.currentUser?.phone,
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _FieldLabel('Full name'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        decoration: const InputDecoration(hintText: 'Your full name'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel('Age'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _ageController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        decoration: const InputDecoration(hintText: 'e.g. 24'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          final n = int.tryParse(v.trim());
                          if (n == null || n < 1 || n > 120) {
                            return 'Enter a valid age (1–120)';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel('Blood group'),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: _selectedBloodGroup,
                        decoration: const InputDecoration(hintText: 'Select'),
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        items: _bloodGroups
                            .map((g) => DropdownMenuItem(
                                  value: g,
                                  child: Text(g),
                                ))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _selectedBloodGroup = v),
                        validator: (v) =>
                            v == null ? 'Select your blood group' : null,
                      ),
                      const SizedBox(height: 20),
                      const _FieldLabel('Home address'),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _addressController,
                        maxLines: 3,
                        style: SentraDesign.body(color: SentraDesign.uberBlack),
                        decoration: const InputDecoration(
                          hintText: 'Street, area, city',
                          alignLabelWithHint: true,
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                              : const Text('Continue'),
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
              _StepDot(active: true),
              SizedBox(width: 6),
              _StepDot(active: false),
            ],
          ),
          const SizedBox(height: 20),
          Text('Your profile', style: SentraDesign.displayHeadline()),
          const SizedBox(height: 8),
          Text(
            'This information helps responders identify you quickly in an emergency.',
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
  Widget build(BuildContext context) => Text(text, style: SentraDesign.caption());
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
