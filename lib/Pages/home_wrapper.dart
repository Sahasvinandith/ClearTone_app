import 'package:flutter/material.dart';
import 'home_screen.dart';

import '../models/profile.dart';

class HomeWrapper extends StatefulWidget {
  final Profile profile;

  const HomeWrapper({super.key, required this.profile});

  @override
  State<HomeWrapper> createState() => _HomeWrapperState();
}

class _HomeWrapperState extends State<HomeWrapper> {
  int _currentIndex = 0;

  late final List<Widget> _screens = [
    HomeScreen(profile: widget.profile),
    // Placeholder for other screens you might add later (e.g. Plan, Stats, More)
    const Center(
      child: Text('PLAN', style: TextStyle(letterSpacing: 1, fontSize: 18)),
    ),
    const Center(
      child: Text('STATS', style: TextStyle(letterSpacing: 1, fontSize: 18)),
    ),
    const Center(
      child: Text('MORE', style: TextStyle(letterSpacing: 1, fontSize: 18)),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      // iOS Pill style TabBar container at the bottom
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(
          21,
          12,
          21,
          8,
        ), // Reduced bottom padding
        decoration: const BoxDecoration(
          color: Color(0xFF111111), // Match scaffold background
        ),
        child: SafeArea(
          // Added to ensure it doesn't overflow
          child: Container(
            height: 56, // Slightly taller for the bottom nav
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1C),
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: const Color(0xFF2A2A2A)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(36),
              child: BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: (index) {
                  setState(() {
                    _currentIndex = index;
                  });
                },
                backgroundColor: const Color(0xFF1C1C1C),
                type: BottomNavigationBarType.fixed,
                elevation: 0,
                showSelectedLabels: true,
                showUnselectedLabels: true,
                selectedItemColor: const Color(0xFF111111), // Dark text on gold
                unselectedItemColor: const Color(0xFF666666),
                selectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  fontSize: 9,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  fontSize: 9,
                ),
                items: [
                  BottomNavigationBarItem(
                    icon: _buildIcon(Icons.home_outlined, 0),
                    activeIcon: _buildActiveIcon(Icons.home, 0),
                    label: 'HOME',
                  ),
                  BottomNavigationBarItem(
                    icon: _buildIcon(Icons.calendar_month_outlined, 1),
                    activeIcon: _buildActiveIcon(Icons.calendar_month, 1),
                    label: 'PLAN',
                  ),
                  BottomNavigationBarItem(
                    icon: _buildIcon(Icons.bar_chart_outlined, 2),
                    activeIcon: _buildActiveIcon(Icons.bar_chart, 2),
                    label: 'STATS',
                  ),
                  BottomNavigationBarItem(
                    icon: _buildIcon(Icons.more_horiz_outlined, 3),
                    activeIcon: _buildActiveIcon(Icons.more_horiz, 3),
                    label: 'MORE',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIcon(IconData iconData, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2.0),
      child: Icon(iconData, size: 20, color: const Color(0xFF666666)),
    );
  }

  Widget _buildActiveIcon(IconData iconData, int index) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFD4AF37),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Icon(iconData, size: 20, color: const Color(0xFF111111)),
    );
  }
}
