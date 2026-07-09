import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/hearing_test_result.dart';
import '../models/profile.dart';
import 'screen_test.dart';

const Map<int, double> _freqToX = {
  250: 0,
  500: 1,
  1000: 2,
  2000: 3,
  4000: 4,
  8000: 5,
};

class ProfileTabScreen extends StatefulWidget {
  final Profile profile;
  final int startTestRequest;

  const ProfileTabScreen({
    super.key,
    required this.profile,
    this.startTestRequest = 0,
  });

  @override
  State<ProfileTabScreen> createState() => _ProfileTabScreenState();
}

class _ProfileTabScreenState extends State<ProfileTabScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (widget.startTestRequest > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startTest();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ProfileTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.startTestRequest != oldWidget.startTestRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startTest();
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _shareResults() {
    final results = widget.profile.testResults;
    if (results.isEmpty) return;

    final buffer = StringBuffer(
      'Hearing Test Results for ${widget.profile.name}\n\n',
    );
    for (int i = 0; i < results.length; i++) {
      final result = results[i];
      buffer.writeln('Test ${i + 1} - ${_formatDate(result.date)}');
      buffer.writeln('Left Ear');
      result.leftEarResults.forEach((freq, db) {
        buffer.writeln('$freq Hz: $db dB');
      });
      buffer.writeln('Right Ear');
      result.rightEarResults.forEach((freq, db) {
        buffer.writeln('$freq Hz: $db dB');
      });
      buffer.writeln();
    }

    Share.share(buffer.toString());
  }

  void _showResultsPopup() {
    final results = widget.profile.testResults;
    if (results.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF1C1C1C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.monitor_heart_outlined,
                        color: Color(0xFFD4AF37),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${widget.profile.name.toUpperCase()} RESULTS',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        return _ResultDetailCard(
                          title: 'Test ${index + 1}',
                          result: results[index],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CLOSE'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _startTest() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'TRY ANOTHER TEST',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 20),
              _TestModeButton(
                title: 'STANDARD TEST',
                subtitle: 'More confirmations per threshold',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ScreenTest(profile: widget.profile, requiredHits: 3),
                    ),
                  ).then((_) => setState(() {}));
                },
              ),
              const SizedBox(height: 12),
              _TestModeButton(
                title: 'ADVANCED TEST',
                subtitle: 'Faster threshold confirmation',
                isAdvanced: true,
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ScreenTest(profile: widget.profile, requiredHits: 2),
                    ),
                  ).then((_) => setState(() {}));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.profile.testResults;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.profile.name.toUpperCase(),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: const Color(0xFFD4AF37),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                results.isEmpty
                    ? 'No hearing test has been completed yet.'
                    : '${results.length} saved test${results.length == 1 ? '' : 's'}',
                style: const TextStyle(color: Color(0xFF888888)),
              ),
              const SizedBox(height: 22),
              if (results.isEmpty)
                Expanded(child: _buildEmptyState())
              else ...[
                _buildChartTabs(),
                const SizedBox(height: 18),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildChart(results, true),
                      _buildChart(results, false),
                      _buildCombinedChart(results),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _buildActions(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.monitor_heart_outlined,
            color: Color(0xFF666666),
            size: 44,
          ),
          const SizedBox(height: 16),
          const Text(
            'NO RESULTS YET',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: _startTest,
            child: const Text('START TEST'),
          ),
        ],
      ),
    );
  }

  Widget _buildChartTabs() {
    return Container(
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
          Tab(text: 'LEFT'),
          Tab(text: 'RIGHT'),
          Tab(text: 'ALL'),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _showResultsPopup,
                icon: const Icon(Icons.visibility),
                label: const Text('VIEW RESULTS'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _shareResults,
                icon: const Icon(Icons.share),
                label: const Text('SHARE'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF3A3A3A)),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _startTest,
          icon: const Icon(Icons.refresh),
          label: const Text('TRY ANOTHER TEST'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF282828),
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildChart(List<HearingTestResult> results, bool isLeftEar) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 12),
      child: LineChart(
        _createChartData(
          results,
          isLeftEar,
          isLeftEar ? const Color(0xFFD4AF37) : Colors.white,
        ),
      ),
    );
  }

  Widget _buildCombinedChart(List<HearingTestResult> results) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 12),
      child: LineChart(
        _createCombinedChartData(
          results,
          const Color(0xFFD4AF37),
          Colors.white,
        ),
      ),
    );
  }

  LineChartData _createChartData(
    List<HearingTestResult> results,
    bool isLeftEar,
    Color baseColor,
  ) {
    final lineBars = <LineChartBarData>[];

    for (int i = 0; i < results.length; i++) {
      final data = isLeftEar
          ? results[i].leftEarResults
          : results[i].rightEarResults;
      final sortedEntries = data.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final spots = sortedEntries
          .map(
            (e) =>
                FlSpot(_freqToX[e.key] ?? e.key.toDouble(), e.value.toDouble()),
          )
          .toList();

      final opacity = (i + 1) / results.length;
      final color = baseColor.withAlpha((opacity * 255).toInt());

      lineBars.add(
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: i == results.length - 1 ? 3 : 2,
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

    return _baseChartData(lineBars);
  }

  LineChartData _createCombinedChartData(
    List<HearingTestResult> results,
    Color leftBaseColor,
    Color rightBaseColor,
  ) {
    final lineBars = <LineChartBarData>[];

    for (int i = 0; i < results.length; i++) {
      final opacity = (i + 1) / results.length;
      final leftColor = leftBaseColor.withAlpha((opacity * 255).toInt());
      final rightColor = rightBaseColor.withAlpha((opacity * 255).toInt());
      final barWidth = i == results.length - 1 ? 3.0 : 2.0;
      final dotSize = i == results.length - 1 ? 8.0 : 6.0;

      final leftEntries = results[i].leftEarResults.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      lineBars.add(_lineForEntries(leftEntries, leftColor, barWidth, dotSize));

      final rightEntries = results[i].rightEarResults.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      lineBars.add(
        _lineForEntries(rightEntries, rightColor, barWidth, dotSize),
      );
    }

    return _baseChartData(lineBars);
  }

  LineChartBarData _lineForEntries(
    List<MapEntry<int, int>> entries,
    Color color,
    double barWidth,
    double dotSize,
  ) {
    return LineChartBarData(
      spots: entries
          .map(
            (e) =>
                FlSpot(_freqToX[e.key] ?? e.key.toDouble(), e.value.toDouble()),
          )
          .toList(),
      isCurved: false,
      color: color,
      barWidth: barWidth,
      isStrokeCapRound: false,
      belowBarData: BarAreaData(show: false),
      dotData: FlDotData(
        show: true,
        getDotPainter: (spot, percent, barData, index) =>
            FlDotSquarePainter(size: dotSize, color: color, strokeWidth: 0),
      ),
    );
  }

  LineChartData _baseChartData(List<LineChartBarData> lineBars) {
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
              const labels = ['250', '500', '1K', '2K', '4K', '8K'];
              final index = value.round();
              if (value != index.toDouble() || index < 0 || index > 5) {
                return Container();
              }
              return SideTitleWidget(
                axisSide: meta.axisSide,
                space: 4,
                child: Text(
                  labels[index],
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFA0A0A0),
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
      minX: -0.5,
      maxX: 5.5,
      minY: 100,
      maxY: -10,
    );
  }
}

class _ResultDetailCard extends StatelessWidget {
  final String title;
  final HearingTestResult result;

  const _ResultDetailCard({required this.title, required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title  |  ${_formatDate(result.date)}',
            style: const TextStyle(
              color: Color(0xFFD4AF37),
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),
          _EarResultGrid(label: 'LEFT EAR', values: result.leftEarResults),
          const SizedBox(height: 12),
          _EarResultGrid(label: 'RIGHT EAR', values: result.rightEarResults),
        ],
      ),
    );
  }
}

class _EarResultGrid extends StatelessWidget {
  final String label;
  final Map<int, int> values;

  const _EarResultGrid({required this.label, required this.values});

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: entries.map((entry) {
            return Container(
              width: 88,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatFrequency(entry.key),
                    style: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.value} dB',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _TestModeButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isAdvanced;

  const _TestModeButton({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isAdvanced = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isAdvanced ? const Color(0xFFD4AF37) : Colors.white70;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isAdvanced
              ? const Color(0xFFD4AF37).withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: accent),
          ],
        ),
      ),
    );
  }
}

String _formatFrequency(int frequency) {
  if (frequency >= 1000) return '${frequency ~/ 1000}K Hz';
  return '$frequency Hz';
}

String _formatDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}
