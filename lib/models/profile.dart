import 'hearing_test_result.dart';

class Profile {
  final String name;
  List<HearingTestResult> testResults;

  Profile({required this.name, List<HearingTestResult>? testResults})
    : testResults = testResults ?? [];

  // Factory constructor to create a Profile from a JSON string
  factory Profile.fromJson(Map<String, dynamic> jsonData) {
    List<HearingTestResult> testResults = [];
    if (jsonData.containsKey('testResults')) {
      testResults = (jsonData['testResults'] as List)
          .map((item) => HearingTestResult.fromJson(item))
          .toList();
    } else if (jsonData.containsKey('testResult')) {
      // Backwards compatibility
      testResults.add(HearingTestResult.fromJson(jsonData['testResult']));
    }

    return Profile(name: jsonData['name'], testResults: testResults);
  }

  // Method to convert a Profile object to a JSON object
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = {'name': name};

    if (testResults.isNotEmpty) {
      data['testResults'] = testResults.map((r) => r.toJson()).toList();
    }

    return data;
  }
}
