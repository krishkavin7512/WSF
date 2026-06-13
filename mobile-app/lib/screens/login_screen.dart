import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/sentra_design.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController  = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController   = TextEditingController();

  bool _isRegister   = true;  // true = Register, false = Login
  bool _isOtpSent    = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  /// E.164: if input starts with `+`, keep country code + digits; else default +91.
  String? _formatPhoneE164(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('+')) {
      final rest = trimmed.substring(1).replaceAll(RegExp(r'\D'), '');
      if (rest.length < 8) return null;
      return '+$rest';
    }

    var digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) digits = digits.substring(1);
    if (digits.length == 11 && digits.startsWith('91')) return '+$digits';
    if (digits.length == 10) return '+91$digits';
    if (digits.length >= 10) return '+91${digits.substring(digits.length - 10)}';
    return null;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendOtp() async {
    if (!_formKey.currentState!.validate()) return;

    final formatted = _formatPhoneE164(_phoneController.text);
    if (formatted == null) {
      _showError('Enter a valid phone number.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        phone: formatted,
        data: _isRegister
            ? {'full_name': _nameController.text.trim()}
            : null,
      );
      if (!mounted) return;
      setState(() {
        _isOtpSent    = true;
        _isSubmitting = false;
      });
    } on AuthException catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError(e.message);
    } catch (_) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError('Could not send OTP. Try again.');
    }
  }

  Future<void> _verifyOtp() async {
    final formatted = _formatPhoneE164(_phoneController.text);
    if (formatted == null) {
      _showError('Invalid phone number.');
      return;
    }
    final token = _otpController.text.trim();
    if (token.isEmpty) {
      _showError('Enter the code from SMS.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client.auth.verifyOTP(
        phone: formatted,
        token: token,
        type: OtpType.sms,
      );

      if (_isRegister) {
        final enteredName = _nameController.text.trim();
        // Force-update metadata and profile with the typed name.
        if (enteredName.isNotEmpty) {
          try {
            await Supabase.instance.client.auth.updateUser(
              UserAttributes(data: {'full_name': enteredName}),
            );
          } catch (_) {}
        }
        final uid   = Supabase.instance.client.auth.currentUser?.id;
        final phone = Supabase.instance.client.auth.currentUser?.phone;
        if (uid != null) {
          try {
            await Supabase.instance.client.from('profiles').upsert({
              'id': uid,
              'full_name': enteredName.isNotEmpty ? enteredName : null,
              'phone': phone,
            }, onConflict: 'id');
          } catch (_) {}
        }
      }

      if (!mounted) return;
      setState(() => _isSubmitting = false);
      if (Supabase.instance.client.auth.currentUser == null) {
        _showError('Verification failed.');
      }
      // AuthShell handles navigation via onAuthStateChange.
    } on AuthException catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError(e.message);
    } catch (_) {
      if (mounted) setState(() => _isSubmitting = false);
      _showError('Could not verify OTP.');
    }
  }

  void _resetPhoneStep() {
    setState(() {
      _isOtpSent = false;
      _otpController.clear();
    });
  }

  void _toggleMode() {
    setState(() {
      _isRegister   = !_isRegister;
      _isOtpSent    = false;
      _nameController.clear();
      _phoneController.clear();
      _otpController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SentraDesign.pureWhite,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Text(
                  'SENTRA',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: SentraDesign.uberBlack,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isRegister ? 'Create your account' : 'Welcome back',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    color: SentraDesign.bodyGray,
                  ),
                ),
                const SizedBox(height: 32),

                // ── Mode toggle ──────────────────────────────────────────
                _ModeToggle(
                  isRegister: _isRegister,
                  onToggle: _isOtpSent ? null : _toggleMode,
                ),
                const SizedBox(height: 32),

                // ── Name field (register only) ───────────────────────────
                if (_isRegister) ...[
                  _label('Full name'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameController,
                    enabled: !_isOtpSent,
                    textCapitalization: TextCapitalization.words,
                    style: _textStyle(),
                    decoration: _inputDeco('Your full name'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Name is required'
                        : null,
                  ),
                  const SizedBox(height: 20),
                ],

                // ── Phone field ──────────────────────────────────────────
                _label('Phone number'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _phoneController,
                  enabled: !_isOtpSent,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                  ],
                  style: _textStyle(),
                  decoration: _inputDeco('+91 or 10-digit number'),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Phone is required';
                    if (_formatPhoneE164(v) == null) return 'Invalid phone number';
                    return null;
                  },
                ),

                // ── OTP field ────────────────────────────────────────────
                if (_isOtpSent) ...[
                  const SizedBox(height: 20),
                  _label('One-time code'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    style: _textStyle(),
                    decoration: _inputDeco('Code from SMS'),
                  ),
                ],

                const SizedBox(height: 32),

                // ── Primary action ───────────────────────────────────────
                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isSubmitting
                        ? null
                        : (_isOtpSent ? _verifyOtp : _sendOtp),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: SentraDesign.uberBlack,
                      foregroundColor: SentraDesign.pureWhite,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 22, width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2, color: SentraDesign.pureWhite))
                        : Text(
                            _isOtpSent
                                ? 'Verify'
                                : (_isRegister ? 'Send OTP' : 'Send OTP'),
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600, fontSize: 16),
                          ),
                  ),
                ),

                if (_isOtpSent) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isSubmitting ? null : _resetPhoneStep,
                    child: Text(
                      'Change number',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: SentraDesign.uberBlack,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _textStyle() => GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: SentraDesign.uberBlack,
      );

  Widget _label(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: SentraDesign.bodyGray,
        ),
      );

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(color: SentraDesign.mutedGray),
      );
}

// ── Mode toggle widget ────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  final bool isRegister;
  final VoidCallback? onToggle;

  const _ModeToggle({required this.isRegister, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _Tab(
            label: 'Register',
            selected: isRegister,
            onTap: (!isRegister && onToggle != null) ? onToggle : null,
          ),
          _Tab(
            label: 'Login',
            selected: !isRegister,
            onTap: (isRegister && onToggle != null) ? onToggle : null,
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _Tab({required this.label, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: selected ? SentraDesign.pureWhite : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? SentraDesign.uberBlack
                    : SentraDesign.mutedGray,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
