import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:gherkin/gherkin.dart';

class FlutterRunProcessHandler extends ProcessHandler {
  static const String FAIL_COLOR = "\u001b[33;31m"; // red
  static const String RESET_COLOR = "\u001b[33;0m";

  static RegExp _observatoryDebuggerUriRegex = RegExp(
      r"observatory debugger .*[:]? (http[s]?:.*\/).*",
      caseSensitive: false,
      multiLine: false);

  static RegExp _noConnectedDeviceRegex =
      RegExp(r"no connected device", caseSensitive: false, multiLine: false);

  static RegExp _restartedApplicationSuccessRegex = RegExp(
      r"Restarted application (.*)ms.",
      caseSensitive: false,
      multiLine: false);

  Process _runningProcess;
  Stream<String> _processStdoutStream;
  List<StreamSubscription> _openSubscriptions = <StreamSubscription>[];
  String _workingDirectory;
  String _appTarget;
  bool _buildApp = true;
  String _buildFlavor;
  String _deviceTargetId;
  String _iOSDeviceName;
  String currentObservatoryUri;
  List<String> _permissions;
  String _bundleId;

  void setBypassPermissions(List<String> value) {
    _permissions = value;
  }

  void setApplicationTargetFile(String targetPath) {
    _appTarget = targetPath;
  }

  void setWorkingDirectory(String workingDirectory) {
    _workingDirectory = workingDirectory;
  }

  void setBuildFlavor(String buildFlavor) {
    _buildFlavor = buildFlavor;
  }

  void setDeviceTargetId(String deviceTargetId) {
    _deviceTargetId = deviceTargetId;
  }

  void setiOSDeviceName(String iOSDeviceName) {
    _iOSDeviceName = iOSDeviceName;
  }

  void setBundleId(String bundleId) {
    _bundleId = bundleId;
  }

  void setBuildRequired(bool build) {
    _buildApp = build;
  }

  Future<void> bypassPermissions(String iOSDeviceName, String bundleId, List<String> permissions) async {
    if(iOSDeviceName.isEmpty || bundleId.isEmpty){
      throw Exception(
          "FlutterRunProcessHandler: to bypass permissions, bundleId and targetDeviceId must be present");
    }
    final arguments = ["--byName", iOSDeviceName, "--bundle", bundleId, "--setPermissions"];
    for (int i = 0; i < permissions.length; i++) {
      arguments.add("${permissions[i]}=YES");
    }
    await Process.run('applesimutils', arguments);
  }


  @override
  Future<void> run() async {
    final arguments = ["run", "--target=$_appTarget"];

    if (_buildApp == false) {
      arguments.add("--no-build");
    }

    if (_buildFlavor.isNotEmpty) {
      arguments.add("--flavor=$_buildFlavor");
    }

    if (_deviceTargetId.isNotEmpty) {
      arguments.add("--device-id=$_deviceTargetId");
    }

    if(_permissions.isNotEmpty){
      await bypassPermissions(_iOSDeviceName, _bundleId, _permissions);
    }

    _runningProcess = await Process.start("flutter", arguments,
        workingDirectory: _workingDirectory, runInShell: true);
    _processStdoutStream =
        _runningProcess.stdout.transform(utf8.decoder).asBroadcastStream();

    _openSubscriptions.add(_runningProcess.stderr.listen((events) {
      stderr.writeln(
          "${FAIL_COLOR}Flutter run error: ${String.fromCharCodes(events)}$RESET_COLOR");
    }));
  }

  @override
  Future<int> terminate() async {
    int exitCode = -1;
    _ensureRunningProcess();
    if (_runningProcess != null) {
      _runningProcess.stdin.write("q");
      _openSubscriptions.forEach((s) => s.cancel());
      _openSubscriptions.clear();
      exitCode = await _runningProcess.exitCode;
      _runningProcess = null;
    }

    return exitCode;
  }

  Future<bool> restart({Duration timeout = const Duration(seconds: 90)}) async {
    _ensureRunningProcess();
    _runningProcess.stdin.write("R");
    await _waitForStdOutMessage(
      _restartedApplicationSuccessRegex,
      "Timeout waiting for app restart",
      timeout,
    );

    // it seems we need a small delay here otherwise the flutter driver fails to
    // consistently connect
    await Future.delayed(Duration(seconds: 1));

    return Future.value(true);
  }

  Future<String> waitForObservatoryDebuggerUri() async {
    currentObservatoryUri = await _waitForStdOutMessage(
        _observatoryDebuggerUriRegex,
        "Timeout while waiting for observatory debugger uri");

    return currentObservatoryUri;
  }

  Future<String> _waitForStdOutMessage(RegExp matcher, String timeoutMessage,
      [Duration timeout = const Duration(seconds: 120)]) {
    _ensureRunningProcess();
    final completer = Completer<String>();
    StreamSubscription sub;
    sub = _processStdoutStream.timeout(timeout, onTimeout: (_) {
      sub?.cancel();
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException(timeoutMessage, timeout));
      }
    }).listen((logLine) {
      // uncomment for debug output
      // stdout.write(logLine);
      if (matcher.hasMatch(logLine)) {
        sub?.cancel();
        if (!completer.isCompleted) {
          completer.complete(matcher.firstMatch(logLine).group(1));
        }
      } else if (_noConnectedDeviceRegex.hasMatch(logLine)) {
        sub?.cancel();
        if (!completer.isCompleted) {
          stderr.writeln(
              "${FAIL_COLOR}No connected devices found to run app on and tests against$RESET_COLOR");
        }
      }
    }, cancelOnError: true);

    return completer.future;
  }

  void _ensureRunningProcess() {
    if (_runningProcess == null) {
      throw Exception(
          "FlutterRunProcessHandler: flutter run process is not active");
    }
  }
}
