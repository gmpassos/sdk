// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show JsonEncoder;
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:analysis_server/protocol/protocol_constants.dart'
    show PROTOCOL_VERSION;
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/legacy_analysis_server.dart';
import 'package:analysis_server/src/lsp/lsp_analysis_server.dart'
    show LspAnalysisServer;
import 'package:analysis_server/src/plugin/plugin_manager.dart';
import 'package:analysis_server/src/scheduler/message_scheduler.dart';
import 'package:analysis_server/src/server/http_server.dart';
import 'package:analysis_server/src/services/completion/completion_performance.dart';
import 'package:analysis_server/src/services/correction/fix_performance.dart';
import 'package:analysis_server/src/services/correction/refactoring_performance.dart';
import 'package:analysis_server/src/socket_server.dart';
import 'package:analysis_server/src/status/ast_writer.dart';
import 'package:analysis_server/src/status/element_writer.dart';
import 'package:analysis_server/src/status/pages.dart';
import 'package:analysis_server/src/utilities/profiling.dart';
import 'package:analysis_server/src/utilities/stream_string_stink.dart';
import 'package:analysis_server_plugin/src/correction/assist_performance.dart';
import 'package:analysis_server_plugin/src/correction/performance.dart';
import 'package:analyzer/dart/analysis/context_root.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/src/context/source.dart';
import 'package:analyzer/src/dart/analysis/analysis_options_map.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/library_graph.dart';
import 'package:analyzer/src/dart/sdk/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/source/package_map_resolver.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:analyzer/src/workspace/pub.dart';
import 'package:analyzer/src/workspace/workspace.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service_io.dart' as vm_service;

final String kCustomCss = '''
.lead, .page-title+.markdown-body>p:first-child {
  margin-bottom: 30px;
  font-size: 20px;
  font-weight: 300;
  color: #555;
}

.container {
  width: 1160px;
}

.masthead {
  padding-top: 1rem;
  padding-bottom: 1rem;
  margin-bottom: 1.5rem;
  text-align: center;
  background-color: #4078c0;
}

.masthead .masthead-logo {
  display: inline-block;
  font-size: 1.5rem;
  color: #fff;
  float: left;
}

.masthead .mega-octicon {
  font-size: 1.5rem;
}

.masthead-nav {
  float: right;
  margin-top: .5rem;
}

.masthead-nav a:not(:last-child) {
  margin-right: 1.25rem;
}

.masthead a {
  color: rgba(255,255,255,0.5);
  font-size: 1rem;
}

.masthead a:hover {
  color: #fff;
  text-decoration: none;
}

.masthead-nav .active {
  color: #fff;
  font-weight: 500;
}

.counter {
  display: inline-block;
  padding: 2px 5px;
  font-size: 11px;
  font-weight: bold;
  line-height: 1;
  color: #666;
  background-color: #eee;
  border-radius: 20px;
}

.menu-item .counter {
  float: right;
  margin-left: 5px;
}

td.right {
  text-align: right;
}

table td {
  max-width: 600px;
  vertical-align: text-top;
}

td.pre {
  white-space: pre;
}

.nowrap {
  white-space: nowrap;
}

.scroll-table {
  max-height: 190px;
  overflow-x: auto;
}

.footer {
  padding-top: 3rem;
  padding-bottom: 3rem;
  margin-top: 3rem;
  line-height: 1.75;
  color: #7a7a7a;
  border-top: 1px solid #eee;
}

.footer strong {
  color: #333;
}

.subtle {
  color: #333;
}
''';

String get _sdkVersion {
  var version = Platform.version;
  if (version.contains(' ')) {
    version = version.substring(0, version.indexOf(' '));
  }
  return version;
}

String writeOption(String name, Object value) {
  return '$name: <code>$value</code><br> ';
}

_CollectedOptionsData _collectOptionsData(AnalysisDriver driver) {
  var collectedData = _CollectedOptionsData();
  if (driver.analysisContext?.allAnalysisOptions case var allAnalysisOptions?) {
    for (var analysisOptions in allAnalysisOptions) {
      collectedData.lints.addAll(analysisOptions.lintRules.map((e) => e.name));
      collectedData.plugins.addAll(analysisOptions.enabledLegacyPluginNames);
    }
  }
  return collectedData;
}

(int, String) _producerDetails(ProducerRequestPerformance request) {
  var details = StringBuffer();

  var totalProducerTime = 0;
  var producerTimings = request.producerTimings;

  for (var timing in producerTimings.sortedBy((t) => t.elapsedTime).reversed) {
    var producerTime = timing.elapsedTime;
    totalProducerTime += producerTime;
    details.write(timing.className);
    details.write(': ');
    details.writeln(printMilliseconds(producerTime));
  }

  return (totalProducerTime, details.toString());
}

class AnalysisDriverTimingsPage extends DiagnosticPageWithNav
    implements PostablePage {
  static const _resetFormId = 'reset-driver-timers';

  AnalysisDriverTimingsPage(DiagnosticsSite site)
    : super(
        site,
        'driver-timings',
        'Analysis Driver',
        description:
            'Timing statistics collected by the analysis driver scheduler since last reset.',
        indentInNav: true,
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    // Output the current values.
    var buffer = StringBuffer();
    server.analysisDriverScheduler.accumulatedPerformance.write(buffer: buffer);
    pre(() {
      buf.write('<code>');
      buf.write(escape('$buffer'));
      buf.writeln('</code>');
    });

    // Add a button to reset the timers.
    buf.write('''
<form action="${this.path}?$_resetFormId=true" method="post">
<input type="submit" class="btn btn-danger" value="Reset Timers" />
</form>
''');
  }

  @override
  Future<String> handlePost(Map<String, String> params) async {
    if (params[_resetFormId]?.isNotEmpty ?? false) {
      server
          .analysisDriverScheduler
          .accumulatedPerformance = OperationPerformanceImpl('<scheduler>');
    }

    return this.path;
  }
}

class AnalysisPerformanceLogPage extends WebSocketLoggingPage {
  AnalysisPerformanceLogPage(DiagnosticsSite site)
    : super(
        site,
        'analysis-performance-log',
        'Analysis Performance Log',
        description: 'Realtime logging from the Analysis Performance Log',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    _writeWebSocketLogPanel();
  }

  @override
  Future<void> handleWebSocket(WebSocket socket) async {
    var logger = server.analysisPerformanceLogger;

    // We were able to attach our temporary sink. Forward all data over the
    // WebSocket and wait for it to close (this is done by the user clicking
    // the Stop button or navigating away from the page).
    var controller = StreamController<String>();
    var sink = StreamStringSink(controller.sink);
    try {
      unawaited(socket.addStream(controller.stream));
      logger.sink.addSink(sink);

      // Wait for the socket to be closed so we can remove the secondary sink.
      var completer = Completer<void>();
      socket.listen(
        null,
        onDone: completer.complete,
        onError: completer.complete,
      );
      await completer.future;
    } finally {
      logger.sink.removeSink(sink);
    }
  }
}

class AnalyticsPage extends DiagnosticPageWithNav {
  AnalyticsPage(DiagnosticsSite site)
    : super(
        site,
        'analytics',
        'Analytics',
        description: 'Analytics gathered by the analysis server.',
      );

  @override
  String? get navDetail => null;

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var manager = server.analyticsManager;
    //
    // Display the standard header.
    //
    if (!manager.analytics.telemetryEnabled) {
      p('Analytics reporting disabled. In order to enable it, run:');
      p('&nbsp;&nbsp;<code>dart --enable-analytics</code>');
      p(
        'If analytics had been enabled, the information below would have been '
        'reported.',
      );
    } else {
      p(
        'The Dart tool uses Google Analytics to report feature usage '
        'statistics and to send basic crash reports. This data is used to '
        'help improve the Dart platform and tools over time.',
      );
      p('To disable reporting of analytics, run:');
      p('&nbsp;&nbsp;<code>dart --disable-analytics</code>', raw: true);
      p(
        'The information below will be reported the next time analytics are '
        'sent.',
      );
    }
    //
    // Display the analytics data that has been gathered.
    //
    manager.toHtml(buf);
  }
}

class AssistsPage extends DiagnosticPageWithNav with PerformanceChartMixin {
  AssistsPage(DiagnosticsSite site)
    : super(
        site,
        'getAssists',
        'Assists',
        description: 'Latency and timing statistics for getting assists.',
        indentInNav: true,
      );

  path.Context get pathContext => server.resourceProvider.pathContext;

  List<GetAssistsPerformance> get performanceItems =>
      server.recentPerformance.getAssists.items.toList();

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var requests = performanceItems;

    if (requests.isEmpty) {
      blankslate('No assist requests recorded.');
      return;
    }

    var fastCount =
        requests.where((c) => c.elapsedInMilliseconds <= 100).length;
    p(
      '${requests.length} results; ${printPercentage(fastCount / requests.length)} within 100ms.',
    );

    drawChart(requests);

    // Emit the data as a table
    buf.writeln('<table>');
    buf.writeln(
      '<tr><th>Time</th><th align = "left" title="Time in correction producer `compute()` calls">Producer.compute()</th><th align = "left">Source</th><th>Snippet</th></tr>',
    );

    for (var request in requests) {
      var shortName = pathContext.basename(request.path);
      var (producerTime, producerDetails) = _producerDetails(request);
      buf.writeln(
        '<tr>'
        '<td class="pre right"><a href="/timing?id=${request.id}&kind=getAssists">'
        '${_formatLatencyTiming(request.elapsedInMilliseconds, request.requestLatency)}'
        '</a></td>'
        '<td><abbr title="$producerDetails">${printMilliseconds(producerTime)}</abbr></td>'
        '<td>${escape(shortName)}</td>'
        '<td><code>${escape(request.snippet)}</code></td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }
}

class AstPage extends DiagnosticPageWithNav {
  String? _description;

  AstPage(DiagnosticsSite site)
    : super(site, 'ast', 'AST', description: 'The AST for a file.');

  @override
  String? get description => _description ?? super.description;

  @override
  bool get showInNav => false;

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var filePath = params['file'];
    if (filePath == null) {
      p('No file path provided.');
      return;
    }
    var driver = server.getAnalysisDriver(filePath);
    if (driver == null) {
      p(
        'The file <code>${escape(filePath)}</code> is not being analyzed.',
        raw: true,
      );
      return;
    }
    var result = await driver.getResolvedUnit(filePath);
    if (result is ResolvedUnitResult) {
      var writer = AstWriter(buf);
      result.unit.accept(writer);
    } else {
      p(
        'An AST could not be produced for the file '
        '<code>${escape(filePath)}</code>.',
        raw: true,
      );
    }
  }

  @override
  Future<void> generatePage(Map<String, String> params) async {
    try {
      _description = params['file'];
      await super.generatePage(params);
    } finally {
      _description = null;
    }
  }
}

class ByteStoreTimingPage extends DiagnosticPageWithNav
    with PerformanceChartMixin {
  ByteStoreTimingPage(DiagnosticsSite site)
    : super(
        site,
        'byte-store-timing',
        'FileByteStore',
        description: 'FileByteStore Timing statistics.',
        indentInNav: true,
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    h3('FileByteStore Timings');

    var byteStoreTimings =
        server.byteStoreTimings
            ?.where(
              (timing) =>
                  timing.readCount != 0 || timing.readTime != Duration.zero,
            )
            .toList();
    if (byteStoreTimings == null || byteStoreTimings.isEmpty) {
      p(
        'There are currently no timings. '
        'Try refreshing after the server has performed initial analysis.',
      );
      return;
    }

    buf.writeln('<table>');
    buf.writeln(
      '<tr><th>Files Read</th><th>Time Taken</th><th>&nbsp;</th></tr>',
    );
    for (var i = 0; i < byteStoreTimings.length; i++) {
      var timing = byteStoreTimings[i];
      if (timing.readCount == 0) {
        continue;
      }

      var nextTiming =
          i + 1 < byteStoreTimings.length ? byteStoreTimings[i + 1] : null;
      var duration = (nextTiming?.time ?? DateTime.now()).difference(
        timing.time,
      );
      var description =
          'Between <em>${timing.reason}</em> and <em>${nextTiming?.reason ?? 'now'} (${printMilliseconds(duration.inMilliseconds)})</em>.';
      buf.writeln(
        '<tr>'
        '<td class="right">${timing.readCount} files</td>'
        '<td class="right">${printMilliseconds(timing.readTime.inMilliseconds)}</td>'
        '<td>$description</td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }
}

class ClientPage extends DiagnosticPageWithNav {
  ClientPage(super.site, [super.id = 'client', super.title = 'Client'])
    : super(description: 'Information about the client.');

  @override
  Future<void> generateContent(Map<String, String> params) async {
    h3('Client Diagnostic Information');
    prettyJson(server.clientDiagnosticInformation);
  }
}

class CollectReportPage extends DiagnosticPage {
  CollectReportPage(DiagnosticsSite site)
    : super(
        site,
        'collectreport',
        'Collect Report',
        description: 'Collect a shareable report for filing issues.',
      );

  @override
  String? contentDispositionString(Map<String, String> params) {
    if (params['collect'] != null) {
      return 'attachment; filename="dart_analyzer_diagnostics_report.json"';
    }
    return super.contentDispositionString(params);
  }

  @override
  ContentType contentType(Map<String, String> params) {
    if (params['collect'] != null) {
      return ContentType.json;
    }
    return super.contentType(params);
  }

  @override
  Future<void> generateContent(Map<String, String> params) async {
    p(
      'To download a report click the link below. '
      'When the report is downloaded you can share it with the '
      'Dart developers.',
    );
    p('<a href="${this.path}?collect=true">Download report</a>.', raw: true);
  }

  @override
  Future<void> generatePage(Map<String, String> params) async {
    if (params['collect'] != null) {
      // No added header etc.
      String data = await _collectAllData();
      buf.write(data);
      return;
    }
    return await super.generatePage(params);
  }

  /// Returns a json encoding of a map containing the data to be collected.
  Future<String> _collectAllData() async {
    Map<String, Object?> collectedData = {};
    var server = this.server;

    _collectGeneralData(collectedData, server);
    _collectMessageSchedulerData(collectedData);
    await _collectProcessData(collectedData);
    _collectCommunicationData(collectedData, server);
    _collectContextData(collectedData, server);
    _collectAnalysisDriverData(collectedData, server);
    _collectFileByteStoreTimingData(collectedData, server);
    _collectPerformanceData(collectedData, server);
    _collectExceptionsData(collectedData, server);
    await _collectObservatoryData(collectedData);

    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(collectedData);
  }

  void _collectAnalysisDriverData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    var buffer = StringBuffer();
    server.analysisDriverScheduler.accumulatedPerformance.write(buffer: buffer);
    collectedData['accumulatedPerformance'] = buffer.toString();
  }

  void _collectCommunicationData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    for (var data
        in {
          'startup': server.performanceDuringStartup,
          if (server.performanceAfterStartup != null)
            'afterStartup': server.performanceAfterStartup!,
        }.entries) {
      var perf = data.value;
      var perfData = {};
      collectedData[data.key] = perfData;

      var requestCount = perf.requestCount;
      var latencyCount = perf.latencyCount;
      var averageLatency =
          latencyCount > 0 ? (perf.requestLatency ~/ latencyCount) : null;
      var maximumLatency = perf.maxLatency;
      var slowRequestCount = perf.slowRequestCount;

      perfData['RequestCount'] = requestCount;
      perfData['LatencyCount'] = latencyCount;
      perfData['AverageLatency'] = averageLatency;
      perfData['MaximumLatency'] = maximumLatency;
      perfData['SlowRequestCount'] = slowRequestCount;
    }
  }

  void _collectContextData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    var driverMapValues = server.driverMap.values.toList();
    var contexts = [];
    collectedData['contexts'] = contexts;

    Set<String> uniqueKnownFiles = {};
    for (var driver in driverMapValues) {
      var contextData = {};
      contexts.add(contextData);
      // We don't include the name because the name might include confidential
      // information.
      var knownFiles = driver.knownFiles.map((f) => f.path).toSet();
      contextData['priorityFiles'] = driver.priorityFiles.length;
      contextData['addedFiles'] = driver.addedFiles.length;
      contextData['knownFiles'] = knownFiles.length;
      uniqueKnownFiles.addAll(knownFiles);

      var collectedOptionsData = _collectOptionsData(driver);
      contextData['lints'] = collectedOptionsData.lints.sorted();
      contextData['plugins'] = collectedOptionsData.plugins.toList();

      Set<LibraryCycle> cycles = {};
      var contextRoot = driver.analysisContext!.contextRoot;
      for (var filePath in contextRoot.analyzedFiles()) {
        var fileState = driver.fsState.getFileForPath(filePath);
        var kind = fileState.kind;
        if (kind is LibraryFileKind) {
          cycles.add(kind.libraryCycle);
        }
      }
      var cycleData = <int, int>{};
      for (var cycle in cycles) {
        cycleData[cycle.size] = (cycleData[cycle.size] ?? 0) + 1;
      }
      var sortedCycleData = <int, int>{};
      for (var size in cycleData.keys.toList()..sort()) {
        sortedCycleData[size] = cycleData[size]!;
      }
      contextData['libraryCycleData'] = sortedCycleData;
    }
    collectedData['uniqueKnownFiles'] = uniqueKnownFiles.length;
  }

  void _collectExceptionsData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    var exceptions = [];
    collectedData['exceptions'] = exceptions;
    for (var exception in server.exceptions.items) {
      exceptions.add({
        'exception': exception.exception?.toString(),
        'fatal': exception.fatal,
        'message': exception.message,
        'stackTrace': exception.stackTrace.toString(),
      });
    }
  }

  void _collectFileByteStoreTimingData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    var byteStoreTimings =
        server.byteStoreTimings
            ?.where(
              (timing) =>
                  timing.readCount != 0 || timing.readTime != Duration.zero,
            )
            .toList();
    if (byteStoreTimings != null && byteStoreTimings.isNotEmpty) {
      var performance = [];
      collectedData['byteStoreTimings'] = performance;
      for (var i = 0; i < byteStoreTimings.length; i++) {
        var timing = byteStoreTimings[i];
        if (timing.readCount == 0) {
          continue;
        }

        var nextTiming =
            i + 1 < byteStoreTimings.length ? byteStoreTimings[i + 1] : null;
        var duration = (nextTiming?.time ?? DateTime.now()).difference(
          timing.time,
        );
        var description =
            'Between ${timing.reason} and ${nextTiming?.reason ?? 'now'} '
            '(${printMilliseconds(duration.inMilliseconds)}).';

        var itemData = {};
        performance.add(itemData);
        itemData['file_reads'] = timing.readCount;
        itemData['time'] = timing.readTime.inMilliseconds;
        itemData['description'] = description;
      }
    }
  }

  void _collectGeneralData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    collectedData['currentTime'] = DateTime.now().millisecondsSinceEpoch;
    collectedData['operatingSystem'] = Platform.operatingSystem;
    collectedData['version'] = Platform.version;
    collectedData['clientId'] = server.options.clientId;
    collectedData['clientVersion'] = server.options.clientVersion;
    collectedData['protocolVersion'] = PROTOCOL_VERSION;
    collectedData['serverType'] = server.runtimeType.toString();
    collectedData['uptime'] = server.uptime.toString();
    if (server is LegacyAnalysisServer) {
      collectedData['serverServices'] =
          server.serverServices.map((e) => e.toString()).toList();
    } else if (server is LspAnalysisServer) {
      collectedData['clientDiagnosticInformation'] =
          server.clientDiagnosticInformation;
    }
  }

  void _collectMessageSchedulerData(Map<String, Object?> collectedData) {
    collectedData['allowOverlappingHandlers'] =
        MessageScheduler.allowOverlappingHandlers;
  }

  Future<void> _collectObservatoryData(
    Map<String, Object?> collectedData,
  ) async {
    var serviceProtocolInfo = await developer.Service.getInfo();
    var startedServiceProtocol = false;
    if (serviceProtocolInfo.serverUri == null) {
      startedServiceProtocol = true;
      serviceProtocolInfo = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
    }

    var serverUri = serviceProtocolInfo.serverUri;
    if (serverUri != null) {
      var path = serverUri.path;
      if (!path.endsWith('/')) path += '/';
      var wsUriString = 'ws://${serverUri.authority}${path}ws';
      var serviceClient = await vm_service.vmServiceConnectUri(wsUriString);
      var vm = await serviceClient.getVM();
      collectedData['vm.architectureBits'] = vm.architectureBits;
      collectedData['vm.hostCPU'] = vm.hostCPU;
      collectedData['vm.operatingSystem'] = vm.operatingSystem;
      collectedData['vm.startTime'] = vm.startTime;

      var processMemoryUsage = await serviceClient.getProcessMemoryUsage();
      collectedData['processMemoryUsage'] = processMemoryUsage.json;

      var isolateData = [];
      collectedData['isolates'] = isolateData;
      var isolates = [...?vm.isolates, ...?vm.systemIsolates];
      for (var isolate in isolates) {
        String? id = isolate.id;
        if (id == null) continue;
        var thisIsolateData = {};
        isolateData.add(thisIsolateData);
        thisIsolateData['id'] = id;
        thisIsolateData['isolateGroupId'] = isolate.isolateGroupId;
        thisIsolateData['name'] = isolate.name;
        var isolateMemoryUsage = await serviceClient.getMemoryUsage(id);
        thisIsolateData['memory'] = isolateMemoryUsage.json;
        var allocationProfile = await serviceClient.getAllocationProfile(id);
        var allocationMembers = allocationProfile.members ?? [];
        var allocationProfileData = <Map<String, Object?>>[];
        thisIsolateData['allocationProfile'] = allocationProfileData;
        for (var member in allocationMembers) {
          var bytesCurrent = member.bytesCurrent;
          // Filter out very small entries to avoid the report becoming too big.
          if (bytesCurrent == null || bytesCurrent < 1024) continue;

          var memberData = <String, Object?>{};
          allocationProfileData.add(memberData);
          memberData['bytesCurrent'] = bytesCurrent;
          memberData['instancesCurrent'] = member.instancesCurrent;
          memberData['accumulatedSize'] = member.accumulatedSize;
          memberData['instancesAccumulated'] = member.instancesAccumulated;
          memberData['className'] = member.classRef?.name;
          memberData['libraryName'] = member.classRef?.library?.name;
        }
        allocationProfileData.sort((a, b) {
          int bytesCurrentA = a['bytesCurrent'] as int;
          int bytesCurrentB = b['bytesCurrent'] as int;
          // Largest first.
          return bytesCurrentB.compareTo(bytesCurrentA);
        });
      }
    }

    if (startedServiceProtocol) {
      await developer.Service.controlWebServer(silenceOutput: true);
    }
  }

  void _collectPerformanceData(
    Map<String, Object?> collectedData,
    AnalysisServer server,
  ) {
    collectedData['performanceCompletion'] = _convertPerformance(
      server.recentPerformance.completion.items.toList(),
    );
    collectedData['performanceGetFixes'] = _convertPerformance(
      server.recentPerformance.getFixes.items.toList(),
    );
    collectedData['performanceRequests'] = _convertPerformance(
      server.recentPerformance.requests.items.toList(),
    );
    collectedData['performanceSlowRequests'] = _convertPerformance(
      server.recentPerformance.slowRequests.items.toList(),
    );
  }

  Future<void> _collectProcessData(Map<String, Object?> collectedData) async {
    var profiler = ProcessProfiler.getProfilerForPlatform();
    UsageInfo? usage;
    if (profiler != null) {
      usage = await profiler.getProcessUsage(pid);
    }
    collectedData['memoryKB'] = usage?.memoryKB;
    collectedData['cpuPercentage'] = usage?.cpuPercentage;
    collectedData['currentRss'] = ProcessInfo.currentRss;
    collectedData['maxRss'] = ProcessInfo.maxRss;
  }

  // Recorded performance data (timing and code completion).
  List<Object> _convertPerformance(List<RequestPerformance> items) {
    var performance = <Object>[];

    for (var item in items) {
      var itemData = {};
      performance.add(itemData);

      itemData['id'] = item.id;
      itemData['operation'] = item.operation;
      itemData['requestLatency'] = item.requestLatency;
      itemData['elapsed'] = item.performance.elapsed.inMilliseconds;
      itemData['startTime'] = item.startTime?.toIso8601String();

      var buffer = StringBuffer();
      item.performance.write(buffer: buffer);
      itemData['performance'] = buffer.toString();
    }
    return performance;
  }
}

class CommunicationsPage extends DiagnosticPageWithNav {
  CommunicationsPage(DiagnosticsSite site)
    : super(
        site,
        'communications',
        'Communications',
        description: 'Latency statistics for analysis server communications.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    void writeRow(List<String> data, {List<String?>? classes}) {
      buf.write('<tr>');
      for (var i = 0; i < data.length; i++) {
        var c = classes == null ? null : classes[i];
        if (c != null) {
          buf.write('<td class="$c">${escape(data[i])}</td>');
        } else {
          buf.write('<td>${escape(data[i])}</td>');
        }
      }
      buf.writeln('</tr>');
    }

    buf.writeln('<div class="columns">');

    var performanceAfterStartup = server.performanceAfterStartup;
    if (performanceAfterStartup != null) {
      buf.writeln('<div class="column one-half">');

      h3('Current');
      _writePerformanceTable(performanceAfterStartup, writeRow);

      var time = server.uptime.toString();
      if (time.contains('.')) {
        time = time.substring(0, time.indexOf('.'));
      }
      buf.writeln(writeOption('Uptime', time));

      buf.write('</div>');
    }

    buf.writeln('<div class="column one-half">');

    h3('Startup');
    _writePerformanceTable(server.performanceDuringStartup, writeRow);

    if (performanceAfterStartup != null) {
      var startupTime =
          performanceAfterStartup.startTime -
          server.performanceDuringStartup.startTime;
      buf.writeln(
        writeOption('Initial analysis time', printMilliseconds(startupTime)),
      );
    }

    buf.write('</div>');

    buf.write('</div>');
  }

  void _writePerformanceTable(
    ServerPerformance perf,
    void Function(List<String> data, {List<String?> classes}) writeRow,
  ) {
    var requestCount = perf.requestCount;
    var latencyCount = perf.latencyCount;
    var averageLatency =
        latencyCount > 0 ? (perf.requestLatency ~/ latencyCount) : 0;
    var maximumLatency = perf.maxLatency;
    var slowRequestPercent =
        latencyCount > 0 ? (perf.slowRequestCount / latencyCount) : 0.0;

    buf.write('<table>');
    writeRow(['$requestCount', 'requests'], classes: ['right', null]);
    writeRow(
      ['$latencyCount', 'requests with latency information'],
      classes: ['right', null],
    );
    if (latencyCount > 0) {
      writeRow(
        [printMilliseconds(averageLatency), 'average latency'],
        classes: ['right', null],
      );
      writeRow(
        [printMilliseconds(maximumLatency), 'maximum latency'],
        classes: ['right', null],
      );
      writeRow(
        [printPercentage(slowRequestPercent), '> 150 ms latency'],
        classes: ['right', null],
      );
    }
    buf.write('</table>');
  }
}

class CompletionPage extends DiagnosticPageWithNav with PerformanceChartMixin {
  CompletionPage(DiagnosticsSite site)
    : super(
        site,
        'completion',
        'Code Completion',
        description: 'Latency statistics for code completion.',
        indentInNav: true,
      );

  path.Context get pathContext => server.resourceProvider.pathContext;

  List<CompletionPerformance> get performanceItems =>
      server.recentPerformance.completion.items.toList();

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var completions = performanceItems;

    if (completions.isEmpty) {
      blankslate('No completions recorded.');
      return;
    }

    var fastCount =
        completions.where((c) => c.elapsedInMilliseconds <= 100).length;
    p(
      '${completions.length} results; ${printPercentage(fastCount / completions.length)} within 100ms.',
    );

    drawChart(completions);

    // emit the data as a table
    buf.writeln('<table>');
    buf.writeln(
      '<tr><th>Time</th><th>Computed Results</th><th>Transmitted Results</th><th>Source</th><th>Snippet</th></tr>',
    );
    for (var completion in completions) {
      var shortName = pathContext.basename(completion.path);
      buf.writeln(
        '<tr>'
        '<td class="pre right"><a href="/timing?id=${completion.id}&kind=completion">'
        '${_formatLatencyTiming(completion.elapsedInMilliseconds, completion.requestLatency)}'
        '</a></td>'
        '<td class="right">${completion.computedSuggestionCountStr}</td>'
        '<td class="right">${completion.transmittedSuggestionCountStr}</td>'
        '<td>${escape(shortName)}</td>'
        '<td><code>${escape(completion.snippet)}</code></td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }
}

class ContentsPage extends DiagnosticPageWithNav {
  String? _description;

  ContentsPage(DiagnosticsSite site)
    : super(
        site,
        'contents',
        'Contents',
        description: 'The Contents/Overlay of a file.',
      );

  @override
  String? get description => _description ?? super.description;

  @override
  bool get showInNav => false;

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var filePath = params['file'];
    if (filePath == null) {
      p('No file path provided.');
      return;
    }
    var driver = server.getAnalysisDriver(filePath);
    if (driver == null) {
      p(
        'The file <code>${escape(filePath)}</code> is not being analyzed.',
        raw: true,
      );
      return;
    }
    var file = server.resourceProvider.getFile(filePath);
    if (!file.exists) {
      p('The file <code>${escape(filePath)}</code> does not exist.', raw: true);
      return;
    }

    if (server.resourceProvider.hasOverlay(filePath)) {
      p('Showing overlay for file.');
    } else {
      p('Showing file system contents for file.');
    }

    pre(() {
      buf.write('<code>');
      buf.write(escape(file.readAsStringSync()));
      buf.writeln('</code>');
    });
  }

  @override
  Future<void> generatePage(Map<String, String> params) async {
    try {
      _description = params['file'];
      await super.generatePage(params);
    } finally {
      _description = null;
    }
  }
}

class ContextsPage extends DiagnosticPageWithNav {
  ContextsPage(DiagnosticsSite site)
    : super(
        site,
        'contexts',
        'Contexts',
        description:
            'An analysis context defines a set of sources for which URIs are '
            'all resolved in the same way.',
      );

  @override
  String get navDetail => '${server.driverMap.length}';

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var driverMap = server.driverMap;
    if (driverMap.isEmpty) {
      blankslate('No contexts.');
      return;
    }

    var contextPath = params['context'];
    var entries = driverMap.entries.toList();
    entries.sort(
      (first, second) => first.key.shortName.compareTo(second.key.shortName),
    );
    var entry = entries.firstWhereOrNull((f) => f.key.path == contextPath);

    if (entry == null) {
      entry = entries.first;
      contextPath = entry.key.path;
    }

    var folder = entry.key;
    var driver = entry.value;

    buf.writeln('<div class="tabnav">');
    buf.writeln('<nav class="tabnav-tabs">');
    for (var entry in entries) {
      var f = entry.key;
      if (f == folder) {
        buf.writeln(
          '<a class="tabnav-tab selected">${escape(f.shortName)}</a>',
        );
      } else {
        var p = '${this.path}?context=${Uri.encodeQueryComponent(f.path)}';
        buf.writeln(
          '<a href="$p" class="tabnav-tab">${escape(f.shortName)}</a>',
        );
      }
    }
    buf.writeln('</nav>');
    buf.writeln('</div>');

    buf.writeln(writeOption('Context location', escape(contextPath)));
    buf.writeln(
      writeOption('SDK root', escape(driver.analysisContext?.sdkRoot?.path)),
    );

    h3('Analysis options');

    // Display analysis options entries inside this context root.
    var optionsInContextRoot = driver.analysisOptionsMap.entries.where(
      (OptionsMapEntry entry) => contextPath!.startsWith(entry.folder.path),
    );
    ul(optionsInContextRoot, (OptionsMapEntry entry) {
      var folder = entry.folder;
      buf.write(escape(folder.path));
      var optionsPath = path.join(folder.path, 'analysis_options.yaml');
      var contentsPath =
          '/contents?file=${Uri.encodeQueryComponent(optionsPath)}';
      buf.writeln(' <a href="$contentsPath">analysis_options.yaml</a>');
    }, classes: 'scroll-table');

    String lenCounter(int length) {
      return '<span class="counter" style="float: right;">$length</span>';
    }

    h3('Workspace');
    var workspace = driver.analysisContext?.contextRoot.workspace;
    buf.writeln('<p>');
    buf.writeln(writeOption('Workspace root', escape(workspace?.root)));
    var workspaceFolder = folder.provider.getFolder(workspace!.root);

    void writePackage(WorkspacePackageImpl package) {
      buf.writeln(writeOption('Package root', escape(package.root.path)));
      if (package is PubPackage) {
        buf.writeln(
          writeOption(
            'pubspec file',
            escape(
              workspaceFolder.getChildAssumingFile(file_paths.pubspecYaml).path,
            ),
          ),
        );
      }
    }

    var packageConfig = workspaceFolder
        .getChildAssumingFolder(file_paths.dotDartTool)
        .getChildAssumingFile(file_paths.packageConfigJson);
    buf.writeln(
      writeOption('Has package_config.json file', packageConfig.exists),
    );
    if (workspace is PackageConfigWorkspace) {
      var packages = workspace.allPackages;
      h4('Packages ${lenCounter(packages.length)}', raw: true);
      ul(packages, writePackage, classes: 'scroll-table');
    }
    buf.writeln('</p>');

    buf.writeln('</div>');

    h3('Plugins');
    var optionsData = _collectOptionsData(driver);
    p(optionsData.plugins.toList().join(', '));

    var priorityFiles = driver.priorityFiles;
    var addedFiles = driver.addedFiles.toList();
    var knownFiles = driver.knownFiles.map((f) => f.path).toSet();
    var implicitFiles = knownFiles.difference(driver.addedFiles).toList();
    addedFiles.sort();
    implicitFiles.sort();

    h3('Context files');

    void writeFile(String file) {
      var astPath = '/ast?file=${Uri.encodeQueryComponent(file)}';
      var elementPath = '/element?file=${Uri.encodeQueryComponent(file)}';
      var contentsPath = '/contents?file=${Uri.encodeQueryComponent(file)}';
      var hasOverlay = server.resourceProvider.hasOverlay(file);

      buf.write(file.wordBreakOnSlashes);
      buf.writeln(' <a href="$astPath">ast</a>');
      buf.writeln(' <a href="$elementPath">element</a>');
      buf.writeln(
        ' <a href="$contentsPath">contents${hasOverlay ? '*' : ''}</a>',
      );
    }

    h4('Priority files ${lenCounter(priorityFiles.length)}', raw: true);
    ul(priorityFiles, writeFile, classes: 'scroll-table');

    h4('Added files ${lenCounter(addedFiles.length)}', raw: true);
    ul(addedFiles, writeFile, classes: 'scroll-table');

    h4('Implicit files ${lenCounter(implicitFiles.length)}', raw: true);
    ul(implicitFiles, writeFile, classes: 'scroll-table');

    var sourceFactory = driver.sourceFactory;
    if (sourceFactory is SourceFactoryImpl) {
      h3('Resolvers');
      for (var resolver in sourceFactory.resolvers) {
        h4(resolver.runtimeType.toString());
        buf.write('<p class="scroll-table">');
        if (resolver is DartUriResolver) {
          var sdk = resolver.dartSdk;
          buf.write(' (sdk = ');
          buf.write(sdk.runtimeType);
          if (sdk is FolderBasedDartSdk) {
            buf.write(' (path = ');
            buf.write(sdk.directory.path);
            buf.write(')');
          } else if (sdk is EmbedderSdk) {
            buf.write(' (map = ');
            writeMap(sdk.urlMappings);
            buf.write(')');
          }
          buf.write(')');
        } else if (resolver is PackageMapUriResolver) {
          writeMap(resolver.packageMap);
        } else if (resolver is PackageConfigPackageUriResolver) {
          writeMap(resolver.packageMap);
        }
        buf.write('</p>');
      }
    }

    h3('Dartdoc template info');
    var info = driver.dartdocDirectiveInfo;
    buf.write('<p class="scroll-table">');
    writeMap(info.templateMap);
    buf.write('</p>');

    h3('Largest library cycles');
    Set<LibraryCycle> cycles = {};
    var contextRoot = driver.analysisContext!.contextRoot;
    for (var filePath in contextRoot.analyzedFiles()) {
      var fileState = driver.fsState.getFileForPath(filePath);
      var kind = fileState.kind;
      if (kind is LibraryFileKind) {
        cycles.add(kind.libraryCycle);
      }
    }
    var sortedCycles =
        cycles.toList()..sort((first, second) => second.size - first.size);
    var cyclesToDisplay = math.min(sortedCycles.length, 10);
    var initialPathLength = contextRoot.root.path.length + 1;
    buf.write('<p>There are ${sortedCycles.length} library cycles. ');
    buf.write('The $cyclesToDisplay largest contain</p>');
    buf.write('<ul>');
    for (var i = 0; i < cyclesToDisplay; i++) {
      var cycle = sortedCycles[i];
      var libraries = cycle.libraries;
      var cycleSize = cycle.size;
      var libraryCount = math.min(cycleSize, 8);
      buf.write('<li>$cycleSize libraries, including');
      buf.write('<ul>');
      for (var j = 0; j < libraryCount; j++) {
        var library = libraries[j];
        buf.write('<li>');
        buf.write(library.file.path.substring(initialPathLength));
        buf.write('</li>');
      }
      buf.write('</ul>');
      buf.write('</li>');
    }
    buf.write('</ul>');
  }

  void writeList<E>(List<E> list) {
    buf.writeln('[${list.join(', ')}]');
  }

  void writeMap<V>(Map<String, V> map) {
    var keys = map.keys.toList();
    keys.sort();
    var length = keys.length;
    buf.write('{');
    for (var i = 0; i < length; i++) {
      buf.write('<br>');
      var key = keys[i];
      var value = map[key];
      buf.write(key);
      buf.write(' = ');
      if (value is List) {
        writeList(value);
      } else {
        buf.write(value);
      }
      buf.write(',');
    }
    buf.write('<br>}');
  }
}

/// A page with a proscriptive notion of layout.
abstract class DiagnosticPage extends Page {
  final DiagnosticsSite site;

  DiagnosticPage(this.site, String id, String title, {String? description})
    : super(id, title, description: description);

  bool get isNavPage => false;

  AnalysisServer get server => site.socketServer.analysisServer!;

  Future<void> generateContainer(Map<String, String> params) async {
    buf.writeln('<div class="columns docs-layout">');
    buf.writeln('<div class="three-fourths column markdown-body">');
    h1(title, classes: 'page-title');
    await asyncDiv(() async {
      p(description ?? 'Unknown Page');
      await generateContent(params);
    }, classes: 'markdown-body');
    buf.writeln('</div>');
    buf.writeln('</div>');
  }

  Future<void> generateContent(Map<String, String> params);

  void generateFooter() {
    buf.writeln('''
    <footer class="footer">
      Dart ${site.title} <span style="float:right">SDK $_sdkVersion</span>
    </footer>
''');
  }

  void generateHeader() {
    buf.writeln('''
    <header class="masthead">
    <div class="container">
      <span class="masthead-logo">
      <span class="mega-octicon octicon-dashboard"></span>
        ${site.title} Diagnostics
      </span>

      <nav class="masthead-nav">
        <a href="/status" ${isNavPage ? ' class="active"' : ''}>Diagnostics</a>
        <a href="/collectreport" ${isCurrentPage('/collectreport') ? ' class="active"' : ''}>Collect Report</a>
        <a href="/feedback" ${isCurrentPage('/feedback') ? ' class="active"' : ''}>Feedback</a>
        <a href="https://dart.dev/tools/dart-analyze" target="_blank">Docs</a>
        <a href="https://htmlpreview.github.io/?https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server/doc/api.html" target="_blank">Spec</a>
      </nav>
    </div>
    </header>
''');
  }

  @override
  Future<void> generatePage(Map<String, String> params) async {
    buf.writeln('<!DOCTYPE html><html lang="en">');
    buf.write('<head>');
    buf.write('<meta charset="utf-8">');
    buf.write(
      '<meta name="viewport" content="width=device-width, '
      'initial-scale=1.0">',
    );
    buf.writeln('<title>${site.title}</title>');
    buf.writeln(
      '<link rel="stylesheet" '
      'href="https://cdnjs.cloudflare.com/ajax/libs/Primer/6.0.0/build.css">',
    );
    buf.writeln(
      '<link rel="stylesheet" '
      'href="https://cdnjs.cloudflare.com/ajax/libs/octicons/4.4.0/font/octicons.css">',
    );
    buf.writeln(
      '<script type="text/javascript" '
      'src="https://www.gstatic.com/charts/loader.js"></script>',
    );
    buf.writeln('<style>${site.customCss}</style>');
    buf.writeln('</head>');

    buf.writeln('<body>');
    generateHeader();
    buf.writeln('<div class="container">');
    await generateContainer(params);
    generateFooter();
    buf.writeln('</div>'); // div.container
    buf.writeln('</body>');
    buf.writeln('</html>');
  }
}

abstract class DiagnosticPageWithNav extends DiagnosticPage {
  final bool indentInNav;

  DiagnosticPageWithNav(
    super.site,
    super.id,
    super.title, {
    super.description,
    this.indentInNav = false,
  });

  @override
  bool get isNavPage => true;

  String? get navDetail => null;

  bool get showInNav => true;

  @override
  Future<void> generateContainer(Map<String, String> params) async {
    buf.writeln('<div class="columns docs-layout">');

    bool shouldShowInNav(DiagnosticPageWithNav page) => page.showInNav;

    buf.writeln('<div class="one-fifth column">');
    buf.writeln('<nav class="menu docs-menu">');
    var navPages = site.pages.whereType<DiagnosticPageWithNav>().where(
      shouldShowInNav,
    );
    for (var page in navPages) {
      var classes = [
        'menu-item',
        if (page == this) 'selected',
        if (page.indentInNav) 'pl-5',
      ];
      buf.write(
        '<a class="${classes.join(' ')}" '
        'href="${page.path}">${escape(page.title)}',
      );
      var detail = page.navDetail;
      if (detail != null) {
        buf.write('<span class="counter">$detail</span>');
      }
      buf.writeln('</a>');
    }
    buf.writeln('</nav>');
    buf.writeln('</div>');

    buf.writeln('<div class="four-fifths column markdown-body">');
    h1(title, classes: 'page-title');
    await asyncDiv(() async {
      p(description ?? 'Unknown Page');
      await generateContent(params);
    }, classes: 'markdown-body');
    buf.writeln('</div>');

    buf.writeln('</div>');
  }

  String _formatLatencyTiming(int elapsed, int? latency) {
    var buffer = StringBuffer();
    buffer.write(printMilliseconds(elapsed));

    if (latency != null) {
      buffer
        ..write(' <small class="subtle" title="client-to-server latency">(+ ')
        ..write(printMilliseconds(latency))
        ..write(')</small>');
    }

    return buffer.toString();
  }
}

class DiagnosticsSite extends Site implements AbstractHttpHandler {
  /// A flag used to control whether developer support should be included when
  /// building the pages.
  static const bool includeDeveloperSupport = false;

  /// An object that can handle either a WebSocket connection or a connection
  /// to the client over stdio.
  AbstractSocketServer socketServer;

  /// The last few lines printed.
  final List<String> lastPrintedLines;

  DiagnosticsSite(this.socketServer, this.lastPrintedLines)
    : super('Analysis Server') {
    pages.add(CommunicationsPage(this));
    pages.add(ContextsPage(this));
    pages.add(EnvironmentVariablesPage(this));
    pages.add(ExceptionsPage(this));
    // pages.add(new InstrumentationPage(this));
    if (includeDeveloperSupport) {
      pages.add(AnalyticsPage(this));
    }

    // Add server-specific pages. Ordering doesn't matter as the items are
    // sorted later.
    var server = socketServer.analysisServer;
    if (server != null) {
      pages.add(PluginsPage(this, server));
    }
    if (server is LegacyAnalysisServer) {
      pages.add(ClientPage(this));
      pages.add(SubscriptionsPage(this, server));
    } else if (server is LspAnalysisServer) {
      pages.add(LspClientPage(this, server));
      pages.add(LspCapabilitiesPage(this, server));
      pages.add(LspRegistrationsPage(this, server));
    }

    pages.add(AnalysisPerformanceLogPage(this));

    var profiler = ProcessProfiler.getProfilerForPlatform();
    if (profiler != null) {
      pages.add(MemoryAndCpuPage(this, profiler));
    }

    pages.sort(
      (Page a, Page b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );

    // Add the status page at the beginning.
    pages.insert(0, StatusPage(this));

    // Add non-nav pages.
    pages.add(FeedbackPage(this));
    pages.add(CollectReportPage(this));
    pages.add(AstPage(this));
    pages.add(ElementModelPage(this));
    pages.add(ContentsPage(this));

    // Add timing pages
    pages.add(TimingPage(this));
    // (Nested)
    pages.add(AnalysisDriverTimingsPage(this));
    pages.add(AssistsPage(this));
    pages.add(ByteStoreTimingPage(this));
    pages.add(CompletionPage(this));
    pages.add(FixesPage(this));
    pages.add(RefactoringsPage(this));
  }

  @override
  String get customCss => kCustomCss;

  @override
  Page createExceptionPage(String message, StackTrace trace) =>
      ExceptionPage(this, message, trace);

  @override
  Page createUnknownPage(String unknownPath) => NotFoundPage(this, unknownPath);
}

class ElementModelPage extends DiagnosticPageWithNav {
  String? _description;

  ElementModelPage(DiagnosticsSite site)
    : super(
        site,
        'element',
        'Element model',
        description: 'The element model for a file.',
      );

  @override
  String? get description => _description ?? super.description;

  @override
  bool get showInNav => false;

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var filePath = params['file'];
    if (filePath == null) {
      p('No file path provided.');
      return;
    }
    var driver = server.getAnalysisDriver(filePath);
    if (driver == null) {
      p(
        'The file <code>${escape(filePath)}</code> is not being analyzed.',
        raw: true,
      );
      return;
    }
    var result = await driver.getResolvedUnit(filePath);
    if (result is! ResolvedUnitResult) {
      p(
        'The file <code>${escape(filePath)}</code> could not be resolved.',
        raw: true,
      );
      return;
    }
    var libraryFragment = result.unit.declaredFragment;
    if (libraryFragment != null) {
      var writer = ElementWriter(buf);
      writer.write(libraryFragment.element);
    } else {
      p(
        'An element model could not be produced for the file '
        '<code>${escape(filePath)}</code>.',
        raw: true,
      );
    }
  }

  @override
  Future<void> generatePage(Map<String, String> params) async {
    try {
      _description = params['file'];
      await super.generatePage(params);
    } finally {
      _description = null;
    }
  }
}

class EnvironmentVariablesPage extends DiagnosticPageWithNav {
  EnvironmentVariablesPage(DiagnosticsSite site)
    : super(
        site,
        'environment',
        'Environment Variables',
        description:
            'System environment variables as seen from the analysis server.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    buf.writeln('<table>');
    buf.writeln('<tr><th>Variable</th><th>Value</th></tr>');
    for (var key in Platform.environment.keys.toList()..sort()) {
      var value = Platform.environment[key];
      buf.writeln('<tr><td>${escape(key)}</td><td>${escape(value)}</td></tr>');
    }
    buf.writeln('</table>');
  }
}

class ExceptionPage extends DiagnosticPage {
  final StackTrace trace;

  ExceptionPage(DiagnosticsSite site, String message, this.trace)
    : super(site, '', '500 Oops', description: message);

  @override
  Future<void> generateContent(Map<String, String> params) async {
    p(trace.toString(), style: 'white-space: pre');
  }
}

class ExceptionsPage extends DiagnosticPageWithNav {
  ExceptionsPage(DiagnosticsSite site)
    : super(
        site,
        'exceptions',
        'Exceptions',
        description: 'Exceptions from the analysis server.',
      );

  Iterable<ServerException> get exceptions => server.exceptions.items;

  @override
  String get navDetail => '${exceptions.length}';

  @override
  Future<void> generateContent(Map<String, String> params) async {
    if (exceptions.isEmpty) {
      blankslate('No exceptions encountered!');
    } else {
      for (var ex in exceptions) {
        h3('Exception ${ex.exception}');
        p(
          '${escape(ex.message)}<br>${writeOption('fatal', ex.fatal)}',
          raw: true,
        );
        pre(() {
          buf.writeln('<code>${escape(ex.stackTrace.toString())}</code>');
        }, classes: 'scroll-table');
      }
    }
  }
}

class FeedbackPage extends DiagnosticPage {
  FeedbackPage(DiagnosticsSite site)
    : super(
        site,
        'feedback',
        'Feedback',
        description: 'Providing feedback and filing issues.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var issuesUrl = 'https://github.com/dart-lang/sdk/issues';
    p(
      'To file issues or feature requests, see our '
      '<a href="$issuesUrl">bug tracker</a>. When filing an issue, please describe:',
      raw: true,
    );
    ul([
      'what you were doing',
      'what occurred',
      'what you think the expected behavior should have been',
    ], (line) => buf.writeln(line));

    var ideInfo = <String>[];
    var clientId = server.options.clientId;
    if (clientId != null) {
      ideInfo.add(clientId);
    }
    var clientVersion = server.options.clientVersion;
    if (clientVersion != null) {
      ideInfo.add(clientVersion);
    }
    var ideText = ideInfo.map((str) => '<code>$str</code>').join(', ');

    p('Other data to include:');
    ul([
      "the IDE you are using and its version${ideText.isEmpty ? '' : ' ($ideText)'}",
      'the Dart SDK version (<code>${escape(_sdkVersion)}</code>)',
      'your operating system (<code>${escape(Platform.operatingSystem)}</code>)',
    ], (line) => buf.writeln(line));

    p('Thanks!');
  }
}

class FixesPage extends DiagnosticPageWithNav with PerformanceChartMixin {
  FixesPage(DiagnosticsSite site)
    : super(
        site,
        'getFixes',
        'Fixes',
        description: 'Latency and timing statistics for getting fixes.',
        indentInNav: true,
      );

  path.Context get pathContext => server.resourceProvider.pathContext;

  List<GetFixesPerformance> get performanceItems =>
      server.recentPerformance.getFixes.items.toList();

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var requests = performanceItems;

    if (requests.isEmpty) {
      blankslate('No fix requests recorded.');
      return;
    }

    var fastCount =
        requests.where((c) => c.elapsedInMilliseconds <= 100).length;
    p(
      '${requests.length} results; ${printPercentage(fastCount / requests.length)} within 100ms.',
    );

    drawChart(requests);

    // Emit the data as a table
    buf.writeln('<table>');
    buf.writeln(
      '<tr><th>Time</th><th align = "left" title="Time in correction producer `compute()` calls">Producer.compute()</th><th align = "left">Source</th><th>Snippet</th></tr>',
    );

    for (var request in requests) {
      var shortName = pathContext.basename(request.path);
      var (producerTime, producerDetails) = _producerDetails(request);
      buf.writeln(
        '<tr>'
        '<td class="pre right"><a href="/timing?id=${request.id}&kind=getFixes">'
        '${_formatLatencyTiming(request.elapsedInMilliseconds, request.requestLatency)}'
        '</a></td>'
        '<td><abbr title="$producerDetails">${printMilliseconds(producerTime)}</abbr></td>'
        '<td>${escape(shortName)}</td>'
        '<td><code>${escape(request.snippet)}</code></td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }
}

class LspCapabilitiesPage extends DiagnosticPageWithNav {
  @override
  LspAnalysisServer server;

  LspCapabilitiesPage(DiagnosticsSite site, this.server)
    : super(
        site,
        'lsp_capabilities',
        'LSP Capabilities',
        description: 'Client and Server LSP Capabilities.',
        indentInNav: true,
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    buf.writeln('<div class="columns">');
    buf.writeln('<div class="column one-half">');
    h3('Client Capabilities');
    var clientCapabilities = server.editorClientCapabilities;
    if (clientCapabilities == null) {
      p('Client capabilities have not yet been received.');
    } else {
      prettyJson(clientCapabilities.raw.toJson());
    }
    buf.writeln('</div>');

    buf.writeln('<div class="column one-half">');
    h3('Server Capabilities');
    var capabilities = server.capabilities;
    if (capabilities == null) {
      p('Server capabilities have not yet been computed.');
    } else {
      prettyJson(capabilities.toJson());
    }
    buf.writeln('</div>'); // half for server capabilities
    buf.writeln('</div>'); // columns
  }
}

/// Overrides [ClientPage] including LSP-specific data.
class LspClientPage extends ClientPage {
  @override
  LspAnalysisServer server;

  LspClientPage(DiagnosticsSite site, this.server) : super(site, 'lsp', 'LSP');

  @override
  Future<void> generateContent(Map<String, String> params) async {
    h3('LSP Client Info');
    prettyJson({
      'Name': server.clientInfo?.name,
      'Version': server.clientInfo?.version,
      'Host': server.clientAppHost,
      'Remote': server.clientRemoteName,
    });

    h3('Initialization Options');
    prettyJson(server.initializationOptions?.raw);

    await super.generateContent(params);
  }
}

class LspRegistrationsPage extends DiagnosticPageWithNav {
  @override
  LspAnalysisServer server;

  LspRegistrationsPage(DiagnosticsSite site, this.server)
    : super(
        site,
        'lsp_registrations',
        'LSP Registrations',
        description: 'Current LSP feature registrations.',
        indentInNav: true,
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    h3('Current Registrations');
    p(
      'Showing the LSP method name and the registration params sent to the '
      'client.',
    );
    prettyJson(server.capabilitiesComputer.currentRegistrations.toList());
  }
}

// class InstrumentationPage extends DiagnosticPageWithNav {
//   InstrumentationPage(DiagnosticsSite site)
//       : super(site, 'instrumentation', 'Instrumentation',
//             description:
//                 'Verbose instrumentation data from the analysis server.');
//
//   @override
//   Future generateContent(Map<String, String> params) async {
//     p(
//         'Instrumentation can be enabled by starting the analysis server with the '
//         '<code>--instrumentation-log-file=path/to/file</code> flag.',
//         raw: true);
//
//     if (!AnalysisEngine.instance.instrumentationService.isActive) {
//       blankslate('Instrumentation not active.');
//       return;
//     }
//
//     h3('Instrumentation');
//
//     p('Instrumentation active.');
//
//     InstrumentationServer instrumentation =
//         AnalysisEngine.instance.instrumentationService.instrumentationServer;
//     String description = instrumentation.describe;
//     HtmlEscape htmlEscape = new HtmlEscape(HtmlEscapeMode.element);
//     description = htmlEscape.convert(description);
//     // Convert http(s): references to hyperlinks.
//     final RegExp urlRegExp = new RegExp(r'[http|https]+:\/*(\S+)');
//     description = description.replaceAllMapped(urlRegExp, (Match match) {
//       return '<a href="${match.group(0)}">${match.group(1)}</a>';
//     });
//     p(description.replaceAll('\n', '<br>'), raw: true);
//   }
// }

class MemoryAndCpuPage extends DiagnosticPageWithNav {
  final ProcessProfiler profiler;

  MemoryAndCpuPage(DiagnosticsSite site, this.profiler)
    : super(
        site,
        'memory',
        'Memory and CPU Usage',
        description: 'Memory and CPU usage for the analysis server.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var usage = await profiler.getProcessUsage(pid);

    var serviceProtocolInfo = await developer.Service.getInfo();

    if (usage != null) {
      var cpuPercentage = usage.cpuPercentage;
      if (cpuPercentage != null) {
        buf.writeln(writeOption('CPU', printPercentage(cpuPercentage / 100.0)));
      }
      buf.writeln(writeOption('Memory', '${usage.memoryMB.round()} MB'));

      h3('VM');

      if (serviceProtocolInfo.serverUri == null) {
        p('Service protocol not enabled.');
      } else {
        buf.writeln(
          writeOption(
            'Service protocol connection available at',
            '${serviceProtocolInfo.serverUri}',
          ),
        );
        buf.writeln('<br>');
        p(
          'To get detailed performance data on the analysis server, we '
          'recommend using Dart DevTools. For instructions on installing and '
          'using DevTools, see '
          '<a href="https://dart.dev/tools/dart-devtools">dart.dev/tools/dart-devtools</a>.',
          raw: true,
        );
      }
    } else {
      p('Error retrieving the memory and cpu usage information.');
    }
  }
}

class NotFoundPage extends DiagnosticPage {
  @override
  final String path;

  NotFoundPage(DiagnosticsSite site, this.path)
    : super(site, '', '404 Not found', description: "'$path' not found.");

  @override
  Future<void> generateContent(Map<String, String> params) async {}
}

class PluginsPage extends DiagnosticPageWithNav {
  @override
  AnalysisServer server;

  PluginsPage(DiagnosticsSite site, this.server)
    : super(site, 'plugins', 'Plugins', description: 'Plugins in use.');

  @override
  Future<void> generateContent(Map<String, String> params) async {
    h3('Analysis plugins');
    var analysisPlugins =
        AnalysisServer.supportsPlugins
            ? server.pluginManager.plugins
            : <PluginInfo>[];

    if (analysisPlugins.isEmpty) {
      blankslate('No known analysis plugins.');
    } else {
      analysisPlugins.sort(
        (first, second) => first.pluginId.compareTo(second.pluginId),
      );
      for (var plugin in analysisPlugins) {
        var id = plugin.pluginId;
        var data = plugin.data;
        var responseTimes = PluginManager.pluginResponseTimes[plugin] ?? {};

        var components = path.split(id);
        var length = components.length;
        var name = switch (length) {
          0 => 'unknown plugin',
          > 2 => components[length - 3],
          _ => components[length - 1],
        };
        h4(name);

        _emitTable([
          ['Bootstrap package path:', id],
          if (plugin is DiscoveredPluginInfo) ...[
            ['Execution path:', plugin.executionPath.wordBreakOnSlashes],
            ['Packages file path', plugin.packagesPath.wordBreakOnSlashes],
          ],
        ]);

        if (data.name == null) {
          if (plugin.exception != null) {
            p('Not running due to:');
            pre(() {
              buf.write(plugin.exception);
            });
          } else {
            p(
              'Not running for unknown reason (no exception was caught while '
              'starting).',
            );
          }
        } else {
          p('Name: ${data.name}');
          p('Version: ${data.version}');
          p('Associated contexts:');
          var contexts = plugin.contextRoots;
          if (contexts.isEmpty) {
            blankslate('none');
          } else {
            ul(contexts.toList(), (ContextRoot root) {
              buf.writeln(root.root);
            });
          }
          p('Performance:');
          var entries = responseTimes.entries.toList();
          entries.sort((first, second) => first.key.compareTo(second.key));
          for (var entry in entries) {
            var requestName = entry.key;
            var data = entry.value;
            // TODO(brianwilkerson): Consider displaying these times as a graph,
            //  similar to the one in CompletionPage.generateContent.
            var buffer = StringBuffer();
            buffer.write(requestName);
            buffer.write(' ');
            buffer.write(data.toAnalyticsString());
            p(buffer.toString());
          }
        }
      }
    }
  }

  void _emitTable(List<List<String>> data) {
    buf.writeln('<table>');
    for (var row in data) {
      buf.writeln('<tr>');
      for (var value in row) {
        buf.writeln('<td>$value</td>');
      }
      buf.writeln('</tr>');
    }

    buf.writeln('</table>');
  }
}

class RefactoringsPage extends DiagnosticPageWithNav
    with PerformanceChartMixin {
  RefactoringsPage(DiagnosticsSite site)
    : super(
        site,
        'getRefactorings',
        'Refactorings',
        description: 'Latency and timing statistics for getting refactorings.',
        indentInNav: true,
      );

  path.Context get pathContext => server.resourceProvider.pathContext;

  List<GetRefactoringsPerformance> get performanceItems =>
      server.recentPerformance.getRefactorings.items.toList();

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var requests = performanceItems;

    if (requests.isEmpty) {
      blankslate('No refactoring requests recorded.');
      return;
    }

    var fastCount =
        requests.where((c) => c.elapsedInMilliseconds <= 100).length;
    p(
      '${requests.length} results; ${printPercentage(fastCount / requests.length)} within 100ms.',
    );

    drawChart(requests);

    // Emit the data as a table
    buf.writeln('<table>');
    buf.writeln(
      '<tr><th>Time</th><th align = "left" title="Time in refactoring producer `compute()` calls">Producer.compute()</th><th align = "left">Source</th><th>Snippet</th></tr>',
    );

    for (var request in requests) {
      var shortName = pathContext.basename(request.path);
      var (producerTime, producerDetails) = _producerDetails(request);
      buf.writeln(
        '<tr>'
        '<td class="pre right"><a href="/timing?id=${request.id}&kind=getRefactorings">'
        '${_formatLatencyTiming(request.elapsedInMilliseconds, request.requestLatency)}'
        '</a></td>'
        '<td><abbr title="$producerDetails">${printMilliseconds(producerTime)}</abbr></td>'
        '<td>${escape(shortName)}</td>'
        '<td><code>${escape(request.snippet)}</code></td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }
}

class StatusPage extends DiagnosticPageWithNav {
  StatusPage(DiagnosticsSite site)
    : super(
        site,
        'status',
        'Status',
        description: 'General status and diagnostics for the analysis server.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    buf.writeln('<div class="columns">');

    buf.writeln('<div class="column one-half">');
    h3('Status');
    buf.writeln(writeOption('Server type', server.runtimeType));
    // buf.writeln(writeOption('Instrumentation enabled',
    //     AnalysisEngine.instance.instrumentationService.isActive));
    buf.writeln(
      writeOption(
        '(Scheduler) allow overlapping message handlers:',
        MessageScheduler.allowOverlappingHandlers,
      ),
    );
    buf.writeln(writeOption('Server process ID', pid));
    buf.writeln('</div>');

    buf.writeln('<div class="column one-half">');
    h3('Versions');
    buf.writeln(writeOption('Analysis server version', PROTOCOL_VERSION));
    buf.writeln(writeOption('Dart SDK', Platform.version));
    buf.writeln('</div>');

    buf.writeln('</div>');

    // SDK configuration overrides.
    var sdkConfig = server.options.configurationOverrides;
    if (sdkConfig?.hasAnyOverrides == true) {
      buf.writeln('<div class="columns">');

      buf.writeln('<div class="column one-half">');
      h3('Configuration Overrides');
      buf.writeln(
        '<pre><code>${sdkConfig?.displayString ?? '<unknown overrides>'}</code></pre><br>',
      );
      buf.writeln('</div>');

      buf.writeln('</div>');
    }

    var lines = site.lastPrintedLines;
    if (lines.isNotEmpty) {
      h3('Debug output');
      p(lines.join('\n'), style: 'white-space: pre');
    }
  }
}

class SubscriptionsPage extends DiagnosticPageWithNav {
  @override
  LegacyAnalysisServer server;

  SubscriptionsPage(DiagnosticsSite site, this.server)
    : super(
        site,
        'subscriptions',
        'Subscriptions',
        description: 'Registered subscriptions to analysis server events.',
      );

  @override
  Future<void> generateContent(Map<String, String> params) async {
    // server domain
    h3('Server domain subscriptions');
    ul(ServerService.values, (item) {
      if (server.serverServices.contains(item)) {
        buf.write('$item (has subscriptions)');
      } else {
        buf.write('$item (no subscriptions)');
      }
    });

    // analysis domain
    h3('Analysis domain subscriptions');
    for (var service in AnalysisService.values) {
      buf.writeln('${service.name}<br>');
      ul(server.analysisServices[service] ?? {}, (item) {
        buf.write('$item');
      });
    }
  }
}

class TimingPage extends DiagnosticPageWithNav with PerformanceChartMixin {
  TimingPage(DiagnosticsSite site)
    : super(site, 'timing', 'Timing', description: 'Timing statistics.');

  @override
  Future<void> generateContent(Map<String, String> params) async {
    var kind = params['kind'];

    List<RequestPerformance> items;
    List<RequestPerformance>? itemsSlow;
    if (kind == 'completion') {
      items = server.recentPerformance.completion.items.toList();
    } else if (kind == 'getAssists') {
      items = server.recentPerformance.getAssists.items.toList();
    } else if (kind == 'getFixes') {
      items = server.recentPerformance.getFixes.items.toList();
    } else if (kind == 'getRefactorings') {
      items = server.recentPerformance.getRefactorings.items.toList();
    } else {
      items = server.recentPerformance.requests.items.toList();
      itemsSlow = server.recentPerformance.slowRequests.items.toList();
    }

    var id = int.tryParse(params['id'] ?? '');
    if (id == null) {
      _generateList(items, itemsSlow);
    } else {
      _generateDetails(id, items, itemsSlow);
    }
  }

  void _emitTable(List<RequestPerformance> items) {
    buf.writeln('<table>');
    buf.writeln('<tr><th>Time</th><th>Request</th></tr>');
    for (var item in items) {
      buf.writeln(
        '<tr>'
        '<td class="pre right"><a href="/timing?id=${item.id}">'
        '${_formatLatencyTiming(item.performance.elapsed.inMilliseconds, item.requestLatency)}'
        '</a></td>'
        '<td>${escape(item.operation)}</td>'
        '</tr>',
      );
    }
    buf.writeln('</table>');
  }

  void _generateDetails(
    int id,
    List<RequestPerformance> items,
    List<RequestPerformance>? itemsSlow,
  ) {
    var item = items.firstWhereOrNull((info) => info.id == id);
    if (item == null && itemsSlow != null) {
      item = itemsSlow.firstWhereOrNull((info) => info.id == id);
    }

    if (item == null) {
      blankslate(
        'Unable to find data for $id. '
        'Perhaps newer requests have pushed it out of the buffer?',
      );
      return;
    }

    h3("Request '${item.operation}'");
    var requestLatency = item.requestLatency;
    if (requestLatency != null) {
      buf.writeln('Request latency: $requestLatency ms.');
      buf.writeln('<p>');
    }
    var startTime = item.startTime;
    if (startTime != null) {
      buf.writeln('Request start time: ${startTime.toIso8601String()}.');
      buf.writeln('<p>');
    }
    var buffer = StringBuffer();
    item.performance.write(buffer: buffer);
    pre(() {
      buf.write('<code>');
      buf.write(escape('$buffer'));
      buf.writeln('</code>');
    });
  }

  void _generateList(
    List<RequestPerformance> items,
    List<RequestPerformance>? itemsSlow,
  ) {
    if (items.isEmpty) {
      assert(itemsSlow == null || itemsSlow.isEmpty);
      blankslate('No requests recorded.');
      return;
    }

    drawChart(items);

    // emit the data as a table
    if (itemsSlow != null) {
      h3('Recent requests');
    }
    _emitTable(items);

    if (itemsSlow != null) {
      h3('Slow requests');
      _emitTable(itemsSlow);
    }
  }
}

/// A base class for pages that provide real-time logging over a WebSocket.
abstract class WebSocketLoggingPage extends DiagnosticPageWithNav
    implements WebSocketPage {
  WebSocketLoggingPage(super.site, super.id, super.title, {super.description});

  void button(String text, {String? id, String classes = '', String? onClick}) {
    var attributes = {
      'type': 'button',
      if (id != null) 'id': id,
      'class': 'btn $classes'.trim(),
      if (onClick != null) 'onclick': onClick,
      'value': text,
    };

    tag('input', attributes: attributes);
  }

  /// Writes an HTML tag for [tagName] with the given [attributes].
  ///
  /// If [gen] is supplied, it is executed to write child content to [buf].
  void tag(
    String tagName, {
    Map<String, String>? attributes,
    void Function()? gen,
  }) {
    buf.write('<$tagName');
    if (attributes != null) {
      for (var MapEntry(:key, :value) in attributes.entries) {
        buf.write(' $key="${escape(value)}"');
      }
    }
    buf.write('>');
    gen?.call();
    buf.writeln('</$tagName>');
  }

  /// Writes Start/Stop/Clear buttons and associated scripts to connect and
  /// disconnect a websocket back to this page, along with a panel to show
  /// any output received from the server over the WebSocket.
  void _writeWebSocketLogPanel() {
    // Add buttons to start/stop logging. Using "position: sticky" so they're
    // always visible even when scrolled.
    tag(
      'div',
      attributes: {
        'style':
            'position: sticky; top: 10px; text-align: right; margin-bottom: 20px;',
      },
      gen: () {
        button(
          'Start Logging',
          id: 'btnStartLog',
          classes: 'btn-danger',
          onClick: 'startLogging()',
        );
        button(
          'Stop Logging',
          id: 'btnStopLog',
          classes: 'btn-danger',
          onClick: 'stopLogging()',
        );
        button('Clear', onClick: 'clearLog()');
      },
    );

    // Write the log container.
    pre(() {
      tag('code', attributes: {'id': 'logContent'});
    });

    // Write the scripts to connect/disconnect the websocket and display the
    // data.
    buf.write('''
<script>
  let logContent = document.getElementById('logContent');
  let btnEnable = document.getElementById('btnEnable');
  let btnDisable = document.getElementById('btnDisable');
  let socket;

  function clearLog(data) {
    logContent.textContent = '';
  }

  function append(data) {
    logContent.appendChild(document.createTextNode(data));
  }

  function startLogging() {
    append("Connecting...\\n");
    socket = new WebSocket("${this.path}");
    socket.addEventListener("open", (event) => {
      append("Connected!\\n");
    });
    socket.addEventListener("close", (event) => {
      append("Disconnected!\\n");
      stopLogging();
    });
    socket.addEventListener("message", (event) => {
      append(event.data);
    });
    btnEnable.disabled = true;
    btnDisable.disabled = false;
  }

  function stopLogging() {
    socket?.close(1000, 'User closed');
    socket = undefined;
    btnEnable.disabled = false;
    btnDisable.disabled = true;
  }
</script>
''');
  }
}

class _CollectedOptionsData {
  final Set<String> lints = <String>{};
  final Set<String> plugins = <String>{};
}

extension on LibraryCycle {
  /// The number of libraries in the cycle.
  int get size => libraries.length;
}

extension on String {
  String get wordBreakOnSlashes => splitMapJoin('/', onMatch: (_) => '/<wbr>');
}
