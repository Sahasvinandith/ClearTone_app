import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../profile_storage.dart';
import 'screen_test.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
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
    setState(() {
      _profiles = profiles;
    });
  }

  Future<void> _addProfile(String name) async {
    if (name.isNotEmpty) {
      final newProfile = Profile(name: name);
      final updatedProfiles = List<Profile>.from(_profiles)..add(newProfile);
      await _profileStorage.saveProfiles(updatedProfiles);
      if (!mounted) return;
      _nameController.clear();
      Navigator.of(context).pop();
      _loadProfiles();
    }
  }

  void _showAddProfileDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create New Profile'),
          content: TextField(
            controller: _nameController,
            decoration: const InputDecoration(hintText: "Enter profile name"),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => _addProfile(_nameController.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  void _navigateToTest(Profile profile) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ScreenTest(profile: profile)),
    ).then((_) => _loadProfiles());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select a Profile')),
      body: _profiles.isEmpty
          ? const Center(
              child: Text(
                'No profiles yet. Tap the + button to create one.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: _profiles.length,
              itemBuilder: (context, index) {
                final profile = _profiles[index];
                return ListTile(
                  title: Text(profile.name),
                  leading: const Icon(Icons.person),
                  onTap: () => _navigateToTest(profile),
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
