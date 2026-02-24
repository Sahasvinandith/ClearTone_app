class HearingTestResult {
  // Using a map to store the hearing threshold (in dB) for each frequency (in Hz).
  final Map<int, int> leftEarResults;
  final Map<int, int> rightEarResults;
  final DateTime date;

  HearingTestResult({
    required this.leftEarResults,
    required this.rightEarResults,
    DateTime? date,
  }) : date = date ?? DateTime.now();

  // Factory constructor to create a HearingTestResult from a JSON object
  factory HearingTestResult.fromJson(Map<String, dynamic> json) {
    // The keys in the JSON map are strings, so we need to convert them back to integers.
    final leftEarMap = (json['leftEarResults'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(int.parse(key), value as int),
    );
    final rightEarMap = (json['rightEarResults'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(int.parse(key), value as int),
    );
    final date = json.containsKey('date')
        ? DateTime.parse(json['date'])
        : DateTime.now();

    return HearingTestResult(
      leftEarResults: leftEarMap,
      rightEarResults: rightEarMap,
      date: date,
    );
  }

  // Method to convert a HearingTestResult object to a JSON object
  Map<String, dynamic> toJson() {
    // The integer keys in the maps must be converted to strings to be valid JSON keys.
    final leftEarJson = leftEarResults.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final rightEarJson = rightEarResults.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    return {
      'leftEarResults': leftEarJson,
      'rightEarResults': rightEarJson,
      'date': date.toIso8601String(),
    };
  }
}
