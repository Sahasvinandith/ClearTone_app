import 'package:cleartone/Pages/profile_screen.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audiometry App',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const ProfileScreen(),
    );
  }
}
