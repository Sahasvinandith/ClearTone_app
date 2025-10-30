import 'package:flutter/material.dart';

class ScreenTest extends StatefulWidget {
  const ScreenTest({super.key});

  @override
  State<ScreenTest> createState() => _ScreenTestState();
}

class _ScreenTestState extends State<ScreenTest> {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.red,
      child: const Center(child: Text('Screen Test')),
    );
  }
}
