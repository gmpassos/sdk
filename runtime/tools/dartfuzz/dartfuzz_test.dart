// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:args/args.dart';
import 'package:matcher/matcher.dart';

import 'dartfuzz.dart';

const debug = false;
const sigkill = 9;
const negSigkill = -sigkill;
const timeout = 60; // in seconds
const dartHeapSize = 128; // in Mb

// Status of divergence report.
enum ReportStatus { reported, ignored, rerun, no_divergence }

/// Result of running a test.
class TestResult {
  const TestResult(this.output, this.stderr, this.exitCode);
  final String output;
  final String stderr;
  final int exitCode;
}

/// Command runner.
TestResult runCommand(List<String> cmd, Map<String, String> env) {
  var res = Process.runSync('timeout', [
    '-s',
    '$sigkill',
    '$timeout',
    ...cmd,
  ], environment: env);
  if (debug) {
    print(
      '\nrunning $cmd yields:\n'
      '${res.exitCode}\n${res.stdout}\n${res.stderr}\n',
    );
  }
  return TestResult(res.stdout, res.stderr, res.exitCode);
}

/// Abstraction for running one test in a particular mode.
abstract class TestRunner {
  TestResult run();
  late String description;

  // Factory.
  static TestRunner getTestRunner(
    String mode,
    String top,
    String tmp,
    Map<String, String> env,
    String fileName,
    Random rand,
  ) {
    var prefix = mode.substring(0, 3).toUpperCase();
    var tag = getTag(mode);
    var extraFlags = <String>[];
    // Every once in a while, stress test JIT.
    if (mode.startsWith('jit') && rand.nextInt(4) == 0) {
      final r = rand.nextInt(7);
      if (r == 0) {
        prefix += '-NOFIELDGUARDS';
        extraFlags += ['--use_field_guards=false'];
      } else if (r == 1) {
        prefix += '-NOINTRINSIFY';
        extraFlags += ['--intrinsify=false'];
      } else if (r == 2) {
        final freq = rand.nextInt(1000) + 500;
        prefix += '-COMPACTEVERY-$freq';
        extraFlags += ['--gc_every=$freq', '--use_compactor=true'];
      } else if (r == 3) {
        final freq = rand.nextInt(1000) + 500;
        prefix += '-MARKSWEEPEVERY-$freq';
        extraFlags += ['--gc_every=$freq', '--use_compactor=false'];
      } else if (r == 4) {
        final freq = rand.nextInt(100) + 50;
        prefix += '-DEPOPTEVERY-$freq';
        extraFlags += ['--deoptimize_every=$freq'];
      } else if (r == 5) {
        final freq = rand.nextInt(100) + 50;
        prefix += '-STACKTRACEEVERY-$freq';
        extraFlags += ['--stacktrace_every=$freq'];
      } else if (r == 6) {
        prefix += '-OPTCOUNTER';
        extraFlags += ['--optimization_counter_threshold=1'];
      }
    }
    // Every once in a while, use -O3 compiler.
    if (!mode.startsWith('djs') && rand.nextInt(4) == 0) {
      prefix += '-O3';
      extraFlags += ['--optimization_level=3'];
    }
    // Every once in a while, use the slowpath flag.
    if (!mode.startsWith('djs') && rand.nextInt(4) == 0) {
      prefix += '-SLOWPATH';
      extraFlags += ['--use-slow-path'];
    }
    // Every once in a while, use the deterministic flag.
    if (!mode.startsWith('djs') && rand.nextInt(4) == 0) {
      prefix += '-DET';
      extraFlags += ['--deterministic'];
    }
    // Construct runner.
    if (mode.startsWith('jit')) {
      return TestRunnerJIT(prefix, tag, top, tmp, env, fileName, extraFlags);
    } else if (mode.startsWith('aot')) {
      return TestRunnerAOT(prefix, tag, top, tmp, env, fileName, extraFlags);
    } else if (mode.startsWith('djs')) {
      return TestRunnerDJS(prefix, tag, top, tmp, env, fileName);
    }
    throw ('unknown runner in mode: $mode');
  }

  // Convert mode to tag.
  static String getTag(String mode) {
    if (mode.endsWith('debug-x64')) return 'DebugX64';
    if (mode.endsWith('debug-x64c')) return 'DebugX64C';
    if (mode.endsWith('debug-arm32')) return 'DebugSIMARM';
    if (mode.endsWith('debug-arm64')) return 'DebugSIMARM64';
    if (mode.endsWith('debug-arm64c')) return 'DebugSIMARM64C';
    if (mode.endsWith('debug-riscv32')) return 'DebugSIMRISCV32';
    if (mode.endsWith('debug-riscv64')) return 'DebugSIMRISCV64';
    if (mode.endsWith('x64')) return 'ReleaseX64';
    if (mode.endsWith('x64c')) return 'ReleaseX64C';
    if (mode.endsWith('arm32')) return 'ReleaseSIMARM';
    if (mode.endsWith('arm64')) return 'ReleaseSIMARM64';
    if (mode.endsWith('arm64c')) return 'ReleaseSIMARM64C';
    if (mode.endsWith('riscv32')) return 'ReleaseSIMRISCV32';
    if (mode.endsWith('riscv64')) return 'ReleaseSIMRISCV64';
    throw ('unknown tag in mode: $mode');
  }

  // Print steps to reproduce build and run.
  void printReproductionCommand();
}

/// Concrete test runner of Dart JIT.
class TestRunnerJIT implements TestRunner {
  TestRunnerJIT(
    String prefix,
    String tag,
    this.top,
    String tmp,
    this.env,
    this.fileName,
    List<String> extraFlags,
  ) {
    description = '$prefix-$tag';
    dart = '$top/out/$tag/dart';
    cmd = [dart, ...extraFlags, '--old_gen_heap_size=$dartHeapSize', fileName];
  }

  @override
  TestResult run() {
    return runCommand(cmd, env);
  }

  @override
  void printReproductionCommand() =>
      print(cmd.join(' ').replaceAll('$top/', ''));

  @override
  late String description;
  late String dart;
  late String fileName;
  final String top;
  Map<String, String> env;
  late List<String> cmd;
}

/// Concrete test runner of Dart AOT.
class TestRunnerAOT implements TestRunner {
  TestRunnerAOT(
    String prefix,
    String tag,
    this.top,
    this.tmp,
    Map<String, String> e,
    this.fileName,
    List<String> extraFlags,
  ) {
    description = '$prefix-$tag';
    precompiler = '$top/pkg/vm/tool/precompiler2';
    dart = '$top/out/$tag/dartaotruntime';
    snapshot = '$tmp/snapshot';
    env = Map<String, String>.from(e);
    env['DART_CONFIGURATION'] = tag;
    env['DART_VM_FLAGS'] = '--enable-asserts';
    cmd = [precompiler, ...extraFlags, fileName, snapshot];
  }

  @override
  TestResult run() {
    var result = runCommand(cmd, env);
    if (result.exitCode != 0) {
      return result;
    }
    return runCommand([
      dart,
      '--old_gen_heap_size=$dartHeapSize',
      snapshot,
    ], env);
  }

  @override
  void printReproductionCommand() {
    print(
      [
        "DART_CONFIGURATION='${env['DART_CONFIGURATION']}'",
        "DART_VM_FLAGS='${env['DART_VM_FLAGS']}'",
        ...cmd,
      ].join(' ').replaceAll('$top/', '').replaceAll('$tmp/', ''),
    );
    print(
      [
        dart,
        snapshot,
      ].join(' ').replaceAll('$top/', '').replaceAll('$tmp/', ''),
    );
  }

  @override
  late String description;
  late String precompiler;
  late String dart;
  late String fileName;
  late String snapshot;
  final String top;
  final String tmp;
  late Map<String, String> env;
  late List<String> cmd;
}

/// Concrete test runner of Dart2JS.
class TestRunnerDJS implements TestRunner {
  TestRunnerDJS(
    String prefix,
    String tag,
    this.top,
    this.tmp,
    this.env,
    this.fileName,
  ) {
    description = '$prefix-$tag';
    dart2js = '$top/sdk/bin/dart2js';
    js = '$tmp/out.js';
  }

  @override
  TestResult run() {
    var result = runCommand([dart2js, fileName, '-o', js], env);
    if (result.exitCode != 0) {
      return result;
    }
    return runCommand(['nodejs', js], env);
  }

  @override
  void printReproductionCommand() {
    print(
      [
        dart2js,
        fileName,
        '-o',
        js,
      ].join(' ').replaceAll('$top/', '').replaceAll('$tmp/', ''),
    );
    print('nodejs out.js');
  }

  @override
  late String description;
  late String dart2js;
  late String fileName;
  late String js;
  final String top;
  final String tmp;
  late Map<String, String> env;
}

/// Class to run fuzz testing.
class DartFuzzTest {
  DartFuzzTest(
    this.env,
    this.repeat,
    this.time,
    this.numOutputLines,
    this.trueDivergence,
    this.showStats,
    this.top,
    this.mode1,
    this.mode2,
    this.rerun,
    this.dartSdkRevision,
  );

  int run() {
    setup();

    print('\n$isolate: start');
    if (showStats) {
      showStatistics();
    }

    for (var i = 0; i < repeat; i++) {
      numTests++;
      seed = rand.nextInt(1 << 32);
      generateTest();
      runTest();
      if (showStats) {
        showStatistics();
      }
      // Timeout?
      if (timeIsUp()) {
        break;
      }
    }

    print('\n$isolate: done');
    showStatistics();
    print('');
    if (timeoutSeeds.isNotEmpty) {
      print('\n$isolate timeout: ' + timeoutSeeds.join(', '));
      print('');
    }
    if (skippedSeeds.isNotEmpty) {
      print('\n$isolate skipped: ' + skippedSeeds.join(', '));
      print('');
    }

    cleanup();
    return numDivergences;
  }

  void setup() {
    rand = Random();
    tmpDir = Directory.systemTemp.createTempSync('dart_fuzz');
    fileName = '${tmpDir.path}/fuzz.dart';

    // Testcase generation flags.

    // Only use FP when modes have the same architecture (to avoid false
    // divergences between 32-bit and 64-bit versions).
    fp = sameArchitecture(mode1, mode2);
    // Occasionally test FFI (if capable).
    ffi = ffiCapable(mode1, mode2) && (rand.nextInt(5) == 0);
    // Resort to flat types for the more expensive modes.
    flatTp = !nestedTypesAllowed(mode1, mode2);

    runner1 = TestRunner.getTestRunner(
      mode1,
      top,
      tmpDir.path,
      env,
      fileName,
      rand,
    );
    runner2 = TestRunner.getTestRunner(
      mode2,
      top,
      tmpDir.path,
      env,
      fileName,
      rand,
    );
    isolate =
        'Isolate (${tmpDir.path}) ${fp ? "" : "NO-"}FP ${ffi ? "" : "NO-"}FFI ${flatTp ? "" : "NO-"}FLAT : '
        '${runner1.description} - ${runner2.description}';

    start_time = DateTime.now().millisecondsSinceEpoch;
    current_time = start_time;
    report_time = start_time;
    end_time = start_time + max(0, time - timeout) * 1000;

    numTests = 0;
    numSuccess = 0;
    numSkipped = 0;
    numRerun = 0;
    numTimeout = 0;
    numDivergences = 0;
    timeoutSeeds = {};
    skippedSeeds = {};
  }

  bool sameArchitecture(String mode1, String mode2) =>
      ((mode1.contains('arm32') && mode2.contains('arm32')) ||
      (mode1.contains('arm64') && mode2.contains('arm64')) ||
      (mode1.contains('x64') && mode2.contains('x64')) ||
      (mode1.contains('riscv32') && mode2.contains('riscv32')) ||
      (mode1.contains('riscv64') && mode2.contains('riscv64')));

  bool ffiCapable(String mode1, String mode2) =>
      mode1.startsWith('jit') &&
      mode2.startsWith('jit') &&
      !mode1.contains('arm') &&
      !mode2.contains('arm') &&
      !mode1.contains('riscv') &&
      !mode2.contains('riscv');

  bool nestedTypesAllowed(String mode1, String mode2) =>
      (!mode1.contains('arm') && !mode2.contains('arm'));

  bool timeIsUp() {
    if (time > 0) {
      current_time = DateTime.now().millisecondsSinceEpoch;
      if (current_time > end_time) {
        return true;
      }
      // Report every 10 minutes.
      if ((current_time - report_time) > (10 * 60 * 1000)) {
        print('\n$isolate: busy @$numTests ${current_time - start_time}ms....');
        report_time = current_time;
      }
    }
    return false;
  }

  void cleanup() {
    tmpDir.delete(recursive: true);
  }

  void showStatistics() {
    stdout.write(
      '\rTests: $numTests Success: $numSuccess (Rerun: $numRerun) '
      'Skipped: $numSkipped Timeout: $numTimeout '
      'Divergences: $numDivergences',
    );
  }

  void generateTest() {
    final file = File(fileName).openSync(mode: FileMode.write);
    DartFuzz(seed, fp, ffi, flatTp, file).run();
    file.closeSync();
  }

  void runTest() {
    var result1 = runner1.run();
    var result2 = runner2.run();
    var report = checkDivergence(result1, result2);
    if (report == ReportStatus.rerun && rerun) {
      print('\nCommencing re-run .... \n');
      numDivergences--;
      result1 = runner1.run();
      result2 = runner2.run();
      report = checkDivergence(result1, result2);
      if (report == ReportStatus.no_divergence) {
        print('\nNo error on re-run\n');
        numRerun++;
      }
    }
    if (report == ReportStatus.reported ||
        (!rerun && report == ReportStatus.rerun)) {
      showReproduce();
    }
  }

  ReportStatus checkDivergence(TestResult result1, TestResult result2) {
    if (result1.exitCode == result2.exitCode) {
      // No divergence in result code.
      switch (result1.exitCode) {
        case 0:
          // Both were successful, inspect output.
          if (result1.output == result2.output) {
            numSuccess++;
          } else {
            reportDivergence(result1, result2);
            return ReportStatus.reported;
          }
          break;
        case negSigkill:
          // Both had a time out.
          numTimeout++;
          timeoutSeeds.add(seed);
          break;
        default:
          // Both had an error.
          numSkipped++;
          skippedSeeds.add(seed);
          break;
      }
    } else {
      // Divergence in result code.
      if (trueDivergence) {
        // When only true divergences are requested, any divergence
        // with at least one time out or out of memory error is
        // treated as a regular time out or skipped test, respectively.
        if (result1.exitCode == negSigkill || result2.exitCode == negSigkill) {
          numTimeout++;
          timeoutSeeds.add(seed);
          return ReportStatus.ignored;
        } else if (result1.exitCode == DartFuzz.oomExitCode ||
            result2.exitCode == DartFuzz.oomExitCode) {
          numSkipped++;
          skippedSeeds.add(seed);
          return ReportStatus.ignored;
        }
      }
      reportDivergence(result1, result2);
      // Exit codes outside [-255,255] are not due to Dart VM exits.
      if (result1.exitCode.abs() > 255 || result2.exitCode.abs() > 255) {
        return ReportStatus.rerun;
      } else {
        return ReportStatus.reported;
      }
    }
    return ReportStatus.no_divergence;
  }

  String generateReport(TestResult result1, TestResult result2) {
    if (result1.exitCode == result2.exitCode) {
      return 'output';
    } else {
      return '${result1.exitCode} vs ${result2.exitCode}';
    }
  }

  void reportStringDifference(String a, String b) {
    final matcher = equals(a);
    final matches = matcher.matches(b, {});
    if (matches) {
      print('Strings are not different.');
      return;
    }
    final mismatch = matcher.describeMismatch(b, StringDescription(), {}, true);
    print(mismatch.toString());
  }

  void reportDivergence(TestResult result1, TestResult result2) {
    numDivergences++;
    var report = generateReport(result1, result2);
    print('\n$isolate: !DIVERGENCE! $version:$seed ($report)');
    if (result1.exitCode == result2.exitCode) {
      if (numOutputLines > 0) {
        print('\nout1 and out2 are different:\n');
        reportStringDifference(result1.output, result2.output);
      }
    } else {
      // For any other divergence, always report what went wrong.
      if (result1.exitCode != 0) {
        print(
          '\nfail1:\n${result1.exitCode}\n${result1.output}\n${result1.stderr}\n',
        );
      }
      if (result2.exitCode != 0) {
        print(
          '\nfail2:\n${result2.exitCode}\n${result2.output}\n${result2.stderr}\n',
        );
      }
    }
  }

  void showReproduce() {
    print('\n-- BEGIN REPRODUCE  --\n');
    print('DART SDK REVISION: $dartSdkRevision\n');
    print(
      "dart runtime/tools/dartfuzz/dartfuzz.dart --${fp ? "" : "no-"}fp --${ffi ? "" : "no-"}ffi "
      "--${flatTp ? "" : "no-"}flat "
      '--seed $seed fuzz.dart',
    );
    print('\n-- RUN 1 --\n');
    runner1.printReproductionCommand();
    print('\n-- RUN 2 --\n');
    runner2.printReproductionCommand();
    print('\n-- END REPRODUCE  --\n');
  }

  // Context.
  final Map<String, String> env;
  final int repeat;
  final int time;
  final int numOutputLines;
  final bool trueDivergence;
  final bool showStats;
  final String top;
  final String mode1;
  final String mode2;
  final bool rerun;
  final String dartSdkRevision;

  // Test.
  late Random rand;
  late Directory tmpDir;
  late String fileName;
  late TestRunner runner1;
  late TestRunner runner2;
  late bool fp;
  late bool ffi;
  late bool flatTp;
  late String isolate;
  late int seed;

  // Timing
  late int start_time;
  late int current_time;
  late int report_time;
  late int end_time;

  // Stats.
  late int numTests;
  late int numSuccess;
  late int numSkipped;
  late int numRerun;
  late int numTimeout;
  late int numDivergences;
  late Set<int> timeoutSeeds;
  late Set<int> skippedSeeds;
}

/// Class to start fuzz testing session.
class DartFuzzTestSession {
  DartFuzzTestSession(
    this.isolates,
    this.repeat,
    this.time,
    this.numOutputLines,
    this.trueDivergence,
    this.showStats,
    String? tp,
    this.mode1,
    this.mode2,
    this.rerun,
  ) : top = getTop(tp),
      dartSdkRevision = getDartSdkRevision(tp);

  Future<void> start() async {
    print('\n**\n**** Dart Fuzz Testing Session\n**\n');
    print('Fuzz Version      : $version');
    print('Dart SDK Revision : $dartSdkRevision');
    print('Isolates          : $isolates');
    print('Tests             : $repeat');
    if (time > 0) {
      print('Time              : $time seconds');
    } else {
      print('Time              : unlimited');
    }
    print('True Divergence   : $trueDivergence');
    print('Show Stats        : $showStats');
    print('Dart Dev          : $top');
    // Fork.
    var ports = <ReceivePort>[];
    for (var i = 0; i < isolates; i++) {
      var r = ReceivePort();
      ports.add(r);
      port = r.sendPort;
      await Isolate.spawn(run, this);
    }
    // Join.
    var divergences = 0;
    for (var i = 0; i < isolates; i++) {
      var d = await ports[i].first as int;
      divergences += d;
    }
    if (divergences == 0) {
      print('\nsuccess\n');
    } else {
      print('\nfailure ($divergences divergences)\n');
      exitCode = 1;
    }
  }

  static void run(DartFuzzTestSession session) {
    var divergences = 0;
    try {
      final m1 = getMode(session.mode1, null);
      final m2 = getMode(session.mode2, m1);
      final fuzz = DartFuzzTest(
        Platform.environment,
        session.repeat,
        session.time,
        session.numOutputLines,
        session.trueDivergence,
        session.showStats,
        session.top,
        m1,
        m2,
        session.rerun,
        session.dartSdkRevision,
      );
      divergences = fuzz.run();
    } catch (e, st) {
      print('Isolate: $e\n$st');
    }
    session.port.send(divergences);
  }

  // Picks a top directory (command line, environment, or current).
  static String getTop(String? top) {
    if (top == null || top == '') {
      top = Platform.environment['DART_TOP'];
    }
    if (top == null || top == '') {
      top = Directory.current.path;
    }
    return top;
  }

  static String getDartSdkRevision(String? top) {
    var res = Process.runSync(Platform.resolvedExecutable, ['--version']);
    return res.stderr;
  }

  // Picks a mode (command line or random).
  static String getMode(String? mode, String? other) {
    // Random when not set.
    if (mode == null || mode == '') {
      // Pick a mode at random (cluster), different from other.
      var rand = Random();
      do {
        mode = clusterModes[rand.nextInt(clusterModes.length)];
      } while (mode == other);
    }
    // Verify mode.
    if (modes.contains(mode)) {
      return mode;
    }
    throw ('unknown mode: $mode');
  }

  // Context.
  final int isolates;
  final int repeat;
  final int time;
  final int numOutputLines;
  final bool trueDivergence;
  final bool showStats;
  final bool rerun;
  final String top;
  final String? mode1;
  final String? mode2;
  final String dartSdkRevision;

  // Passes each port to isolate.
  late SendPort port;

  // Modes used on cluster runs.
  static const List<String> clusterModes = [
    'jit-debug-x64',
    'jit-debug-x64c',
    'jit-debug-arm32',
    'jit-debug-arm64',
    'jit-debug-arm64c',
    'jit-debug-riscv32',
    'jit-debug-riscv64',
    'jit-x64',
    'jit-x64c',
    'jit-arm32',
    'jit-arm64',
    'jit-arm64c',
    'jit-riscv32',
    'jit-riscv64',
    'aot-debug-x64',
    'aot-debug-x64c',
    'aot-x64',
    'aot-x64c',
  ];

  // Modes not used on cluster runs because they have outstanding issues.
  static const List<String> nonClusterModes = [
    // Times out often:
    'aot-debug-arm32',
    'aot-debug-arm64',
    'aot-debug-arm64c',
    'aot-debug-riscv32',
    'aot-debug-riscv64',
    'aot-arm32',
    'aot-arm64',
    'aot-arm64c',
    'aot-riscv32',
    'aot-riscv64',
    // Too many divergences (due to arithmetic):
    'js-x64',
  ];

  // All modes.
  static List<String> modes = clusterModes + nonClusterModes;
}

/// Main driver for a fuzz testing session.
void main(List<String> arguments) {
  // Set up argument parser.
  final parser = ArgParser()
    ..addOption('isolates', help: 'number of isolates to use', defaultsTo: '1')
    ..addOption('repeat', help: 'number of tests to run', defaultsTo: '1000')
    ..addOption('time', help: 'time limit in seconds', defaultsTo: '0')
    ..addOption(
      'num-output-lines',
      help: 'number of output lines to be printed in the case of a divergence',
      defaultsTo: '200',
    )
    ..addFlag(
      'true-divergence',
      negatable: true,
      help: 'only report true divergences',
      defaultsTo: true,
    )
    ..addFlag(
      'show-stats',
      negatable: true,
      help: 'show session statistics',
      defaultsTo: true,
    )
    ..addOption('dart-top', help: 'explicit value for \$DART_TOP')
    ..addOption('mode1', help: 'execution mode 1')
    ..addOption('mode2', help: 'execution mode 2')
    ..addFlag(
      'rerun',
      negatable: true,
      help: 're-run if test only diverges on return code (not in the output)',
      defaultsTo: true,
    )
    // Undocumented options for cluster runs.
    ..addOption(
      'shards',
      help: 'number of shards used in cluster run',
      defaultsTo: '1',
    )
    ..addOption('shard', help: 'shard id in cluster run', defaultsTo: '1')
    ..addOption(
      'output_directory',
      help: 'path to output (ignored)',
      defaultsTo: null,
    )
    ..addOption(
      'output-directory',
      help: 'path to output (ignored)',
      defaultsTo: null,
    );

  // Starts fuzz testing session.
  ArgResults results;
  try {
    results = parser.parse(arguments);
  } catch (e) {
    print('Usage: dart dartfuzz_test.dart [OPTIONS]\n${parser.usage}\n$e');
    exitCode = 255;
    return;
  }
  final shards = int.parse(results['shards']);
  final shard = int.parse(results['shard']);
  if (shards > 1) {
    print('\nSHARD $shard OF $shards');
  }
  DartFuzzTestSession(
    int.parse(results['isolates']),
    int.parse(results['repeat']),
    int.parse(results['time']),
    int.parse(results['num-output-lines']),
    results['true-divergence'],
    results['show-stats'],
    results['dart-top'],
    results['mode1'],
    results['mode2'],
    results['rerun'],
  ).start();
}
