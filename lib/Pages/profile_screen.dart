import 'package:flutter/material.dart';
import '../models/profile.dart';
import 'screen_test.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final List<Profile> _profiles = [];
  final TextEditingController _nameController = TextEditingController();

  void _addProfile(String name) {
    if (name.isNotEmpty) {
      setState(() {
        _profiles.add(Profile(name: name));
      });
      _nameController.clear();
      Navigator.of(context).pop();
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
      MaterialPageRoute(
        // Pass the selected profile to the test screen
        builder: (context) => ScreenTest(profile: profile),
      ),
    );
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
