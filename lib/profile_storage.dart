import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/profile.dart';

class ProfileStorage {
  static const _profilesKey = 'profiles';

  Future<List<Profile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final String? profilesString = prefs.getString(_profilesKey);
    if (profilesString != null) {
      final List<dynamic> profilesJson = jsonDecode(profilesString);
      return profilesJson.map((json) => Profile.fromJson(json)).toList();
    }
    return [];
  }

  Future<void> saveProfiles(List<Profile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final String profilesString =
        jsonEncode(profiles.map((p) => p.toJson()).toList());
    await prefs.setString(_profilesKey, profilesString);
  }

  Future<void> saveProfile(Profile profile) async {
    List<Profile> profiles = await loadProfiles();
    int index = profiles.indexWhere((p) => p.name == profile.name);
    if (index != -1) {
      profiles[index] = profile;
    } else {
      profiles.add(profile);
    }
    await saveProfiles(profiles);
  }
}
