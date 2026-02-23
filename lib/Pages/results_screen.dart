import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import '../models/profile.dart';

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

  // Helper to create the line chart data
  LineChartData _createChartData(Map<int, int> data, Color color) {
    // Sort entries by frequency for correct line drawing
    final sortedEntries = data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final spots = sortedEntries
        .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
        .toList();

    return LineChartData(
      gridData: FlGridData(
        show: true,
        getDrawingHorizontalLine: (value) =>
            const FlLine(color: Color(0xFF2A2A2A), strokeWidth: 1),
        getDrawingVerticalLine: (value) =>
            const FlLine(color: Color(0xFF2A2A2A), strokeWidth: 1),
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
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false, // brutalist: sharp straight lines instead of curves
          color: color,
          barWidth: 3,
          isStrokeCapRound: false, // zero radius
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(size: 8, color: color, strokeWidth: 0),
          ),
        ),
      ],
      minX: 0,
      maxX: 8250, // Give some space on the right
      minY: 100, // Inverted Y-axis
      maxY: -10, // Inverted Y-axis
    );
  }

  // Helper to create the line chart data
  LineChartData _createCombinedChartData(
    Map<int, int> leftData,
    Color leftColor,
    Map<int, int> rightData,
    Color rightColor,
  ) {
    // Sort entries by frequency for correct line drawing
    final leftSortedEntries = leftData.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final leftSpots = leftSortedEntries
        .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
        .toList();
    final rightSortedEntries = rightData.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final rightSpots = rightSortedEntries
        .map((e) => FlSpot(e.key.toDouble(), e.value.toDouble()))
        .toList();

    return LineChartData(
      gridData: FlGridData(
        show: true,
        getDrawingHorizontalLine: (value) =>
            const FlLine(color: Color(0xFF2A2A2A), strokeWidth: 1),
        getDrawingVerticalLine: (value) =>
            const FlLine(color: Color(0xFF2A2A2A), strokeWidth: 1),
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
      lineBarsData: [
        LineChartBarData(
          spots: leftSpots,
          isCurved: false,
          color: leftColor,
          barWidth: 3,
          isStrokeCapRound: false,
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(size: 8, color: leftColor, strokeWidth: 0),
          ),
        ),
        LineChartBarData(
          spots: rightSpots,
          isCurved: false,
          color: rightColor,
          barWidth: 3,
          isStrokeCapRound: false,
          belowBarData: BarAreaData(show: false),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, percent, barData, index) =>
                FlDotSquarePainter(size: 8, color: rightColor, strokeWidth: 0),
          ),
        ),
      ],
      minX: 0,
      maxX: 8250,
      minY: 100,
      maxY: -10,
    );
  }

  // Function to handle sharing
  void _shareResults(BuildContext context) {
    final result = widget.profile.testResult;
    if (result == null) return;

    String report = 'Hearing Test Results for ${widget.profile.name}:\n\n';
    report += 'Left Ear:\n';
    result.leftEarResults.forEach((freq, db) => report += '$freq Hz: $db dB\n');
    report += '\nRight Ear:\n';
    result.rightEarResults.forEach(
      (freq, db) => report += '$freq Hz: $db dB\n',
    );

    Share.share(report);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.profile.testResult;

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
          if (result != null)
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
                            result.leftEarResults,
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
                            result.rightEarResults,
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
                            result.leftEarResults,
                            const Color(0xFFD4AF37),
                            result.rightEarResults,
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (result == null) const Text('NO TEST RESULTS AVAILABLE.'),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: ElevatedButton(
              onPressed: () => _shareResults(context),
              child: const Text('SHARE RESULTS'),
            ),
          ),
        ],
      ),
      // NO PADDING AT BOTTOM OF BODY SINCE IT AFFECTS TABS
    );
  }
}
