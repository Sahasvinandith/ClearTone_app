import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:share_plus/share_plus.dart';
import '../models/hearing_test_result.dart';
import '../models/profile.dart';

class ResultsScreen extends StatefulWidget {
  final Profile profile;

  const ResultsScreen({required this.profile, super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
      gridData: const FlGridData(show: true),
      titlesData: FlTitlesData(
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, meta) {
              return Text('${value.toInt()} dB');
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
                      text = '1k';
                      break;
                    case 2000:
                      text = '2k';
                      break;
                    case 4000:
                      text = '4k';
                      break;
                    case 8000:
                      text = '8k';
                      break;
                    default:
                      return Container();
                  }
                  return SideTitleWidget(
                      axisSide: meta.axisSide,
                      space: 4,
                      child: Text(text, style: style));
                })),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: true),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: color,
          barWidth: 4,
          isStrokeCapRound: true,
          belowBarData: BarAreaData(show: false),
        ),
      ],
      minX: 0,
      maxX: 8250, // Give some space on the right
      minY: 100, // Inverted Y-axis
      maxY: -10, // Inverted Y-axis
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
    result.rightEarResults.forEach((freq, db) => report += '$freq Hz: $db dB\n');

    Share.share(report);
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.profile.testResult;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Results'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Left Ear'),
            Tab(text: 'Right Ear'),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text('Audiogram for ${widget.profile.name}',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
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
                              _createChartData(result.leftEarResults, Colors.blue)),
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
                              _createChartData(result.rightEarResults, Colors.red)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (result == null) const Text('No test results available.'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _shareResults(context),
              child: const Text('Share Results'),
            ),
          ],
        ),
      ),
    );
  }
}
