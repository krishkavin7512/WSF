import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../repositories/profile_repository.dart';
import '../services/location_service.dart';
import '../theme/sentra_design.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController    = TextEditingController();
  final _ageController     = TextEditingController();
  final _addressController = TextEditingController();
  final _ecNameController  = TextEditingController();
  final _ecNumberController = TextEditingController();

  String? _bloodGroup;
  String? _ecRelationship;
  String? _phone;
  bool _loading = true;
  bool _saving  = false;

  static const List<String> _bloodGroups = [
    'A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−',
  ];

  static const List<String> _relationships = [
    'Mother', 'Father', 'Sister', 'Brother',
    'Spouse / Partner', 'Friend', 'Guardian', 'Other',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _addressController.dispose();
    _ecNameController.dispose();
    _ecNumberController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final profile = await ProfileRepository.instance.fetchProfile(userId);
      final ec      = await ProfileRepository.instance.fetchEmergencyContact(userId);

      if (!mounted) return;
      setState(() {
        _nameController.text    = profile?['full_name']   as String? ?? '';
        _ageController.text     = profile?['age'] != null ? '${profile!['age']}' : '';
        _addressController.text = profile?['home_address'] as String? ?? '';
        _bloodGroup             = profile?['blood_group']  as String?;
        _phone = Supabase.instance.client.auth.currentUser?.phone;

        if (ec != null) {
          _ecNameController.text   = ec['contact_name']   as String? ?? '';
          _ecNumberController.text = ec['contact_number'] as String? ?? '';
          _ecRelationship          = ec['relationship']   as String?;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _formatPhone(String raw) {
    final trimmed = raw.trim();
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
    if (userId == null) return;

    final ecFormatted = _formatPhone(_ecNumberController.text);
    if (ecFormatted == null) {
      _showSnack('Enter a valid emergency contact number.');
      return;
    }

    setState(() => _saving = true);
    try {
      await ProfileRepository.instance.savePersonalInfo(
        userId:      userId,
        fullName:    _nameController.text.trim(),
        age:         int.parse(_ageController.text.trim()),
        bloodGroup:  _bloodGroup!,
        homeAddress: _addressController.text.trim(),
        phone:       _phone,
      );
      await ProfileRepository.instance.saveEmergencyContact(
        userId:          userId,
        contactName:     _ecNameController.text.trim(),
        contactNumber:   ecFormatted,
        relationship:    _ecRelationship!,
      );
      if (!mounted) return;
      _showSnack('Profile saved.');
    } on PostgrestException catch (e) {
      if (mounted) _showSnack(e.message);
    } catch (_) {
      if (mounted) _showSnack('Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Sign out',
                style: TextStyle(color: Colors.red.shade700)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LocationService().clearLocation();
    await LocationService().dispose();
    await Supabase.instance.client.auth.signOut();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: SentraDesign.pureWhite,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: SentraDesign.uberBlack, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Profile',
          style: GoogleFonts.inter(
            color: SentraDesign.uberBlack,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: SentraDesign.uberBlack))
                  : Text(
                      'Save',
                      style: GoogleFonts.inter(
                        color: SentraDesign.uberBlack,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: SentraDesign.uberBlack))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildAvatar(),
                  const SizedBox(height: 24),
                  _sectionCard('Personal Information', [
                    _field(
                      label: 'Full name',
                      controller: _nameController,
                      hint: 'Your full name',
                      textCapitalization: TextCapitalization.words,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: 'Phone',
                      controller: TextEditingController(
                          text: _phone ?? '—'),
                      hint: '',
                      enabled: false,
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: 'Age',
                      controller: _ageController,
                      hint: 'e.g. 24',
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly
                      ],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        final n = int.tryParse(v.trim());
                        if (n == null || n < 1 || n > 120) {
                          return 'Enter a valid age (1–120)';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    _label('Blood group'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _bloodGroup,
                      decoration: _inputDeco('Select'),
                      style: SentraDesign.body(
                          color: SentraDesign.uberBlack),
                      items: _bloodGroups
                          .map((g) => DropdownMenuItem(
                              value: g, child: Text(g)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _bloodGroup = v),
                      validator: (v) =>
                          v == null ? 'Select blood group' : null,
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: 'Home address',
                      controller: _addressController,
                      hint: 'Street, area, city',
                      maxLines: 3,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Required'
                              : null,
                    ),
                  ]),
                  const SizedBox(height: 16),
                  _sectionCard('Emergency Contact', [
                    _field(
                      label: 'Contact name',
                      controller: _ecNameController,
                      hint: 'Full name of trusted person',
                      textCapitalization: TextCapitalization.words,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    _field(
                      label: 'Phone number',
                      controller: _ecNumberController,
                      hint: '+91 or 10-digit number',
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9+\s\-]'))
                      ],
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (_formatPhone(v) == null) {
                          return 'Enter a valid phone number';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    _label('Relationship'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _ecRelationship,
                      decoration: _inputDeco('Select'),
                      style: SentraDesign.body(
                          color: SentraDesign.uberBlack),
                      items: _relationships
                          .map((r) => DropdownMenuItem(
                              value: r, child: Text(r)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _ecRelationship = v),
                      validator: (v) =>
                          v == null ? 'Select relationship' : null,
                    ),
                  ]),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: _signOut,
                      icon: Icon(Icons.logout_rounded,
                          color: Colors.red.shade700, size: 20),
                      label: Text(
                        'Sign out',
                        style: GoogleFonts.inter(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.red.shade200),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildAvatar() {
    final name = _nameController.text.trim();
    final initials = name.isEmpty
        ? '?'
        : name.split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase();

    return Center(
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: SentraDesign.uberBlack,
            child: Text(
              initials,
              style: GoogleFonts.inter(
                color: SentraDesign.pureWhite,
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _nameController.text.trim().isEmpty
                ? 'Your Profile'
                : _nameController.text.trim(),
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: SentraDesign.uberBlack,
            ),
          ),
          if (_phone != null && _phone!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _phone!,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: SentraDesign.bodyGray,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionCard(String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: SentraDesign.pureWhite,
        borderRadius: BorderRadius.circular(16),
        boxShadow: SentraDesign.cardShadow,
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: SentraDesign.mutedGray,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    bool enabled = true,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    TextCapitalization textCapitalization = TextCapitalization.none,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          enabled: enabled,
          maxLines: maxLines,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          inputFormatters: inputFormatters,
          style: SentraDesign.body(color: SentraDesign.uberBlack),
          decoration: _inputDeco(hint),
          validator: validator,
        ),
      ],
    );
  }

  Widget _label(String text) => Text(text, style: SentraDesign.caption());

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: SentraDesign.body(color: SentraDesign.mutedGray),
        filled: true,
        fillColor: const Color(0xFFF8F8F8),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(
              color: SentraDesign.uberBlack, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey.shade100),
        ),
      );
}
