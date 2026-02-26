import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/profile.dart';
import 'results_screen.dart';
import '../profile_storage.dart';
import 'screen_test.dart';
import '../audio_generator.dart';
import 'profile_selection_screen.dart';

class HomeScreen extends StatefulWidget {
  final Profile profile;

  const HomeScreen({super.key, required this.profile});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProfileStorage _profileStorage = ProfileStorage();
  final AudioGenerator _audioGenerator = AudioGenerator();
  List<Profile> _profiles = [];

  late Profile _activeProfile;
  int _selectedChartTab = 2; // 0=Left, 1=Right, 2=All

  @override
  void dispose() {
    _audioGenerator.stopTone();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _activeProfile = widget.profile;
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final profiles = await _profileStorage.loadProfiles();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
    });
  }

  // Removed _addProfile and _showAddProfileDialog and _navigateToTest

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _profiles.isEmpty ? _buildEmptyState() : _buildDashboard(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              'NO PROFILES YET.\nCREATE ONE TO START.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: Color(0xFF666666),
              ),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (context) => const ProfileSelectionScreen(),
                ),
                (route) => false,
              );
            },
            child: const Text('SWITCH PROFILES'),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'HELLO ! ${_activeProfile.name.toUpperCase()}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    color: const Color(0xFFD4AF37), // Gold accent
                  ),
                ),
                _buildProfileSelector(),
              ],
            ),
            const SizedBox(height: 32),
            if (_activeProfile.testResult != null) ...[
              const Text(
                'YOUR LATEST RESULTS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                  color: Color(0xFFA0A0A0),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(color: Color(0xFF1C1C1C)),
                child: Column(
                  children: [
                    _buildMiniChartTabs(),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 120, // Mini chart height
                      child: _buildMiniChart(),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'PREVIEW',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.5,
                        color: Color(0xFF666666),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1C),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.monitor_heart_outlined,
                      size: 32,
                      color: Color(0xFF666666),
                    ),
                    SizedBox(height: 14),
                    Text(
                      'NO TEST RESULTS YET',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileSelector() {
    return PopupMenuButton<dynamic>(
      icon: const Icon(Icons.person, color: Colors.white),
      color: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      onSelected: (dynamic value) {
        if (value is String && value == 'ADD_NEW') {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(
              builder: (context) => const ProfileSelectionScreen(),
            ),
            (route) => false,
          );
        } else if (value is Profile) {
          setState(() {
            _activeProfile = value;
          });
        }
      },
      itemBuilder: (BuildContext context) {
        List<PopupMenuEntry<dynamic>> items = _profiles.map((Profile profile) {
          return PopupMenuItem<dynamic>(
            value: profile,
            child: Text(
              profile.name.toUpperCase(),
              style: TextStyle(
                color: _activeProfile.name == profile.name
                    ? const Color(0xFFD4AF37)
                    : Colors.white,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          );
        }).toList();

        items.add(const PopupMenuDivider(height: 1));
        items.add(
          const PopupMenuItem<dynamic>(
            value: 'ADD_NEW',
            child: Text(
              'SWITCH PROFILES',
              style: TextStyle(
                color: Color(0xFF666666),
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
          ),
        );
        return items;
      },
    );
  }

  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: _showSoundCheckDialog,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
          ),
          child: const Text('CHECK EARBUDS'),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ScreenTest(profile: _activeProfile),
              ),
            ).then((_) => _loadProfiles());
          },
          child: const Text('START TEST'),
        ),
        const SizedBox(height: 16),
        if (_activeProfile.testResult != null)
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ResultsScreen(profile: _activeProfile),
                ),
              ).then((_) => _loadProfiles());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF282828),
              foregroundColor: Colors.white,
            ),
            child: const Text('CHECK MY EAR PROFILE'),
          ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(
                builder: (context) => const ProfileSelectionScreen(),
              ),
              (route) => false,
            );
          },
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF666666)),
          child: const Text('SWITCH PROFILE'),
        ),
      ],
    );
  }

  Widget _buildMiniChartTabs() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildMiniTab(0, 'LEFT'),
        const Text(' | ', style: TextStyle(color: Color(0xFF666666))),
        _buildMiniTab(1, 'RIGHT'),
        const Text(' | ', style: TextStyle(color: Color(0xFF666666))),
        _buildMiniTab(2, 'ALL'),
      ],
    );
  }

  Widget _buildMiniTab(int index, String label) {
    final isSelected = _selectedChartTab == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedChartTab = index;
        });
      },
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
          letterSpacing: 1,
          color: isSelected ? const Color(0xFFD4AF37) : const Color(0xFF666666),
        ),
      ),
    );
  }

  Widget _buildMiniChart() {
    final result = _activeProfile.testResult;
    if (result == null) return const SizedBox();

    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        minY: 120, // Start y-axis
        maxY: -10, // Max DB (inverted)
        lineBarsData: _buildMiniChartLines(result),
      ),
    );
  }

  List<LineChartBarData> _buildMiniChartLines(dynamic result) {
    List<LineChartBarData> lineBars = [];
    final frequencies = [250, 500, 1000, 2000, 4000, 8000];

    // Left Ear
    if (_selectedChartTab == 0 || _selectedChartTab == 2) {
      final leftSpots = frequencies.map((freq) {
        final val =
            result.leftEarResults[freq] ?? 120; // Default to bottom if missing
        return FlSpot(freq.toDouble(), val.toDouble());
      }).toList();

      lineBars.add(
        LineChartBarData(
          spots: leftSpots,
          isCurved: false,
          color: const Color(0xFFD4AF37), // Gold
          barWidth: 2,
          isStrokeCapRound: false,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(
            show: true,
            color: const Color(0xFFD4AF37).withValues(alpha: 0.1),
          ),
        ),
      );
    }

    // Right Ear
    if (_selectedChartTab == 1 || _selectedChartTab == 2) {
      final rightSpots = frequencies.map((freq) {
        final val =
            result.rightEarResults[freq] ?? 120; // Default to bottom if missing
        return FlSpot(freq.toDouble(), val.toDouble());
      }).toList();

      lineBars.add(
        LineChartBarData(
          spots: rightSpots,
          isCurved: false,
          color: Colors.white, // White for right ear contrast
          barWidth: 2,
          isStrokeCapRound: false,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(
            show: true,
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
      );
    }

    return lineBars;
  }

  void _showSoundCheckDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "CHECK YOUR EARBUDS",
          style: TextStyle(letterSpacing: 1),
        ),
        content: const Text(
          "Make sure you can hear the sound in the correct ear.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            child: const Text("CHECK LEFT EAR"),
            onPressed: () => _audioGenerator.playTone(
              frequency: 1000,
              amplitude: 40,
              channel: 'left',
              duration: 1000,
            ),
          ),
          TextButton(
            child: const Text("CHECK RIGHT EAR"),
            onPressed: () => _audioGenerator.playTone(
              frequency: 1000,
              amplitude: 40,
              channel: 'right',
              duration: 1000,
            ),
          ),
          TextButton(
            child: const Text("DONE"),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
