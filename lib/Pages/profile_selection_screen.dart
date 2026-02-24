import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../profile_storage.dart';
import 'home_wrapper.dart';

class ProfileSelectionScreen extends StatefulWidget {
  const ProfileSelectionScreen({super.key});

  @override
  State<ProfileSelectionScreen> createState() => _ProfileSelectionScreenState();
}

class _ProfileSelectionScreenState extends State<ProfileSelectionScreen> {
  final ProfileStorage _profileStorage = ProfileStorage();
  List<Profile> _profiles = [];
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final profiles = await _profileStorage.loadProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
    });
  }

  void _addProfile(String name) async {
    if (name.isNotEmpty) {
      final newProfile = Profile(name: name);
      await _profileStorage.saveProfile(newProfile);
      _nameController.clear();
      if (!mounted) return;
      Navigator.of(context).pop(); // Close dialog
      _loadProfiles();
    }
  }

  void _showAddProfileDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'CREATE NEW PROFILE',
            style: TextStyle(letterSpacing: 1),
          ),
          content: TextField(
            controller: _nameController,
            decoration: const InputDecoration(hintText: "ENTER PROFILE NAME"),
            autofocus: true,
            style: const TextStyle(letterSpacing: 1),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () => _addProfile(_nameController.text),
              child: const Text('CREATE'),
            ),
          ],
        );
      },
    );
  }

  void _navigateToHome(Profile profile) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => HomeWrapper(profile: profile)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SELECT A PROFILE')),
      body: _profiles.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  'NO PROFILES YET.\nTAP THE + BUTTON TO CREATE ONE.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: Color(0xFF666666), // Muted text
                  ),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 28),
              itemCount: _profiles.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final profile = _profiles[index];
                return InkWell(
                  onTap: () => _navigateToHome(profile),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
                    child: Row(
                      children: [
                        Container(
                          width: 3,
                          height: 14,
                          color: const Color(0xFFD4AF37), // Vertical accent bar
                        ),
                        const SizedBox(width: 12),
                        const Icon(
                          Icons.person,
                          color: Colors.white70,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          profile.name.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddProfileDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}
