import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import '../models/profile.dart';
import '../models/hearing_test_result.dart';

class ResultsScreen extends StatefulWidget {
  final Profile profile;

  const ResultsScreen({required this.profile, super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // Helper to create the line chart data for a single ear
  LineChartData _createChartData(
    List<HearingTestResult> results,
    bool isLeftEar,
    Color baseColor,
  ) {
    List<LineChartBarData> lineBars = [];

    for (int i = 0; i < results.length; i++) {
      final data = isLeftEar
          ? results[i].leftEarResults
          : results[i].rightEarResults;
      final sortedEntries = data.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final spots = sortedEntries
          .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
          .toList();

      // Adjust opacity based on how old the test is (newest is fully opaque)
      // If we have 3 tests: i=0 (oldest), i=1, i=2 (newest)
      // opacity = (i + 1) / results.length  => 0.33, 0.66, 1.0 (for 3 tests)
      final double opacity = (i + 1) / results.length;
      final Color color = baseColor.withAlpha((opacity * 255).toInt());

      lineBars.add(
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: i == results.length - 1 ? 3 : 2, // Highlight newest test
          isStrokeCapRound: false,
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(
                  size: i == results.length - 1 ? 8 : 6,
                  color: color,
                  strokeWidth: 0,
                ),
          ),
        ),
      );
    }

    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: true,
        drawHorizontalLine: true,
        horizontalInterval: 20,
        verticalInterval: 1,
        getDrawingHorizontalLine: (value) => FlLine(
          color: const Color(0xFF3A3A3A).withValues(alpha: 0.5),
          strokeWidth: 1,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: const Color(0xFF3A3A3A).withValues(alpha: 0.5),
          strokeWidth: 1,
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, meta) {
              return Text(
                '${value.toInt()} dB',
                style: const TextStyle(
                  color: Color(0xFFA0A0A0),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            getTitlesWidget: (value, meta) {
              const style = TextStyle(
                fontSize: 10,
                color: Color(0xFFA0A0A0),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              );
              String text;
              switch (value.toInt()) {
                case 250:
                  text = '250';
                  break;
                case 500:
                  text = '500';
                  break;
                case 1000:
                  text = '1K';
                  break;
                case 2000:
                  text = '2K';
                  break;
                case 4000:
                  text = '4K';
                  break;
                case 8000:
                  text = '8K';
                  break;
                default:
                  return Container();
              }
              return SideTitleWidget(
                axisSide: meta.axisSide,
                space: 4,
                child: Text(text, style: style),
              );
            },
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      lineBarsData: lineBars,
      minX: 0,
      maxX: 8250, // Give some space on the right
      minY: 100, // Inverted Y-axis
      maxY: -10, // Inverted Y-axis
    );
  }

  // Helper to create the combined line chart data
  LineChartData _createCombinedChartData(
    List<HearingTestResult> results,
    Color leftBaseColor,
    Color rightBaseColor,
  ) {
    List<LineChartBarData> lineBars = [];

    for (int i = 0; i < results.length; i++) {
      final double opacity = (i + 1) / results.length;
      final Color leftColor = leftBaseColor.withAlpha((opacity * 255).toInt());
      final Color rightColor = rightBaseColor.withAlpha(
        (opacity * 255).toInt(),
      );
      final double barWidth = i == results.length - 1 ? 3 : 2;
      final double dotSize = i == results.length - 1 ? 8 : 6;

      // Left Ear
      final leftSortedEntries = results[i].leftEarResults.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final leftSpots = leftSortedEntries
          .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
          .toList();

      lineBars.add(
        LineChartBarData(
          spots: leftSpots,
          isCurved: false,
          color: leftColor,
          barWidth: barWidth,
          isStrokeCapRound: false,
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(
                  size: dotSize,
                  color: leftColor,
                  strokeWidth: 0,
                ),
          ),
        ),
      );

      // Right Ear
      final rightSortedEntries = results[i].rightEarResults.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final rightSpots = rightSortedEntries
          .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
          .toList();

      lineBars.add(
        LineChartBarData(
          spots: rightSpots,
          isCurved: false,
          color: rightColor,
          barWidth: barWidth,
          isStrokeCapRound: false,
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(
                  size: dotSize,
                  color: rightColor,
                  strokeWidth: 0,
                ),
          ),
        ),
      );
    }

    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: true,
        drawHorizontalLine: true,
        horizontalInterval: 20,
        verticalInterval: 1,
        getDrawingHorizontalLine: (value) => FlLine(
          color: const Color(0xFF3A3A3A).withValues(alpha: 0.5),
          strokeWidth: 1,
        ),
        getDrawingVerticalLine: (value) => FlLine(
          color: const Color(0xFF3A3A3A).withValues(alpha: 0.5),
          strokeWidth: 1,
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, meta) {
              return Text(
                '${value.toInt()} dB',
                style: const TextStyle(
                  color: Color(0xFFA0A0A0),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            getTitlesWidget: (value, meta) {
              const style = TextStyle(
                fontSize: 10,
                color: Color(0xFFA0A0A0),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              );
              String text;
              switch (value.toInt()) {
                case 250:
                  text = '250';
                  break;
                case 500:
                  text = '500';
                  break;
                case 1000:
                  text = '1K';
                  break;
                case 2000:
                  text = '2K';
                  break;
                case 4000:
                  text = '4K';
                  break;
                case 8000:
                  text = '8K';
                  break;
                default:
                  return Container();
              }
              return SideTitleWidget(
                axisSide: meta.axisSide,
                space: 4,
                child: Text(text, style: style),
              );
            },
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      lineBarsData: lineBars,
      minX: 0,
      maxX: 8250,
      minY: 100,
      maxY: -10,
    );
  }

  // Function to handle sharing
  void _shareResults(BuildContext context) {
    final results = widget.profile.testResults;
    if (results.isEmpty) return;

    String report = 'Hearing Test Results for ${widget.profile.name}:\n\n';

    for (int i = 0; i < results.length; i++) {
      final testNumber = i + 1;
      final result = results[i];
      report += '--- Test $testNumber ---\n';
      report += 'Left Ear:\n';
      result.leftEarResults.forEach(
        (freq, db) => report += '$freq Hz: $db dB\n',
      );
      report += '\nRight Ear:\n';
      result.rightEarResults.forEach(
        (freq, db) => report += '$freq Hz: $db dB\n',
      );
      report += '\n';
    }

    Share.share(report);
  }

  // Function to show results in a popup
  void _showResultsPopup(BuildContext context) {
    final results = widget.profile.testResults;
    if (results.isEmpty) return;

    String report = 'Hearing Test Results for ${widget.profile.name}:\n\n';

    for (int i = 0; i < results.length; i++) {
      final testNumber = i + 1;
      final result = results[i];
      report += '--- Test $testNumber ---\n';
      report += 'Left Ear:\n';
      result.leftEarResults.forEach(
        (freq, db) => report += '$freq Hz: $db dB\n',
      );
      report += '\nRight Ear:\n';
      result.rightEarResults.forEach(
        (freq, db) => report += '$freq Hz: $db dB\n',
      );
      report += '\n';
    }

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('RAW DATA', style: TextStyle(letterSpacing: 2)),
          content: SingleChildScrollView(
            child: Text(
              report,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CLOSE'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.profile.testResults;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TEST RESULTS', style: TextStyle(letterSpacing: 2)),
      ),
      body: Column(
        children: [
          // iOS Pill style TabBar container
          Container(
            padding: const EdgeInsets.fromLTRB(21, 12, 21, 21),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1C),
                borderRadius: BorderRadius.circular(36),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: TabBar(
                controller: _tabController,
                indicatorPadding: const EdgeInsets.all(4),
                tabs: const [
                  Tab(text: 'LEFT EAR'),
                  Tab(text: 'RIGHT EAR'),
                  Tab(text: 'COMBINED'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 3,
                      height: 14,
                      color: const Color(0xFFD4AF37),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'AUDIOGRAM FOR ${widget.profile.name.toUpperCase()}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                        color: const Color(0xFFA0A0A0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (results.isNotEmpty)
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Left Ear Chart
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 1000,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16.0, right: 16.0),
                        child: LineChart(
                          _createChartData(
                            results,
                            true, // isLeftEar
                            const Color(0xFFD4AF37), // Primary Gold
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Right Ear Chart
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 1000,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16.0, right: 16.0),
                        child: LineChart(
                          _createChartData(
                            results,
                            false, // isLeftEar
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Right Ear Chart
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 1000,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16.0, right: 16.0),
                        child: LineChart(
                          _createCombinedChartData(
                            results,
                            const Color(0xFFD4AF37),
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (results.isEmpty) const Text('NO TEST RESULTS AVAILABLE.'),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _shareResults(context),
                  child: const Text('SHARE RESULTS'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () => _showResultsPopup(context),
                  child: const Text('VIEW RESULTS'),
                ),
              ],
            ),
          ),
        ],
      ),
      // NO PADDING AT BOTTOM OF BODY SINCE IT AFFECTS TABS
    );
  }
}
