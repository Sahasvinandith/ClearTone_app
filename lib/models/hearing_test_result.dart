class HearingTestResult {
  // Using a map to store the hearing threshold (in dB) for each frequency (in Hz).
  final Map<int, int> leftEarResults;
  final Map<int, int> rightEarResults;

  HearingTestResult({required this.leftEarResults, required this.rightEarResults});
}
