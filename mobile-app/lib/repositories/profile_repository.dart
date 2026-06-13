import 'package:supabase_flutter/supabase_flutter.dart';

/// All Supabase reads/writes related to user profile and emergency contacts
/// live here. Screens never touch `Supabase.instance.client` directly.
class ProfileRepository {
  ProfileRepository._();
  static final ProfileRepository instance = ProfileRepository._();

  SupabaseClient get _db => Supabase.instance.client;

  // ── Profiles ──────────────────────────────────────────────────────────────

  /// Returns the current user's profile row, or null if not yet created.
  Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    final response = await _db
        .from('profiles')
        .select('id, full_name, age, blood_group, home_address, phone')
        .eq('id', userId)
        .maybeSingle();
    return response;
  }

  /// True when the user has completed Step 1 (personal info).
  /// Uses `age` as the sentinel — it is the first non-nullable business field.
  Future<bool> isPersonalInfoComplete(String userId) async {
    final row = await fetchProfile(userId);
    if (row == null) return false;
    return row['age'] != null;
  }

  /// True when the user has finished the entire onboarding flow.
  /// `registration_complete` is the single official gate (set once the
  /// emergency contact is saved). Prefer this over inferring from other fields.
  Future<bool> isRegistrationComplete(String userId) async {
    final row = await _db
        .from('profiles')
        .select('registration_complete')
        .eq('id', userId)
        .maybeSingle();
    return (row?['registration_complete'] as bool?) ?? false;
  }

  /// Upserts all personal-info fields. Safe to call on subsequent logins.
  Future<void> savePersonalInfo({
    required String userId,
    required String fullName,
    required int age,
    required String bloodGroup,
    required String homeAddress,
    String? phone,
  }) async {
    await _db.from('profiles').upsert(
      {
        'id': userId,
        'full_name': fullName,
        'age': age,
        'blood_group': bloodGroup,
        'home_address': homeAddress,
        if (phone != null) 'phone': phone,
      },
      onConflict: 'id',
    );
  }

  // ── Emergency contacts ────────────────────────────────────────────────────

  /// True when the user has at least one emergency contact on record.
  Future<bool> hasEmergencyContact(String userId) async {
    final response = await _db
        .from('emergency_contacts')
        .select('id')
        .eq('user_id', userId)
        .limit(1);
    return (response as List).isNotEmpty;
  }

  /// Returns the user's single emergency contact, or null if none is set yet.
  /// Used by the profile screen so the contact can be edited later.
  Future<Map<String, dynamic>?> fetchEmergencyContact(String userId) async {
    return await _db
        .from('emergency_contacts')
        .select('id, contact_name, contact_number, relationship')
        .eq('user_id', userId)
        .maybeSingle();
  }

  /// Saves (or replaces) the user's single emergency contact and marks
  /// onboarding complete. The UNIQUE(user_id) constraint makes this upsert
  /// replace the existing row in place, so editing later just calls this again.
  Future<void> saveEmergencyContact({
    required String userId,
    required String contactName,
    required String contactNumber,
    required String relationship,
  }) async {
    await _db.from('emergency_contacts').upsert({
      'user_id': userId,
      'contact_name': contactName,
      'contact_number': contactNumber,
      'relationship': relationship,
    }, onConflict: 'user_id');

    // Flip the official onboarding gate once a contact exists.
    await _db
        .from('profiles')
        .update({'registration_complete': true})
        .eq('id', userId);
  }
}
