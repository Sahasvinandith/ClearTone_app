import 'dart:convert';

import 'hearing_test_result.dart';

class Profile {
  final String name;
  HearingTestResult? testResult;

  Profile({required this.name, this.testResult});

  // Factory constructor to create a Profile from a JSON string
  factory Profile.fromJson(Map<String, dynamic> jsonData) {
    HearingTestResult? testResult;
    if (jsonData.containsKey('testResult')) {
      testResult = HearingTestResult.fromJson(jsonData['testResult']);
    }

    return Profile(
      name: jsonData['name'],
      testResult: testResult,
    );
  }

  // Method to convert a Profile object to a JSON object
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = {
      'name': name,
    };

    if (testResult != null) {
      data['testResult'] = testResult!.toJson();
    }

    return data;
  }
}
