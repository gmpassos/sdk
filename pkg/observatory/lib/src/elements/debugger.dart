// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library debugger_page_element;

import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:web/web.dart';

import '../../app.dart';
import '../../cli.dart';
import '../../debugger.dart';
import '../../event.dart';
import '../../models.dart' as M;
import '../../repositories.dart' as R;
import '../../service.dart' as S;
import 'function_ref.dart';
import 'helpers/any_ref.dart';
import 'helpers/custom_element.dart';
import 'helpers/element_utils.dart';
import 'helpers/nav_bar.dart';
import 'helpers/nav_menu.dart';
import 'helpers/rendering_scheduler.dart';
import 'helpers/uris.dart';
import 'instance_ref.dart';
import 'nav/isolate_menu.dart';
import 'nav/notify.dart';
import 'nav/top_menu.dart';
import 'nav/vm_menu.dart';
import 'source_inset.dart';
import 'source_link.dart';

// TODO(turnidge): Move Debugger, DebuggerCommand to debugger library.
abstract class DebuggerCommand extends Command {
  ObservatoryDebugger debugger;

  DebuggerCommand(Debugger debugger, name, List<Command> children)
    : debugger = debugger as ObservatoryDebugger,
      super(name, children);

  String get helpShort;
  String get helpLong;
}

// TODO(turnidge): Rewrite HelpCommand so that it is a general utility
// provided by the cli library.
class HelpCommand extends DebuggerCommand {
  HelpCommand(ObservatoryDebugger debugger)
    : super(debugger, 'help', <Command>[new HelpHotkeysCommand(debugger)]);

  String _nameAndAlias(Command cmd) {
    if (cmd.alias == null) {
      return cmd.fullName;
    } else {
      return '${cmd.fullName}, ${cmd.alias}';
    }
  }

  Future run(List<String> args) {
    var con = debugger.console;
    if (args.length == 0) {
      // Print list of all top-level commands.
      var commands = debugger.cmd.matchCommand(<String>[], false);
      commands.sort((a, b) => a.name.compareTo(b.name));
      con.print('List of commands:\n');
      for (Command c in commands) {
        DebuggerCommand command = c as DebuggerCommand;
        con.print(
          '${_nameAndAlias(command).padRight(12)} '
          '- ${command.helpShort}',
        );
      }
      con.print(
        "\nFor more information on a specific command type 'help <command>'\n"
        "For a list of hotkeys type 'help hotkeys'\n"
        "\n"
        "Command prefixes are accepted (e.g. 'h' for 'help')\n"
        "Hit [TAB] to complete a command (try 'is[TAB][TAB]')\n"
        "Hit [ENTER] to repeat the last command\n"
        "Use up/down arrow for command history\n",
      );
      return new Future.value(null);
    } else {
      // Print any matching commands.
      var commands = debugger.cmd.matchCommand(args, true);
      commands.sort((a, b) => a.name.compareTo(b.name));
      if (commands.isEmpty) {
        var line = args.join(' ');
        con.print("No command matches '${line}'");
        return new Future.value(null);
      }
      con.print('');
      for (Command c in commands) {
        DebuggerCommand command = c as DebuggerCommand;
        con.printBold(_nameAndAlias(command));
        con.print(command.helpLong);

        var newArgs = <String>[];
        newArgs.addAll(args.take(args.length - 1));
        newArgs.add(command.name);
        newArgs.add('');
        var subCommands = debugger.cmd.matchCommand(newArgs, false);
        subCommands.remove(command);
        if (subCommands.isNotEmpty) {
          subCommands.sort((a, b) => a.name.compareTo(b.name));
          con.print('Subcommands:\n');
          for (Command c in subCommands) {
            DebuggerCommand subCommand = c as DebuggerCommand;
            con.print(
              '    ${subCommand.fullName.padRight(16)} '
              '- ${subCommand.helpShort}',
            );
          }
          con.print('');
        }
      }
      return new Future.value(null);
    }
  }

  Future<List<String>> complete(List<String> args) {
    var commands = debugger.cmd.matchCommand(args, false);
    var result = commands.map((command) => '${command.fullName} ');
    return new Future.value(result.toList());
  }

  String helpShort =
      'List commands or provide details about a specific command';

  String helpLong =
      'List commands or provide details about a specific command.\n'
      '\n'
      'Syntax: help            - Show a list of all commands\n'
      '        help <command>  - Help for a specific command\n';
}

class HelpHotkeysCommand extends DebuggerCommand {
  HelpHotkeysCommand(Debugger debugger)
    : super(debugger, 'hotkeys', <Command>[]);

  Future run(List<String> args) {
    var con = debugger.console;
    con.print(
      "List of hotkeys:\n"
      "\n"
      "[TAB]        - complete a command\n"
      "[Up Arrow]   - history previous\n"
      "[Down Arrow] - history next\n"
      "\n"
      "[Page Up]    - move up one frame\n"
      "[Page Down]  - move down one frame\n"
      "\n"
      "[F7]         - continue execution of the current isolate\n"
      "[Ctrl ;]     - pause execution of the current isolate\n"
      "\n"
      "[F8]         - toggle breakpoint at current location\n"
      "[F9]         - next\n"
      "[F10]        - step\n"
      "\n",
    );
    return new Future.value(null);
  }

  String helpShort = 'Provide a list of hotkeys';

  String helpLong =
      'Provide a list of key hotkeys.\n'
      '\n'
      'Syntax: help hotkeys\n';
}

class PrintCommand extends DebuggerCommand {
  PrintCommand(Debugger debugger) : super(debugger, 'print', <Command>[]) {
    alias = 'p';
  }

  Future run(List<String> args) async {
    if (args.length < 1) {
      debugger.console.print('print expects arguments');
      return;
    }
    if (debugger.currentFrame == null) {
      debugger.console.print('No stack');
      return;
    }
    var expression = args.join('');
    var response = await debugger.isolate.evalFrame(
      debugger.currentFrame!,
      expression,
    );
    if (response is S.DartError) {
      debugger.console.print(response.message!);
    } else if (response is S.Sentinel) {
      debugger.console.print(response.valueAsString);
    } else {
      debugger.console.print('= ', newline: false);
      debugger.console.printRef(
        debugger.isolate,
        response as S.Instance,
        debugger.objects!,
      );
    }
  }

  String helpShort = 'Evaluate and print an expression in the current frame';

  String helpLong =
      'Evaluate and print an expression in the current frame.\n'
      '\n'
      'Syntax: print <expression>\n'
      '        p <expression>\n';
}

class DownCommand extends DebuggerCommand {
  DownCommand(Debugger debugger) : super(debugger, 'down', <Command>[]);

  Future run(List<String> args) {
    int count = 1;
    if (args.length == 1) {
      count = int.parse(args[0]);
    } else if (args.length > 1) {
      debugger.console.print('down expects 0 or 1 argument');
      return new Future.value(null);
    }
    if (debugger.currentFrame == null) {
      debugger.console.print('No stack');
      return new Future.value(null);
    }
    try {
      debugger.downFrame(count);
      debugger.console.print('frame = ${debugger.currentFrame}');
    } catch (e) {
      debugger.console.print(
        'frame must be in range [${(e as dynamic).start}..${(e as dynamic).end - 1}]',
      );
    }
    return new Future.value(null);
  }

  String helpShort = 'Move down one or more frames (hotkey: [Page Down])';

  String helpLong =
      'Move down one or more frames.\n'
      '\n'
      'Hotkey: [Page Down]\n'
      '\n'
      'Syntax: down\n'
      '        down <count>\n';
}

class UpCommand extends DebuggerCommand {
  UpCommand(Debugger debugger) : super(debugger, 'up', <Command>[]);

  Future run(List<String> args) {
    int count = 1;
    if (args.length == 1) {
      count = int.parse(args[0]);
    } else if (args.length > 1) {
      debugger.console.print('up expects 0 or 1 argument');
      return new Future.value(null);
    }
    if (debugger.currentFrame == null) {
      debugger.console.print('No stack');
      return new Future.value(null);
    }
    try {
      debugger.upFrame(count);
      debugger.console.print('frame = ${debugger.currentFrame}');
    } on RangeError catch (e) {
      debugger.console.print(
        'frame must be in range [${e.start}..${e.end! - 1}]',
      );
    }
    return new Future.value(null);
  }

  String helpShort = 'Move up one or more frames (hotkey: [Page Up])';

  String helpLong =
      'Move up one or more frames.\n'
      '\n'
      'Hotkey: [Page Up]\n'
      '\n'
      'Syntax: up\n'
      '        up <count>\n';
}

class FrameCommand extends DebuggerCommand {
  FrameCommand(Debugger debugger) : super(debugger, 'frame', <Command>[]) {
    alias = 'f';
  }

  Future run(List<String> args) {
    int frame = 1;
    if (args.length == 1) {
      frame = int.parse(args[0]);
    } else {
      debugger.console.print('frame expects 1 argument');
      return new Future.value(null);
    }
    if (debugger.currentFrame == null) {
      debugger.console.print('No stack');
      return new Future.value(null);
    }
    try {
      debugger.currentFrame = frame;
      debugger.console.print('frame = ${debugger.currentFrame}');
    } on RangeError catch (e) {
      debugger.console.print(
        'frame must be in range [${e.start}..${e.end! - 1}]',
      );
    }
    return new Future.value(null);
  }

  String helpShort = 'Set the current frame';

  String helpLong =
      'Set the current frame.\n'
      '\n'
      'Syntax: frame <number>\n'
      '        f <count>\n';
}

class PauseCommand extends DebuggerCommand {
  PauseCommand(Debugger debugger) : super(debugger, 'pause', <Command>[]);

  Future run(List<String> args) {
    return debugger.pause();
  }

  String helpShort = 'Pause the isolate (hotkey: [Ctrl ;])';

  String helpLong =
      'Pause the isolate.\n'
      '\n'
      'Hotkey: [Ctrl ;]\n'
      '\n'
      'Syntax: pause\n';
}

class ContinueCommand extends DebuggerCommand {
  ContinueCommand(Debugger debugger)
    : super(debugger, 'continue', <Command>[]) {
    alias = 'c';
  }

  Future run(List<String> args) {
    return debugger.resume();
  }

  String helpShort = 'Resume execution of the isolate (hotkey: [F7])';

  String helpLong =
      'Continue running the isolate.\n'
      '\n'
      'Hotkey: [F7]\n'
      '\n'
      'Syntax: continue\n'
      '        c\n';
}

class SmartNextCommand extends DebuggerCommand {
  SmartNextCommand(Debugger debugger) : super(debugger, 'next', <Command>[]) {
    alias = 'n';
  }

  Future run(List<String> args) async {
    return debugger.smartNext();
  }

  String helpShort =
      'Continue running the isolate until it reaches the next source location '
      'in the current function (hotkey: [F9])';

  String helpLong =
      'Continue running the isolate until it reaches the next source location '
      'in the current function.\n'
      '\n'
      'Hotkey: [F9]\n'
      '\n'
      'Syntax: next\n';
}

class SyncNextCommand extends DebuggerCommand {
  SyncNextCommand(Debugger debugger)
    : super(debugger, 'next-sync', <Command>[]);

  Future run(List<String> args) {
    return debugger.syncNext();
  }

  String helpShort = 'Run until return/unwind to current activation.';

  String helpLong =
      'Continue running the isolate until control returns to the current '
      'activation or one of its callers.\n'
      '\n'
      'Syntax: next-sync\n';
}

class AsyncNextCommand extends DebuggerCommand {
  AsyncNextCommand(Debugger debugger)
    : super(debugger, 'next-async', <Command>[]);

  Future run(List<String> args) {
    return debugger.asyncNext();
  }

  String helpShort = 'Step over await or yield';

  String helpLong =
      'Continue running the isolate until control returns to the current '
      'activation of an async or async* function.\n'
      '\n'
      'Syntax: next-async\n';
}

class StepCommand extends DebuggerCommand {
  StepCommand(Debugger debugger) : super(debugger, 'step', <Command>[]) {
    alias = 's';
  }

  Future run(List<String> args) {
    return debugger.step();
  }

  String helpShort =
      'Continue running the isolate until it reaches the next source location'
      ' (hotkey: [F10]';

  String helpLong =
      'Continue running the isolate until it reaches the next source '
      'location.\n'
      '\n'
      'Hotkey: [F10]\n'
      '\n'
      'Syntax: step\n';
}

class RewindCommand extends DebuggerCommand {
  RewindCommand(Debugger debugger) : super(debugger, 'rewind', <Command>[]);

  Future run(List<String> args) async {
    try {
      int? count = 1;
      if (args.length == 1) {
        count = int.tryParse(args[0]);
        if (count == null || count < 1 || count >= debugger.stackDepth) {
          debugger.console.print(
            'Frame must be an int in bounds [1..${debugger.stackDepth - 1}]:'
            ' saw ${args[0]}',
          );
          return;
        }
      } else if (args.length > 1) {
        debugger.console.print('rewind expects 0 or 1 argument');
        return;
      }
      await debugger.rewind(count);
    } on S.ServerRpcException catch (e) {
      if (e.code == S.ServerRpcException.kCannotResume) {
        debugger.console.printRed(e.data!['details']);
      } else {
        rethrow;
      }
    }
  }

  String helpShort = 'Rewind the stack to a previous frame';

  String helpLong =
      'Rewind the stack to a previous frame.\n'
      '\n'
      'Syntax: rewind\n'
      '        rewind <count>\n';
}

class ReloadCommand extends DebuggerCommand {
  final M.IsolateRepository _isolates;

  ReloadCommand(Debugger debugger, this._isolates)
    : super(debugger, 'reload', <Command>[]);

  Future run(List<String> args) async {
    try {
      if (args.length > 0) {
        debugger.console.print('reload expects no arguments');
        return;
      }
      if (_isolates.reloadSourcesServices.isEmpty) {
        await _isolates.reloadSources(debugger.isolate);
      } else {
        await _isolates.reloadSources(
          debugger.isolate,
          service: _isolates.reloadSourcesServices.first,
        );
      }
      debugger.console.print('reload complete');
      await debugger.refreshStack();
    } on S.ServerRpcException catch (e) {
      if (e.code == S.ServerRpcException.kIsolateReloadBarred ||
          e.code == S.ServerRpcException.kIsolateIsReloading) {
        debugger.console.printRed(e.data!['details']);
      } else {
        rethrow;
      }
    }
  }

  String helpShort = 'Reload the sources for the current isolate';

  String helpLong =
      'Reload the sources for the current isolate.\n'
      '\n'
      'Syntax: reload\n';
}

class ClsCommand extends DebuggerCommand {
  ClsCommand(Debugger debugger) : super(debugger, 'cls', <Command>[]) {}

  Future run(List<String> args) {
    debugger.console.clear();
    debugger.console.newline();
    return new Future.value(null);
  }

  String helpShort = 'Clear the console';

  String helpLong =
      'Clear the console.\n'
      '\n'
      'Syntax: cls\n';
}

class LogCommand extends DebuggerCommand {
  LogCommand(Debugger debugger) : super(debugger, 'log', <Command>[]);

  Future run(List<String> args) async {
    if (args.length == 0) {
      debugger.console.print(
        'Current log level: '
        '${debugger._consolePrinter._minimumLogLevel.name}',
      );
      return new Future.value(null);
    }
    if (args.length > 1) {
      debugger.console.print("log expects zero or one arguments");
      return new Future.value(null);
    }
    var level = _findLevel(args[0]);
    if (level == null) {
      debugger.console.print('No such log level: ${args[0]}');
      return new Future.value(null);
    }
    debugger._consolePrinter._minimumLogLevel = level;
    debugger.console.print('Set log level to: ${level.name}');
    return new Future.value(null);
  }

  Level? _findLevel(String levelName) {
    levelName = levelName.toUpperCase();
    for (var level in Level.LEVELS) {
      if (level.name == levelName) {
        return level;
      }
    }
    return null;
  }

  Future<List<String>> complete(List<String> args) {
    if (args.length != 1) {
      return new Future.value([args.join('')]);
    }
    var prefix = args[0].toUpperCase();
    var result = <String>[];
    for (var level in Level.LEVELS) {
      if (level.name.startsWith(prefix)) {
        result.add(level.name);
      }
    }
    return new Future.value(result);
  }

  String helpShort = 'Control which log messages are displayed';

  String helpLong =
      'Get or set the minimum log level that should be displayed.\n'
      '\n'
      'Log levels (in ascending order): ALL, FINEST, FINER, FINE, CONFIG, '
      'INFO, WARNING, SEVERE, SHOUT, OFF\n'
      '\n'
      'Default: OFF\n'
      '\n'
      'Syntax: log          '
      '# Display the current minimum log level.\n'
      '        log <level>  '
      '# Set the minimum log level to <level>.\n'
      '        log OFF      '
      '# Display no log messages.\n'
      '        log ALL      '
      '# Display all log messages.\n';
}

class FinishCommand extends DebuggerCommand {
  FinishCommand(Debugger debugger) : super(debugger, 'finish', <Command>[]);

  Future run(List<String> args) {
    if (debugger.isolatePaused()) {
      var event = debugger.isolate.pauseEvent;
      if (event is M.PauseStartEvent) {
        debugger.console.print(
          "Type 'continue' [F7] or 'step' [F10] to start the isolate",
        );
        return new Future.value(null);
      }
      if (event is M.PauseExitEvent) {
        debugger.console.print("Type 'continue' [F7] to exit the isolate");
        return new Future.value(null);
      }
      return debugger.isolate.stepOut();
    } else {
      debugger.console.print('The program is already running');
      return new Future.value(null);
    }
  }

  String helpShort =
      'Continue running the isolate until the current function exits';

  String helpLong =
      'Continue running the isolate until the current function exits.\n'
      '\n'
      'Syntax: finish\n';
}

class SetCommand extends DebuggerCommand {
  SetCommand(Debugger debugger) : super(debugger, 'set', <Command>[]);

  static var _boeValues = ['All', 'None', 'Unhandled'];
  static var _boolValues = ['false', 'true'];

  static var _options = {
    'break-on-exception': [
      _boeValues,
      _setBreakOnException,
      (debugger, _) => debugger.breakOnException,
    ],
    'up-is-down': [
      _boolValues,
      _setUpIsDown,
      (debugger, _) => debugger.upIsDown,
    ],
    'causal-async-stacks': [
      _boolValues,
      _setCausalAsyncStacks,
      (debugger, _) => debugger.saneAsyncStacks,
    ],
  };

  static Future _setBreakOnException(debugger, name, value) async {
    var result = await debugger.isolate.setIsolatePauseMode(value);
    if (result.isError) {
      debugger.console.print(result.toString());
    } else {
      // Printing will occur elsewhere.
      debugger.breakOnException = value;
    }
  }

  static Future _setUpIsDown(debugger, name, value) async {
    if (value == 'true') {
      debugger.upIsDown = true;
    } else {
      debugger.upIsDown = false;
    }
    debugger.console.print('${name} = ${value}');
  }

  static Future _setCausalAsyncStacks(debugger, name, value) async {
    if (value == 'true') {
      debugger.causalAsyncStacks = true;
    } else {
      debugger.causalAsyncStacks = false;
    }
    debugger.refreshStack();
    debugger.console.print('${name} = ${value}');
  }

  Future run(List<String> args) async {
    if (args.length == 0) {
      for (var name in _options.keys) {
        dynamic getHandler = _options[name]![2];
        var value = await getHandler(debugger, name);
        debugger.console.print("${name} = ${value}");
      }
    } else if (args.length == 1) {
      var name = args[0].trim();
      var optionInfo = _options[name];
      if (optionInfo == null) {
        debugger.console.print("unrecognized option: $name");
        return;
      } else {
        dynamic getHandler = optionInfo[2];
        var value = await getHandler(debugger, name);
        debugger.console.print("${name} = ${value}");
      }
    } else if (args.length == 2) {
      var name = args[0].trim();
      var value = args[1].trim();
      var optionInfo = _options[name];
      if (optionInfo == null) {
        debugger.console.print("unrecognized option: $name");
        return;
      }
      dynamic validValues = optionInfo[0];
      if (!validValues.contains(value)) {
        debugger.console.print("'${value}' is not in ${validValues}");
        return;
      }
      dynamic setHandler = optionInfo[1];
      await setHandler(debugger, name, value);
    } else {
      debugger.console.print("set expects 0, 1, or 2 arguments");
    }
  }

  Future<List<String>> complete(List<String> args) {
    if (args.length < 1 || args.length > 2) {
      return new Future.value([args.join('')]);
    }
    var result = <String>[];
    if (args.length == 1) {
      var prefix = args[0];
      for (var option in _options.keys) {
        if (option.startsWith(prefix)) {
          result.add('${option} ');
        }
      }
    }
    if (args.length == 2) {
      var name = args[0].trim();
      var prefix = args[1];
      var optionInfo = _options[name];
      if (optionInfo != null) {
        dynamic validValues = optionInfo[0];
        for (var value in validValues) {
          if (value.startsWith(prefix)) {
            result.add('${args[0]}${value} ');
          }
        }
      }
    }
    return new Future.value(result);
  }

  String helpShort = 'Set a debugger option';

  String helpLong =
      'Set a debugger option.\n'
      '\n'
      'Known options:\n'
      '  break-on-exception    # Should the debugger break on exceptions?\n'
      "                        # ${_boeValues}\n"
      '  up-is-down            # Reverse meaning of up/down commands?\n'
      "                        # ${_boolValues}\n"
      '\n'
      'Syntax: set                    # Display all option settings\n'
      '        set <option>           # Get current value for option\n'
      '        set <option> <value>   # Set value for option';
}

class BreakCommand extends DebuggerCommand {
  BreakCommand(Debugger debugger) : super(debugger, 'break', <Command>[]);

  Future run(List<String> args) async {
    if (args.length > 1) {
      debugger.console.print('not implemented');
      return;
    }
    var arg = (args.length == 0 ? '' : args[0]);
    var loc = await DebuggerLocation.parse(debugger, arg);
    if (loc.valid) {
      if (loc.function != null) {
        try {
          await debugger.isolate.addBreakpointAtEntry(loc.function!);
        } on S.ServerRpcException catch (e) {
          if (e.code == S.ServerRpcException.kCannotAddBreakpoint) {
            debugger.console.print('Unable to set breakpoint at ${loc}');
          } else {
            rethrow;
          }
        }
      } else {
        assert(loc.script != null);
        var script = loc.script!;
        await script.load();
        if (loc.line! < 1 || loc.line! > script.lines.length) {
          debugger.console.print(
            'line number must be in range [1..${script.lines.length}]',
          );
          return;
        }
        try {
          await debugger.isolate.addBreakpoint(script, loc.line!, loc.col);
        } on S.ServerRpcException catch (e) {
          if (e.code == S.ServerRpcException.kCannotAddBreakpoint) {
            debugger.console.print('Unable to set breakpoint at ${loc}');
          } else {
            rethrow;
          }
        }
      }
    } else {
      debugger.console.print(loc.errorMessage!);
    }
  }

  Future<List<String>> complete(List<String> args) {
    if (args.length != 1) {
      return new Future.value([args.join('')]);
    }
    // TODO - fix DebuggerLocation complete
    return new Future.value(DebuggerLocation.complete(debugger, args[0]));
  }

  String helpShort =
      'Add a breakpoint by source location or function name'
      ' (hotkey: [F8])';

  String helpLong =
      'Add a breakpoint by source location or function name.\n'
      '\n'
      'Hotkey: [F8]\n'
      '\n'
      'Syntax: break                       '
      '# Break at the current position\n'
      '        break <line>                '
      '# Break at a line in the current script\n'
      '                                    '
      '  (e.g \'break 11\')\n'
      '        break <line>:<col>          '
      '# Break at a line:col in the current script\n'
      '                                    '
      '  (e.g \'break 11:8\')\n'
      '        break <script>:<line>       '
      '# Break at a line:col in a specific script\n'
      '                                    '
      '  (e.g \'break test.dart:11\')\n'
      '        break <script>:<line>:<col> '
      '# Break at a line:col in a specific script\n'
      '                                    '
      '  (e.g \'break test.dart:11:8\')\n'
      '        break <function>            '
      '# Break at the named function\n'
      '                                    '
      '  (e.g \'break main\' or \'break Class.someFunction\')\n';
}

class ClearCommand extends DebuggerCommand {
  ClearCommand(Debugger debugger) : super(debugger, 'clear', <Command>[]);

  Future run(List<String> args) async {
    if (args.length > 1) {
      debugger.console.print('not implemented');
      return;
    }
    var arg = (args.length == 0 ? '' : args[0]);
    var loc = await DebuggerLocation.parse(debugger, arg);
    if (!loc.valid) {
      debugger.console.print(loc.errorMessage!);
      return;
    }
    if (loc.function != null) {
      debugger.console.print(
        'Ignoring breakpoint at $loc: '
        'Clearing function breakpoints not yet implemented',
      );
      return;
    }

    var script = loc.script!;
    if (loc.line! < 1 || loc.line! > script.lines.length) {
      debugger.console.print(
        'line number must be in range [1..${script.lines.length}]',
      );
      return;
    }
    var lineInfo = script.getLine(loc.line!)!;
    var bpts = lineInfo.breakpoints;
    var foundBreakpoint = false;
    if (bpts != null) {
      var bptList = bpts.toList();
      for (var bpt in bptList) {
        if (loc.col == null ||
            loc.col == script.tokenToCol(bpt.location!.tokenPos)) {
          foundBreakpoint = true;
          var result = await debugger.isolate.removeBreakpoint(bpt);
          if (result is S.DartError) {
            debugger.console.print(
              'Error clearing breakpoint ${bpt.number}: ${result.message}',
            );
          }
        }
      }
    }
    if (!foundBreakpoint) {
      debugger.console.print('No breakpoint found at ${loc}');
    }
  }

  Future<List<String>> complete(List<String> args) {
    if (args.length != 1) {
      return new Future.value([args.join('')]);
    }
    return new Future.value(DebuggerLocation.complete(debugger, args[0]));
  }

  String helpShort =
      'Remove a breakpoint by source location or function name'
      ' (hotkey: [F8])';

  String helpLong =
      'Remove a breakpoint by source location or function name.\n'
      '\n'
      'Hotkey: [F8]\n'
      '\n'
      'Syntax: clear                       '
      '# Clear at the current position\n'
      '        clear <line>                '
      '# Clear at a line in the current script\n'
      '                                    '
      '  (e.g \'clear 11\')\n'
      '        clear <line>:<col>          '
      '# Clear at a line:col in the current script\n'
      '                                    '
      '  (e.g \'clear 11:8\')\n'
      '        clear <script>:<line>       '
      '# Clear at a line:col in a specific script\n'
      '                                    '
      '  (e.g \'clear test.dart:11\')\n'
      '        clear <script>:<line>:<col> '
      '# Clear at a line:col in a specific script\n'
      '                                    '
      '  (e.g \'clear test.dart:11:8\')\n'
      '        clear <function>            '
      '# Clear at the named function\n'
      '                                    '
      '  (e.g \'clear main\' or \'clear Class.someFunction\')\n';
}

// TODO(turnidge): Add argument completion.
class DeleteCommand extends DebuggerCommand {
  DeleteCommand(Debugger debugger) : super(debugger, 'delete', <Command>[]);

  Future run(List<String> args) {
    if (args.length < 1) {
      debugger.console.print('delete expects one or more arguments');
      return new Future.value(null);
    }
    List toRemove = [];
    for (var arg in args) {
      int id = int.parse(arg);
      var bptToRemove = null;
      for (var bpt in debugger.isolate.breakpoints.values) {
        if (bpt.number == id) {
          bptToRemove = bpt;
          break;
        }
      }
      if (bptToRemove == null) {
        debugger.console.print("Invalid breakpoint id '${id}'");
        return new Future.value(null);
      }
      toRemove.add(bptToRemove);
    }
    List<Future> pending = [];
    for (var bpt in toRemove) {
      pending.add(debugger.isolate.removeBreakpoint(bpt));
    }
    return Future.wait(pending);
  }

  String helpShort = 'Remove a breakpoint by breakpoint id';

  String helpLong =
      'Remove a breakpoint by breakpoint id.\n'
      '\n'
      'Syntax: delete <bp-id>\n'
      '        delete <bp-id> <bp-id> ...\n';
}

class InfoBreakpointsCommand extends DebuggerCommand {
  InfoBreakpointsCommand(Debugger debugger)
    : super(debugger, 'breakpoints', <Command>[]);

  Future run(List<String> args) async {
    if (debugger.isolate.breakpoints.isEmpty) {
      debugger.console.print('No breakpoints');
    }
    List bpts = debugger.isolate.breakpoints.values.toList();
    bpts.sort((a, b) => a.number - b.number);
    for (var bpt in bpts) {
      var bpId = bpt.number;
      var locString = await bpt.location.toUserString();
      if (!bpt.resolved) {
        debugger.console.print('Future breakpoint ${bpId} at ${locString}');
      } else {
        debugger.console.print('Breakpoint ${bpId} at ${locString}');
      }
    }
  }

  String helpShort = 'List all breakpoints';

  String helpLong =
      'List all breakpoints.\n'
      '\n'
      'Syntax: info breakpoints\n';
}

class InfoFrameCommand extends DebuggerCommand {
  InfoFrameCommand(Debugger debugger) : super(debugger, 'frame', <Command>[]);

  Future run(List<String> args) {
    if (args.length > 0) {
      debugger.console.print('info frame expects no arguments');
      return new Future.value(null);
    }
    debugger.console.print('frame = ${debugger.currentFrame}');
    return new Future.value(null);
  }

  String helpShort = 'Show current frame';

  String helpLong =
      'Show current frame.\n'
      '\n'
      'Syntax: info frame\n';
}

class IsolateCommand extends DebuggerCommand {
  IsolateCommand(Debugger debugger)
    : super(debugger, 'isolate', <Command>[
        new IsolateListCommand(debugger),
        new IsolateNameCommand(debugger),
      ]) {
    alias = 'i';
  }

  Future run(List<String> args) {
    if (args.length != 1) {
      debugger.console.print('isolate expects one argument');
      return new Future.value(null);
    }
    var arg = args[0].trim();
    var num = int.tryParse(arg);

    var candidate;
    for (var isolate in debugger.vm.isolates) {
      if (num != null && num == isolate.number) {
        candidate = isolate;
        break;
      } else if (arg == isolate.name) {
        if (candidate != null) {
          debugger.console.print(
            "Isolate identifier '${arg}' is ambiguous: "
            'use the isolate number instead',
          );
          return new Future.value(null);
        }
        candidate = isolate;
      }
    }
    if (candidate == null) {
      debugger.console.print("Invalid isolate identifier '${arg}'");
    } else {
      if (candidate == debugger.isolate) {
        debugger.console.print(
          "Current isolate is already ${candidate.number} '${candidate.name}'",
        );
      } else {
        HTMLAnchorElement()
          ..href = Uris.debugger(candidate)
          ..click();
      }
    }
    return new Future.value(null);
  }

  Future<List<String>> complete(List<String> args) {
    if (args.length != 1) {
      return new Future.value([args.join('')]);
    }
    var result = <String>[];
    for (var isolate in debugger.vm.isolates) {
      var str = isolate.number.toString();
      if (str.startsWith(args[0])) {
        result.add('$str ');
      }
    }
    for (var isolate in debugger.vm.isolates) {
      if (isolate.name!.startsWith(args[0])) {
        result.add('${isolate.name} ');
      }
    }
    return new Future.value(result);
  }

  String helpShort = 'Switch, list, rename, or reload isolates';

  String helpLong =
      'Switch the current isolate.\n'
      '\n'
      'Syntax: isolate <number>\n'
      '        isolate <name>\n';
}

String _isolateRunState(S.Isolate isolate) {
  if (isolate.paused) {
    return 'paused';
  } else if (isolate.running) {
    return 'running';
  } else if (isolate.idle) {
    return 'idle';
  } else {
    return 'unknown';
  }
}

class IsolateListCommand extends DebuggerCommand {
  IsolateListCommand(Debugger debugger) : super(debugger, 'list', <Command>[]);

  Future run(List<String> args) async {
    // Refresh all isolates first.
    var pending = <Future>[];
    for (var isolate in debugger.vm.isolates) {
      pending.add(isolate.reload());
    }
    await Future.wait(pending);

    const maxIdLen = 10;
    const maxRunStateLen = 7;
    var maxNameLen = 'NAME'.length;
    for (var isolate in debugger.vm.isolates) {
      maxNameLen = max(maxNameLen, isolate.name!.length);
    }
    debugger.console.print(
      "${'ID'.padLeft(maxIdLen, ' ')} "
      "${'ORIGIN'.padLeft(maxIdLen, ' ')} "
      "${'NAME'.padRight(maxNameLen, ' ')} "
      "${'STATE'.padRight(maxRunStateLen, ' ')} "
      "CURRENT",
    );
    for (var isolate in debugger.vm.isolates) {
      String current = (isolate == debugger.isolate ? '*' : '');
      debugger.console.print(
        "${isolate.number.toString().padLeft(maxIdLen, ' ')} "
        "${isolate.name!.padRight(maxNameLen, ' ')} "
        "${_isolateRunState(isolate).padRight(maxRunStateLen, ' ')} "
        "${current}",
      );
    }
    debugger.console.newline();
  }

  String helpShort = 'List all isolates';

  String helpLong =
      'List all isolates.\n'
      '\n'
      'Syntax: isolate list\n';
}

class IsolateNameCommand extends DebuggerCommand {
  IsolateNameCommand(Debugger debugger) : super(debugger, 'name', <Command>[]);

  Future run(List<String> args) {
    if (args.length != 1) {
      debugger.console.print('isolate name expects one argument');
      return new Future.value(null);
    }
    return debugger.isolate.setName(args[0]);
  }

  String helpShort = 'Rename the current isolate';

  String helpLong =
      'Rename the current isolate.\n'
      '\n'
      'Syntax: isolate name <name>\n';
}

class InfoCommand extends DebuggerCommand {
  InfoCommand(Debugger debugger)
    : super(debugger, 'info', <Command>[
        new InfoBreakpointsCommand(debugger),
        new InfoFrameCommand(debugger),
      ]);

  Future run(List<String> args) {
    debugger.console.print("'info' expects a subcommand (see 'help info')");
    return new Future.value(null);
  }

  String helpShort = 'Show information on a variety of topics';

  String helpLong =
      'Show information on a variety of topics.\n'
      '\n'
      'Syntax: info <subcommand>\n';
}

class RefreshStackCommand extends DebuggerCommand {
  RefreshStackCommand(Debugger debugger)
    : super(debugger, 'stack', <Command>[]);

  Future run(List<String> args) {
    return debugger.refreshStack();
  }

  String helpShort = 'Refresh isolate stack';

  String helpLong =
      'Refresh isolate stack.\n'
      '\n'
      'Syntax: refresh stack\n';
}

class RefreshCommand extends DebuggerCommand {
  RefreshCommand(Debugger debugger)
    : super(debugger, 'refresh', <Command>[new RefreshStackCommand(debugger)]);

  Future run(List<String> args) {
    debugger.console.print(
      "'refresh' expects a subcommand (see 'help refresh')",
    );
    return new Future.value(null);
  }

  String helpShort = 'Refresh debugging information of various sorts';

  String helpLong =
      'Refresh debugging information of various sorts.\n'
      '\n'
      'Syntax: refresh <subcommand>\n';
}

class VmListCommand extends DebuggerCommand {
  VmListCommand(Debugger debugger) : super(debugger, 'list', <Command>[]);

  Future run(List<String> args) async {
    if (args.length > 0) {
      debugger.console.print('vm list expects no arguments');
      return;
    }
    // TODO(turnidge): Right now there is only one vm listed.
    var vmList = [debugger.vm];

    var maxAddrLen = 'ADDRESS'.length;
    var maxNameLen = 'NAME'.length;

    for (var vm in vmList) {
      maxAddrLen = max(maxAddrLen, vm.target.networkAddress.length);
      maxNameLen = max(maxNameLen, vm.name!.length);
    }

    debugger.console.print(
      "${'ADDRESS'.padRight(maxAddrLen, ' ')} "
      "${'NAME'.padRight(maxNameLen, ' ')} "
      "CURRENT",
    );
    for (var vm in vmList) {
      String current = (vm == debugger.vm ? '*' : '');
      debugger.console.print(
        "${vm.target.networkAddress.padRight(maxAddrLen, ' ')} "
        "${vm.name!.padRight(maxNameLen, ' ')} "
        "${current}",
      );
    }
  }

  String helpShort = 'List all connected Dart virtual machines';

  String helpLong =
      'List all connected Dart virtual machines..\n'
      '\n'
      'Syntax: vm list\n';
}

class VmNameCommand extends DebuggerCommand {
  VmNameCommand(Debugger debugger) : super(debugger, 'name', <Command>[]);

  Future run(List<String> args) async {
    if (args.length != 1) {
      debugger.console.print('vm name expects one argument');
      return;
    }
    await debugger.vm.setName(args[0]);
  }

  String helpShort = 'Rename the current Dart virtual machine';

  String helpLong =
      'Rename the current Dart virtual machine.\n'
      '\n'
      'Syntax: vm name <name>\n';
}

class VmCommand extends DebuggerCommand {
  VmCommand(Debugger debugger)
    : super(debugger, 'vm', <Command>[
        new VmListCommand(debugger),
        new VmNameCommand(debugger),
      ]);

  Future run(List<String> args) async {
    debugger.console.print("'vm' expects a subcommand (see 'help vm')");
  }

  String helpShort = 'Manage a Dart virtual machine';

  String helpLong =
      'Manage a Dart virtual machine.\n'
      '\n'
      'Syntax: vm <subcommand>\n';
}

class _ConsoleStreamPrinter {
  ObservatoryDebugger _debugger;

  _ConsoleStreamPrinter(this._debugger);
  Level _minimumLogLevel = Level.OFF;
  String? _savedStream;
  String? _savedIsolate;
  String? _savedLine;
  List<String> _buffer = [];

  void onEvent(String streamName, S.ServiceEvent event) {
    if (event.kind == S.ServiceEvent.kLogging) {
      // Check if we should print this log message.
      if (event.logRecord!['level'].value < _minimumLogLevel.value) {
        return;
      }
    }
    String isolateName = event.isolate!.name!;
    // If we get a line from a different isolate/stream, flush
    // any pending output, even if it is not newline-terminated.
    if ((_savedIsolate != null && isolateName != _savedIsolate) ||
        (_savedStream != null && streamName != _savedStream)) {
      flush();
    }
    String data;
    bool hasNewline;
    if (event.kind == S.ServiceEvent.kLogging) {
      data = event.logRecord!["message"].valueAsString;
      hasNewline = true;
    } else {
      data = event.bytesAsString!;
      hasNewline = data.endsWith('\n');
    }
    if (_savedLine != null) {
      data = _savedLine! + data;
      _savedIsolate = null;
      _savedStream = null;
      _savedLine = null;
    }
    var lines = data.split('\n').where((line) => line != '').toList();
    if (lines.isEmpty) {
      return;
    }
    int limit = (hasNewline ? lines.length : lines.length - 1);
    for (int i = 0; i < limit; i++) {
      _buffer.add(_format(isolateName, streamName, lines[i]));
    }
    // If there is no newline, we save the last line of output for next time.
    if (!hasNewline) {
      _savedIsolate = isolateName;
      _savedStream = streamName;
      _savedLine = lines[lines.length - 1];
    }
  }

  void flush() {
    // If there is any saved output, flush it now.
    if (_savedLine != null) {
      _buffer.add(_format(_savedIsolate!, _savedStream!, _savedLine!));
      _savedIsolate = null;
      _savedStream = null;
      _savedLine = null;
    }
    if (_buffer.isNotEmpty) {
      _debugger.console.printStdio(_buffer);
      _buffer.clear();
    }
  }

  String _format(String isolateName, String streamName, String line) {
    return '${isolateName}:${streamName}> ${line}';
  }
}

// Tracks the state for an isolate debugging session.
class ObservatoryDebugger extends Debugger {
  final SettingsGroup settings = new SettingsGroup('debugger');
  late RootCommand cmd;
  late DebuggerPageElement page;
  late DebuggerConsoleElement console;
  late DebuggerInputElement input;
  late DebuggerStackElement stackElement;
  S.ServiceMap? stack;
  final S.Isolate isolate;
  String breakOnException = "none"; // Last known setting.

  int? get currentFrame => _currentFrame;

  void set currentFrame(int? value) {
    if (value != null && (value < 0 || value >= stackDepth)) {
      throw new RangeError.range(value, 0, stackDepth);
    }
    _currentFrame = value;
    stackElement.setCurrentFrame(value);
  }

  int? _currentFrame = null;

  bool get upIsDown => _upIsDown;
  void set upIsDown(bool value) {
    settings.set('up-is-down', value);
    _upIsDown = value;
  }

  bool _upIsDown = false;

  bool get causalAsyncStacks => _causalAsyncStacks;
  void set causalAsyncStacks(bool value) {
    settings.set('causal-async-stacks', value);
    _causalAsyncStacks = value;
  }

  bool _causalAsyncStacks = true;

  static const String kAsyncCausalStackFrames = 'asyncCausalFrames';
  static const String kStackFrames = 'frames';

  void upFrame(int count) {
    if (_upIsDown) {
      currentFrame = currentFrame! + count;
    } else {
      currentFrame = currentFrame! - count;
    }
  }

  void downFrame(int count) {
    if (_upIsDown) {
      currentFrame = currentFrame! - count;
    } else {
      currentFrame = currentFrame! + count;
    }
  }

  int get stackDepth {
    if (causalAsyncStacks) {
      var asyncCausalStackFrames = stack![kAsyncCausalStackFrames];
      if (asyncCausalStackFrames != null) {
        return asyncCausalStackFrames.length;
      }
    }
    return stack![kStackFrames].length;
  }

  List get stackFrames {
    if (causalAsyncStacks) {
      var asyncCausalStackFrames = stack![kAsyncCausalStackFrames];
      if (asyncCausalStackFrames != null) {
        return asyncCausalStackFrames;
      }
    }
    return stack![kStackFrames] ?? [];
  }

  static final _history = [''];

  ObservatoryDebugger(this.isolate) {
    _loadSettings();
    cmd = new RootCommand([
      new AsyncNextCommand(this),
      new BreakCommand(this),
      new ClearCommand(this),
      new ClsCommand(this),
      new ContinueCommand(this),
      new DeleteCommand(this),
      new DownCommand(this),
      new FinishCommand(this),
      new FrameCommand(this),
      new HelpCommand(this),
      new InfoCommand(this),
      new IsolateCommand(this),
      new LogCommand(this),
      new PauseCommand(this),
      new PrintCommand(this),
      new ReloadCommand(this, new R.IsolateRepository(this.isolate.vm)),
      new RefreshCommand(this),
      new RewindCommand(this),
      new SetCommand(this),
      new SmartNextCommand(this),
      new StepCommand(this),
      new SyncNextCommand(this),
      new UpCommand(this),
      new VmCommand(this),
    ], _history);
    _consolePrinter = new _ConsoleStreamPrinter(this);
  }

  void _loadSettings() {
    _upIsDown = settings.get('up-is-down') ?? false;
    _causalAsyncStacks = settings.get('causal-async-stacks') ?? true;
  }

  S.VM get vm => page.app.vm;

  void init() {
    console.printBold(
      'Debugging isolate ${isolate.number} '
      '\'${isolate.name}\' ',
    );
    console.printBold('Type \'h\' for help');

    if ((breakOnException != isolate.exceptionsPauseInfo) &&
        (isolate.exceptionsPauseInfo != null)) {
      breakOnException = isolate.exceptionsPauseInfo!;
    }

    isolate.reload().then((serviceObject) {
      S.Isolate response = serviceObject as S.Isolate;
      if (response.isSentinel) {
        // The isolate has gone away.  The IsolateExit event will
        // clear the isolate for the debugger page.
        return;
      }
      // TODO(turnidge): Currently the debugger relies on all libs
      // being loaded.  Fix this.
      var pending = <Future>[];
      for (var lib in response.libraries) {
        if (!lib.loaded) {
          pending.add(lib.load());
        }
      }
      Future.wait(pending)
          .then((_) {
            refreshStack();
          })
          .catchError((e) {
            print("UNEXPECTED ERROR $e");
            reportStatus();
          });
    });
  }

  Future refreshStack() async {
    try {
      await _refreshStack(isolate.pauseEvent);
      flushStdio();
      reportStatus();
    } catch (e, st) {
      console.printRed("Unexpected error in refreshStack: $e\n$st");
    }
  }

  bool isolatePaused() {
    // TODO(turnidge): Stop relying on the isolate to track the last
    // pause event.  Since we listen to events directly in the
    // debugger, this could introduce a race.
    return isolate.status == M.IsolateStatus.paused;
  }

  void warnOutOfDate() {
    // Wait a bit, then tell the user that the stack may be out of date.
    new Timer(const Duration(seconds: 2), () {
      if (!isolatePaused()) {
        stackElement.isSampled = true;
      }
    });
  }

  Future<S.ServiceMap?> _refreshStack(M.DebugEvent? pauseEvent) {
    return isolate.getStack().then((result) {
      if (result.isSentinel) {
        // The isolate has gone away.  The IsolateExit event will
        // clear the isolate for the debugger page.
        return null;
      }
      stack = result;
      stackElement.updateStack(stack!, pauseEvent);
      if (stack!['frames'].length > 0) {
        currentFrame = 0;
      } else {
        currentFrame = null;
      }
      input.focus();
      return null;
    });
  }

  void reportStatus() {
    flushStdio();
    if (isolate.idle) {
      console.print('Isolate is idle');
    } else if (isolate.running) {
      console.print("Isolate is running (type 'pause' to interrupt)");
    } else if (isolate.pauseEvent != null) {
      _reportPause(isolate.pauseEvent!);
    } else {
      console.print('Isolate is in unknown state');
    }
    warnOutOfDate();
  }

  void _reportIsolateError(S.Isolate? isolate, M.DebugEvent event) {
    if (isolate == null) {
      return;
    }
    S.DartError? error = isolate.error;
    if (error == null) {
      return;
    }
    console.newline();
    if (event is M.PauseExceptionEvent) {
      console.printBold('Isolate will exit due to an unhandled exception:');
    } else {
      console.printBold('Isolate has exited due to an unhandled exception:');
    }
    console.print(error.message!);
    console.newline();
    if (event is M.PauseExceptionEvent &&
        (error.exception!.isStackOverflowError ||
            error.exception!.isOutOfMemoryError)) {
      console.printBold(
        'When an unhandled stack overflow or OOM exception occurs, the VM '
        'has run out of memory and cannot keep the stack alive while '
        'paused.',
      );
    } else {
      console.printBold(
        "Type 'set break-on-exception Unhandled' to pause the"
        " isolate when an unhandled exception occurs.",
      );
      console.printBold(
        "You can make this the default by running with "
        "--pause-isolates-on-unhandled-exceptions",
      );
    }
  }

  void _reportPause(M.DebugEvent event) {
    if (event is M.NoneEvent) {
      console.print("Paused until embedder makes the isolate runnable.");
    } else if (event is M.PauseStartEvent) {
      console.print(
        "Paused at isolate start "
        "(type 'continue' [F7] or 'step' [F10] to start the isolate')",
      );
    } else if (event is M.PauseExitEvent) {
      console.print(
        "Paused at isolate exit "
        "(type 'continue' or [F7] to exit the isolate')",
      );
      _reportIsolateError(isolate, event);
    } else if (event is M.PauseExceptionEvent) {
      console.print(
        "Paused at an unhandled exception "
        "(type 'continue' or [F7] to exit the isolate')",
      );
      _reportIsolateError(isolate, event);
    } else if (stack!['frames'].length > 0) {
      S.Frame frame = stack!['frames'][0];
      var script = frame.location!.script;
      script.load().then((_) {
        var line = script.tokenToLine(frame.location!.tokenPos);
        var col = script.tokenToCol(frame.location!.tokenPos);
        if ((event is M.PauseBreakpointEvent) && (event.breakpoint != null)) {
          var bpId = event.breakpoint!.number;
          console.print(
            'Paused at breakpoint ${bpId} at '
            '${script.name}:${line}:${col}',
          );
        } else if (event is M.PauseExceptionEvent) {
          console.print(
            'Paused due to exception at '
            '${script.name}:${line}:${col}',
          );
          // This seems to be missing if we are paused-at-exception after
          // paused-at-isolate-exit. Maybe we shutdown part of the debugger too
          // soon?
          console.printRef(isolate, event.exception as S.Instance, objects!);
        } else {
          console.print('Paused at ${script.name}:${line}:${col}');
        }
      });
    } else {
      console.print(
        "Paused in message loop (type 'continue' or [F7] "
        "to resume processing messages)",
      );
    }
  }

  Future _reportBreakpointEvent(S.ServiceEvent event) async {
    var verb = null;
    switch (event.kind) {
      case S.ServiceEvent.kBreakpointAdded:
        verb = 'added';
        break;
      case S.ServiceEvent.kBreakpointResolved:
        verb = 'resolved';
        break;
      case S.ServiceEvent.kBreakpointRemoved:
        verb = 'removed';
        break;
      default:
        break;
    }
    var bpt = event.breakpoint!;
    var location = bpt.location!;
    var script = location.script!;
    await script.load();

    var bpId = bpt.number;
    var locString = await location.toUserString();
    if (bpt.resolved!) {
      console.print('Breakpoint ${bpId} ${verb} at ${locString}');
    } else {
      console.print('Future breakpoint ${bpId} ${verb} at ${locString}');
    }
  }

  void onEvent(S.ServiceEvent event) {
    switch (event.kind) {
      case S.ServiceEvent.kVMUpdate:
        S.VM vm = event.owner as S.VM;
        console.print("VM ${vm.displayName} renamed to '${vm.name}'");
        break;

      case S.ServiceEvent.kIsolateStart:
        {
          S.Isolate iso = event.owner as S.Isolate;
          console.print("Isolate ${iso.number} '${iso.name}' has been created");
        }
        break;

      case S.ServiceEvent.kIsolateExit:
        {
          S.Isolate iso = event.owner as S.Isolate;
          if (iso == isolate) {
            console.print(
              "The current isolate ${iso.number} '${iso.name}' "
              "has exited",
            );
            var isolates = vm.isolates;
            if (isolates.length > 0) {
              var newIsolate = isolates.first;
              HTMLAnchorElement()
                ..href = Uris.debugger(newIsolate)
                ..click();
            } else {
              HTMLAnchorElement()
                ..href = Uris.vm()
                ..click();
            }
          } else {
            console.print("Isolate ${iso.number} '${iso.name}' has exited");
          }
        }
        break;

      case S.ServiceEvent.kDebuggerSettingsUpdate:
        if (breakOnException != event.exceptions) {
          breakOnException = event.exceptions!;
          console.print("Now pausing for exceptions: $breakOnException");
        }
        break;

      case S.ServiceEvent.kIsolateUpdate:
        S.Isolate iso = event.owner as S.Isolate;
        console.print("Isolate ${iso.number} renamed to '${iso.name}'");
        break;

      case S.ServiceEvent.kIsolateReload:
        var reloadError = event.reloadError;
        if (reloadError != null) {
          console.print('Isolate reload failed: ${event.reloadError}');
        } else {
          console.print('Isolate reloaded.');
        }
        break;

      case S.ServiceEvent.kPauseStart:
      case S.ServiceEvent.kPauseExit:
      case S.ServiceEvent.kPauseBreakpoint:
      case S.ServiceEvent.kPauseInterrupted:
      case S.ServiceEvent.kPauseException:
        if (event.owner == isolate) {
          var e = createEventFromServiceEvent(event) as M.DebugEvent;
          _refreshStack(e).then((_) async {
            flushStdio();
            await isolate.reload();
            _reportPause(e);
          });
        }
        break;

      case S.ServiceEvent.kResume:
        if (event.owner == isolate) {
          flushStdio();
          console.print('Continuing...');
        }
        break;

      case S.ServiceEvent.kBreakpointAdded:
      case S.ServiceEvent.kBreakpointResolved:
      case S.ServiceEvent.kBreakpointRemoved:
        if (event.owner == isolate) {
          _reportBreakpointEvent(event);
        }
        break;

      case S.ServiceEvent.kIsolateRunnable:
      case S.ServiceEvent.kHeapSnapshot:
      case S.ServiceEvent.kGC:
      case S.ServiceEvent.kInspect:
        // Ignore.
        break;

      case S.ServiceEvent.kLogging:
        _consolePrinter.onEvent(event.logRecord!['level'].name, event);
        break;

      default:
        console.print('Unrecognized event: $event');
        break;
    }
  }

  late _ConsoleStreamPrinter _consolePrinter;

  void flushStdio() {
    _consolePrinter.flush();
  }

  void onStdout(S.ServiceEvent event) {
    _consolePrinter.onEvent('stdout', event);
  }

  void onStderr(S.ServiceEvent event) {
    _consolePrinter.onEvent('stderr', event);
  }

  static String _commonPrefix(String a, String b) {
    int pos = 0;
    while (pos < a.length && pos < b.length) {
      if (a.codeUnitAt(pos) != b.codeUnitAt(pos)) {
        break;
      }
      pos++;
    }
    return a.substring(0, pos);
  }

  static String _foldCompletions(List<String> values) {
    if (values.length == 0) {
      return '';
    }
    var prefix = values[0];
    for (int i = 1; i < values.length; i++) {
      prefix = _commonPrefix(prefix, values[i]);
    }
    return prefix;
  }

  Future<String> complete(String line) {
    return cmd.completeCommand(line).then((completions) {
      if (completions.length == 0) {
        // No completions.  Leave the line alone.
        return line;
      } else if (completions.length == 1) {
        // Unambiguous completion.
        return completions[0];
      } else {
        // Ambiguous completion.
        completions = completions.map((s) => s.trimRight()).toList();
        console.printBold(completions.toString());
        return _foldCompletions(completions);
      }
    });
  }

  // TODO(turnidge): Implement real command line history.
  String? lastCommand;

  Future run(String command) {
    if (command == '' && lastCommand != null) {
      command = lastCommand!;
    }
    console.printBold('\$ $command');
    return cmd
        .runCommand(command)
        .then((_) {
          lastCommand = command;
        })
        .catchError((e, s) {
          console.printRed(
            'Unable to execute command because the connection '
            'to the VM has been closed',
          );
        }, test: (e) => e is S.NetworkRpcException)
        .catchError((e, s) {
          console.printRed(e.toString());
        }, test: (e) => e is CommandException)
        .catchError((e, s) {
          if (s != null) {
            console.printRed('Internal error: $e\n$s');
          } else {
            console.printRed('Internal error: $e\n');
          }
        });
  }

  String historyPrev(String command) {
    return cmd.historyPrev(command);
  }

  String historyNext(String command) {
    return cmd.historyNext(command);
  }

  Future pause() {
    if (!isolatePaused()) {
      return isolate.pause();
    } else {
      console.print('The program is already paused');
      return new Future.value(null);
    }
  }

  Future resume() {
    if (isolatePaused()) {
      return isolate.resume().then((_) {
        warnOutOfDate();
      });
    } else {
      console.print('The program must be paused');
      return new Future.value(null);
    }
  }

  Future toggleBreakpoint() async {
    var loc = await DebuggerLocation.parse(this, '');
    var script = loc.script;
    var line = loc.line;
    if (script != null && line != null) {
      var bpts = script.getLine(line)!.breakpoints;
      if (bpts == null || bpts.isEmpty) {
        // Set a new breakpoint.
        // TODO(turnidge): Set this breakpoint at current column.
        await isolate.addBreakpoint(script, line);
      } else {
        // TODO(turnidge): Clear this breakpoint at current column.
        var pending = <Future>[];
        for (var bpt in bpts) {
          pending.add(isolate.removeBreakpoint(bpt));
        }
        await Future.wait(pending);
      }
    }
    return new Future.value(null);
  }

  Future smartNext() async {
    if (isolatePaused()) {
      M.AsyncSuspensionEvent event =
          isolate.pauseEvent as M.AsyncSuspensionEvent;
      if (event.atAsyncSuspension) {
        return asyncNext();
      } else {
        return syncNext();
      }
    } else {
      console.print('The program is already running');
    }
  }

  Future asyncNext() async {
    if (isolatePaused()) {
      M.AsyncSuspensionEvent event =
          isolate.pauseEvent as M.AsyncSuspensionEvent;
      if (!event.atAsyncSuspension) {
        console.print("No async continuation at this location");
      } else {
        return isolate.stepOverAsyncSuspension();
      }
    } else {
      console.print('The program is already running');
    }
  }

  Future syncNext() async {
    if (isolatePaused()) {
      var event = isolate.pauseEvent;
      if (event is M.PauseStartEvent) {
        console.print(
          "Type 'continue' [F7] or 'step' [F10] to start the isolate",
        );
        return null;
      }
      if (event is M.PauseExitEvent) {
        console.print("Type 'continue' [F7] to exit the isolate");
        return null;
      }
      return isolate.stepOver();
    } else {
      console.print('The program is already running');
      return null;
    }
  }

  Future step() {
    if (isolatePaused()) {
      var event = isolate.pauseEvent;
      if (event is M.PauseExitEvent) {
        console.print("Type 'continue' [F7] to exit the isolate");
        return new Future.value(null);
      }
      return isolate.stepInto();
    } else {
      console.print('The program is already running');
      return new Future.value(null);
    }
  }

  Future rewind(int count) {
    if (isolatePaused()) {
      var event = isolate.pauseEvent;
      if (event is M.PauseExitEvent) {
        console.print("Type 'continue' [F7] to exit the isolate");
        return new Future.value(null);
      }
      return isolate.rewind(count);
    } else {
      console.print('The program must be paused');
      return new Future.value(null);
    }
  }
}

class DebuggerPageElement extends CustomElement implements Renderable {
  late S.Isolate _isolate;
  late ObservatoryDebugger _debugger;
  late M.ObjectRepository _objects;
  late M.ScriptRepository _scripts;
  late M.EventRepository _events;

  factory DebuggerPageElement(
    S.Isolate isolate,
    M.ObjectRepository objects,
    M.ScriptRepository scripts,
    M.EventRepository events,
  ) {
    final DebuggerPageElement e = new DebuggerPageElement.created();
    final debugger = new ObservatoryDebugger(isolate);
    debugger.page = e;
    debugger.objects = objects;
    e._isolate = isolate;
    e._debugger = debugger;
    e._objects = objects;
    e._scripts = scripts;
    e._events = events;
    return e;
  }

  DebuggerPageElement.created() : super.created('debugger-page');

  Future<StreamSubscription>? _vmSubscriptionFuture;
  Future<StreamSubscription>? _isolateSubscriptionFuture;
  Future<StreamSubscription>? _debugSubscriptionFuture;
  Future<StreamSubscription>? _stdoutSubscriptionFuture;
  Future<StreamSubscription>? _stderrSubscriptionFuture;
  Future<StreamSubscription>? _logSubscriptionFuture;

  ObservatoryApplication get app => ObservatoryApplication.app;

  Timer? _timer;

  static final consoleElement = new DebuggerConsoleElement();

  @override
  void attached() {
    super.attached();

    final stackDiv = new HTMLDivElement()..className = 'stack';
    final stackElement = new DebuggerStackElement(
      _isolate,
      _debugger,
      stackDiv,
      _objects,
      _scripts,
      _events,
    );
    stackDiv.appendChildren(<HTMLElement>[stackElement.element]);

    final consoleDiv = new HTMLDivElement()
      ..className = 'console'
      ..appendChildren(<HTMLElement>[consoleElement.element]);

    final commandElement = new DebuggerInputElement(_isolate, _debugger);
    final commandDiv = new HTMLDivElement()
      ..className = 'commandline'
      ..appendChildren(<HTMLElement>[commandElement.element]);

    setChildren(<HTMLElement>[
      navBar(<HTMLElement>[
        new NavTopMenuElement(queue: app.queue).element,
        new NavVMMenuElement(app.vm, app.events, queue: app.queue).element,
        new NavIsolateMenuElement(
          _isolate,
          app.events,
          queue: app.queue,
        ).element,
        navMenu('debugger'),
        new NavNotifyElement(
          app.notifications,
          notifyOnPause: false,
          queue: app.queue,
        ).element,
      ]),
      new HTMLDivElement()
        ..className = 'variable'
        ..appendChildren(<HTMLElement>[
          stackDiv,
          new HTMLDivElement()..appendChildren(<HTMLElement>[
            new HTMLHRElement()..className = 'splitter',
          ]),
          consoleDiv,
        ]),
      commandDiv,
    ]);

    DebuggerConsoleElement._scrollToBottom(consoleDiv);

    // Wire the debugger object to the stack, console, and command line.
    _debugger.stackElement = stackElement;
    _debugger.console = consoleElement;
    _debugger.input = commandElement;
    _debugger.input._debugger = _debugger;
    _debugger.init();

    _vmSubscriptionFuture = app.vm.listenEventStream(
      S.VM.kVMStream,
      _debugger.onEvent,
    );
    _isolateSubscriptionFuture = app.vm.listenEventStream(
      S.VM.kIsolateStream,
      _debugger.onEvent,
    );
    _debugSubscriptionFuture = app.vm.listenEventStream(
      S.VM.kDebugStream,
      _debugger.onEvent,
    );
    _stdoutSubscriptionFuture = app.vm.listenEventStream(
      S.VM.kStdoutStream,
      _debugger.onStdout,
    );
    if (_stdoutSubscriptionFuture != null) {
      // TODO(turnidge): How do we want to handle this in general?
      _stdoutSubscriptionFuture!.then(
        (_) {},
        onError: (e, st) {
          Logger.root.info('Failed to subscribe to stdout: $e\n$st\n');
          _stdoutSubscriptionFuture = null;
        },
      );
    }
    _stderrSubscriptionFuture = app.vm.listenEventStream(
      S.VM.kStderrStream,
      _debugger.onStderr,
    );
    if (_stderrSubscriptionFuture != null) {
      // TODO(turnidge): How do we want to handle this in general?
      _stderrSubscriptionFuture!.then(
        (_) {},
        onError: (e, st) {
          Logger.root.info('Failed to subscribe to stderr: $e\n$st\n');
          _stderrSubscriptionFuture = null;
        },
      );
    }
    _logSubscriptionFuture = app.vm.listenEventStream(
      S.Isolate.kLoggingStream,
      _debugger.onEvent,
    );
    // Turn on the periodic poll timer for this page.
    _timer = new Timer.periodic(const Duration(milliseconds: 100), (_) {
      _debugger.flushStdio();
    });

    onClick.listen((event) {
      // Random clicks should focus on the text box.  If the user selects
      // a range, don't interfere.
      var selection = window.getSelection();
      if (selection == null ||
          (selection.type != 'Range' && selection.type != 'text')) {
        _debugger.input.focus();
      }
    });
  }

  @override
  void render() {
    /* nothing to do */
  }

  @override
  void detached() {
    _timer!.cancel();
    removeChildren();
    S.cancelFutureSubscription(_vmSubscriptionFuture!);
    _vmSubscriptionFuture = null;
    S.cancelFutureSubscription(_isolateSubscriptionFuture!);
    _isolateSubscriptionFuture = null;
    S.cancelFutureSubscription(_debugSubscriptionFuture!);
    _debugSubscriptionFuture = null;
    S.cancelFutureSubscription(_stdoutSubscriptionFuture!);
    _stdoutSubscriptionFuture = null;
    S.cancelFutureSubscription(_stderrSubscriptionFuture!);
    _stderrSubscriptionFuture = null;
    S.cancelFutureSubscription(_logSubscriptionFuture!);
    _logSubscriptionFuture = null;
    super.detached();
  }
}

class DebuggerStackElement extends CustomElement implements Renderable {
  late S.Isolate _isolate;
  late M.ObjectRepository _objects;
  late M.ScriptRepository _scripts;
  late M.EventRepository _events;
  late HTMLElement _scroller;
  late HTMLDivElement _isSampled;
  bool get isSampled => !_isSampled.className.contains('hidden');
  set isSampled(bool value) {
    if (value != isSampled) {
      toggleClass(_isSampled, ' hidden');
    }
  }

  late HTMLDivElement _hasStack;
  bool get hasStack => _hasStack.className.contains('hidden');
  set hasStack(bool value) {
    if (value != hasStack) {
      toggleClass(_hasStack, ' hidden');
    }
  }

  late HTMLDivElement _hasMessages;
  bool get hasMessages => _hasMessages.className.contains('hidden');
  set hasMessages(bool value) {
    if (value != hasMessages) {
      toggleClass(_hasMessages, ' hidden');
    }
  }

  HTMLUListElement? _frameList;
  HTMLUListElement? _messageList;
  int? currentFrame;
  late ObservatoryDebugger _debugger;

  factory DebuggerStackElement(
    S.Isolate isolate,
    ObservatoryDebugger debugger,
    HTMLElement scroller,
    M.ObjectRepository objects,
    M.ScriptRepository scripts,
    M.EventRepository events,
  ) {
    final DebuggerStackElement e = new DebuggerStackElement.created();
    e._isolate = isolate;
    e._debugger = debugger;
    e._scroller = scroller;
    e._objects = objects;
    e._scripts = scripts;
    e._events = events;

    var btnPause;
    var btnRefresh;
    e.appendChildren(<HTMLElement>[
      e._isSampled = new HTMLDivElement()
        ..className = 'sampledMessage hidden'
        ..appendChildren(<HTMLElement>[
          new HTMLSpanElement()
            ..textContent =
                'The program is not paused. '
                'The stack trace below may be out of date.',
          new HTMLBRElement(),
          new HTMLBRElement(),
          btnPause = new HTMLButtonElement()
            ..textContent = '[Pause Isolate]'
            ..onClick.listen((_) async {
              btnPause.disabled = true;
              try {
                await debugger.isolate.pause();
              } finally {
                btnPause.disabled = false;
              }
            }),
          btnRefresh = new HTMLButtonElement()
            ..textContent = '[Refresh Stack]'
            ..onClick.listen((_) async {
              btnRefresh.disabled = true;
              try {
                await debugger.refreshStack();
              } finally {
                btnRefresh.disabled = false;
              }
            }),
          new HTMLBRElement(),
          new HTMLBRElement(),
          new HTMLHRElement()..className = 'splitter',
        ]),
      e._hasStack = new HTMLDivElement()
        ..className = 'noStack hidden'
        ..textContent = 'No stack',
      e._frameList = new HTMLUListElement()..className = 'list-group',
      new HTMLHRElement(),
      e._hasMessages = new HTMLDivElement()
        ..className = 'noMessages hidden'
        ..textContent = 'No pending messages',
      e._messageList = new HTMLUListElement()..className = 'messageList',
    ]);
    return e;
  }

  void render() {
    /* nothing to do */
  }

  _addFrame(S.Frame frameInfo) {
    final li = HTMLLIElement()
      ..className = 'list-group-item'
      ..appendChild(
        (DebuggerFrameElement(
          _isolate,
          frameInfo,
          _scroller,
          _objects,
          _scripts,
          _events,
          queue: app.queue,
        )..setCurrent(frameInfo.index == currentFrame)).element,
      );
    _frameList!.appendChild(li);
  }

  _addMessage(S.ServiceMessage messageInfo) {
    final messageElement = new DebuggerMessageElement(
      _isolate,
      messageInfo,
      _objects,
      _scripts,
      _events,
      queue: app.queue,
    );

    _messageList!.appendChild(
      new HTMLLIElement()
        ..className = 'list-group-item'
        ..appendChild(messageElement.element),
    );
  }

  ObservatoryApplication get app => ObservatoryApplication.app;

  void updateStackFrames(S.ServiceMap newStack) {
    final HTMLCollection frameElements = _frameList!.children;
    final List newFrames =
        (_debugger.causalAsyncStacks &&
            (newStack[ObservatoryDebugger.kAsyncCausalStackFrames] != null))
        ? newStack[ObservatoryDebugger.kAsyncCausalStackFrames]
        : newStack[ObservatoryDebugger.kStackFrames];

    // Remove any frames whose functions don't match, starting from
    // bottom of stack.
    int oldPos = frameElements.length - 1;
    int newPos = newFrames.length - 1;
    while (oldPos >= 0 && newPos >= 0) {
      DebuggerFrameElement dbgFrameElement =
          CustomElement.reverse(
                (frameElements.item(oldPos) as HTMLElement).firstElementChild
                    as HTMLElement,
              )
              as DebuggerFrameElement;
      if (!dbgFrameElement.matchFrame(newFrames[newPos])) {
        // The rest of the frame elements no longer match.  Remove them.
        for (int i = 0; i <= oldPos; i++) {
          // NOTE(turnidge): removeRange is missing, sadly.
          _frameList!.removeChild(_frameList!.firstChild!);
        }
        break;
      }
      oldPos--;
      newPos--;
    }

    // Remove any extra frames.
    if (frameElements.length > newFrames.length) {
      // Remove old frames from the top of stack.
      final removeCount = frameElements.length - newFrames.length;
      for (int i = 0; i < removeCount; i++) {
        _frameList!.removeChild(_frameList!.firstChild!);
      }
    }

    // Add any new frames.
    int newCount = 0;
    if (frameElements.length < newFrames.length) {
      // Add new frames to the top of stack.
      newCount = newFrames.length - _frameList!.children.length;
      for (int i = 0; i < newCount; i++) {
        _addFrame(newFrames[i]);
      }
    }
    assert(_frameList!.children.length == newFrames.length);

    if (_frameList!.children.length > 0) {
      for (int i = newCount; i < _frameList!.children.length; i++) {
        DebuggerFrameElement dbgFrameElement =
            CustomElement.reverse(
                  _frameList!.children.item(i)!.firstChild as HTMLElement,
                )
                as DebuggerFrameElement;
        dbgFrameElement.updateFrame(newFrames[i]);
      }
    }

    hasStack = frameElements.length > 0;
  }

  void updateStackMessages(S.ServiceMap newStack) {
    List newMessages = newStack['messages'];

    // Remove any extra message elements.
    if (_messageList!.childNodes.length > newMessages.length) {
      // Remove old messages from the front of the queue.
      int removeCount = _messageList!.childNodes.length - newMessages.length;
      for (int i = 0; i < removeCount; i++) {
        _messageList!.removeChild(_messageList!.firstChild!);
      }
    }

    // Add any new messages to the tail of the queue.
    int newStartingIndex = _messageList!.childNodes.length;
    if (_messageList!.childNodes.length < newMessages.length) {
      for (int i = newStartingIndex; i < newMessages.length; i++) {
        _addMessage(newMessages[i]);
      }
    }
    assert(_messageList!.childNodes.length == newMessages.length);

    if (_messageList!.childNodes.length > 0) {
      // Update old messages.
      for (int i = 0; i < newStartingIndex; i++) {
        DebuggerMessageElement e =
            CustomElement.reverse(
                  _messageList!.childNodes.item(i)!.firstChild as HTMLElement,
                )
                as DebuggerMessageElement;
        e.updateMessage(newMessages[i]);
      }
    }

    hasMessages = _messageList!.childNodes.length > 0;
  }

  void updateStack(S.ServiceMap newStack, M.DebugEvent? pauseEvent) {
    updateStackFrames(newStack);
    updateStackMessages(newStack);
    isSampled = pauseEvent == null;
  }

  void setCurrentFrame(int? value) {
    currentFrame = value;
    for (int i = 0; i < _frameList!.childNodes.length; i++) {
      final frameElement = _frameList!.childNodes.item(i)!;
      DebuggerFrameElement dbgFrameElement =
          CustomElement.reverse(frameElement.firstChild! as HTMLElement)
              as DebuggerFrameElement;
      if (dbgFrameElement.frame.index == currentFrame) {
        dbgFrameElement.setCurrent(true);
      } else {
        dbgFrameElement.setCurrent(false);
      }
    }
  }

  DebuggerStackElement.created() : super.created('debugger-stack');
}

class DebuggerFrameElement extends CustomElement implements Renderable {
  late RenderingScheduler<DebuggerFrameElement> _r;

  Stream<RenderedEvent<DebuggerFrameElement>> get onRendered => _r.onRendered;

  late HTMLElement _scroller;
  late HTMLDivElement _varsDiv;
  late M.Isolate _isolate;
  late S.Frame _frame;
  S.Frame get frame => _frame;
  late M.ObjectRepository _objects;
  late M.ScriptRepository _scripts;
  late M.EventRepository _events;

  // Is this the current frame?
  bool _current = false;

  // Has this frame been pinned open?
  bool _pinned = false;

  bool _expanded = false;

  void setCurrent(bool value) {
    Future load = (_frame.function != null)
        ? _frame.function!.load()
        : new Future.value(null);
    load.then((func) {
      _current = value;
      if (_current) {
        _expand();
        scrollIntoView();
      } else {
        if (_pinned) {
          _expand();
        } else {
          _unexpand();
        }
      }
    });
  }

  factory DebuggerFrameElement(
    M.Isolate isolate,
    S.Frame frame,
    HTMLElement scroller,
    M.ObjectRepository objects,
    M.ScriptRepository scripts,
    M.EventRepository events, {
    RenderingQueue? queue,
  }) {
    final DebuggerFrameElement e = new DebuggerFrameElement.created();
    e._r = new RenderingScheduler<DebuggerFrameElement>(e, queue: queue);
    e._isolate = isolate;
    e._frame = frame;
    e._scroller = scroller;
    e._objects = objects;
    e._scripts = scripts;
    e._events = events;
    return e;
  }

  DebuggerFrameElement.created() : super.created('debugger-frame');

  void render() {
    if (_pinned) {
      className += ' shadow';
    } else {
      className.replaceAll(' shadow', '');
    }
    if (_current) {
      className += ' current';
    } else {
      className.replaceAll(' current', '');
    }
    if ((_frame.kind == M.FrameKind.asyncSuspensionMarker) ||
        (_frame.kind == M.FrameKind.asyncCausal)) {
      className += ' causalFrame';
    }
    if (_frame.kind == M.FrameKind.asyncSuspensionMarker) {
      final content = <HTMLElement>[
        new HTMLSpanElement()
          ..appendChildren(_createMarkerHeader(_frame.marker!)),
      ];
      setChildren(content);
      return;
    }
    late HTMLButtonElement expandButton;
    final content = <HTMLElement>[
      expandButton = new HTMLButtonElement()
        ..appendChildren(_createHeader())
        ..onClick.listen((e) async {
          expandButton.disabled = true;
          await _toggleExpand();
          expandButton.disabled = false;
        }),
    ];
    if (_expanded) {
      final homeMethod = _frame.function!.homeMethod;
      String? homeMethodName;
      if ((homeMethod.dartOwner is S.Class) && homeMethod.isStatic == true) {
        homeMethodName = '<class>';
      } else if (homeMethod.dartOwner is S.Library) {
        homeMethodName = '<library>';
      }
      late HTMLButtonElement collapseButton;
      content.addAll([
        new HTMLDivElement()
          ..className = 'frameDetails'
          ..appendChildren(<HTMLElement>[
            new HTMLDivElement()
              ..className = 'flex-row-wrap'
              ..appendChildren(<HTMLElement>[
                new HTMLDivElement()
                  ..className = 'flex-item-script'
                  ..appendChildren(
                    _frame.function?.location == null
                        ? const []
                        : [
                            (new SourceInsetElement(
                              _isolate,
                              _frame.function!.location!,
                              _scripts,
                              _objects,
                              _events,
                              currentPos: _frame.location!.tokenPos,
                              variables: _frame.variables,
                              inDebuggerContext: true,
                              queue: _r.queue,
                            )).element,
                          ],
                  ),
                new HTMLDivElement()
                  ..className = 'flex-item-vars'
                  ..appendChildren(<HTMLElement>[
                    _varsDiv = new HTMLDivElement()
                      ..className = 'memberList frameVars'
                      ..appendChildren(
                        ([
                          new HTMLDivElement()
                            ..className = 'memberItem'
                            ..appendChildren(
                              homeMethodName == null
                                  ? const []
                                  : [
                                      new HTMLDivElement()
                                        ..className = 'memberName'
                                        ..textContent = homeMethodName,
                                      new HTMLDivElement()
                                        ..className = 'memberName'
                                        ..appendChildren(<HTMLElement>[
                                          anyRef(
                                            _isolate,
                                            homeMethod.dartOwner,
                                            _objects,
                                            queue: _r.queue,
                                          ),
                                        ]),
                                    ],
                            ),
                        ]..addAll(
                          _frame.variables.map<HTMLElement>(
                            (v) => new HTMLDivElement()
                              ..className = 'memberItem'
                              ..appendChildren(<HTMLElement>[
                                new HTMLDivElement()
                                  ..className = 'memberName'
                                  ..textContent = v.name ?? '',
                                new HTMLDivElement()
                                  ..className = 'memberName'
                                  ..appendChildren(<HTMLElement>[
                                    anyRef(
                                      _isolate,
                                      v['value'],
                                      _objects,
                                      queue: _r.queue,
                                    ),
                                  ]),
                              ]),
                          ),
                        )),
                      ),
                  ]),
              ]),
            new HTMLDivElement()
              ..className = 'frameContractor'
              ..appendChildren(<HTMLElement>[
                collapseButton = new HTMLButtonElement()
                  ..onClick.listen((e) async {
                    collapseButton.disabled = true;
                    await _toggleExpand();
                    collapseButton.disabled = false;
                  })
                  ..appendChild(HTMLSpanElement()..textContent = '🔼'),
              ]),
          ]),
      ]);
    }
    setChildren(content);
  }

  List<HTMLElement> _createMarkerHeader(String marker) {
    final content = <HTMLElement>[
      new HTMLDivElement()
        ..className = 'frameSummaryText'
        ..appendChildren(<HTMLElement>[
          new HTMLDivElement()
            ..className = 'frameId'
            ..textContent = 'Frame ${_frame.index}',
          new HTMLSpanElement()..textContent = '$marker',
        ]),
    ];
    return [
      new HTMLDivElement()
        ..className = 'frameSummary'
        ..appendChildren(content),
    ];
  }

  List<HTMLElement> _createHeader() {
    final content = <HTMLElement>[
      new HTMLDivElement()
        ..className = 'frameSummaryText'
        ..appendChildren(<HTMLElement>[
          new HTMLDivElement()
            ..className = 'frameId'
            ..textContent = 'Frame ${_frame.index}',
          new HTMLSpanElement()..appendChildren(
            _frame.function == null
                ? const []
                : [
                    new FunctionRefElement(
                      _isolate,
                      _frame.function!,
                      queue: _r.queue,
                    ).element,
                  ],
          ),
          new HTMLSpanElement()..textContent = ' ( ',
          new HTMLSpanElement()..appendChildren(
            _frame.function?.location == null
                ? const []
                : [
                    new SourceLinkElement(
                      _isolate,
                      _frame.function!.location!,
                      _scripts,
                      queue: _r.queue,
                    ).element,
                  ],
          ),
          new HTMLSpanElement()..textContent = ' )',
        ]),
    ];
    if (!_expanded) {
      content.add(
        new HTMLDivElement()
          ..className = 'frameExpander'
          ..appendChild(HTMLSpanElement()..textContent = '🔽'),
      );
    }
    return [
      new HTMLDivElement()
        ..className = 'frameSummary'
        ..appendChildren(content),
    ];
  }

  String makeExpandKey(String key) {
    return '${_frame.function!.qualifiedName}/${key}';
  }

  bool matchFrame(S.Frame newFrame) {
    if (newFrame.kind != _frame.kind) {
      return false;
    }
    if (newFrame.function == null) {
      return frame.function == null;
    }
    return (newFrame.function!.id == _frame.function!.id &&
        newFrame.location!.script.id == frame.location!.script.id);
  }

  void updateFrame(S.Frame newFrame) {
    assert(matchFrame(newFrame));
    _frame = newFrame;
  }

  S.Script get script => _frame.location!.script;

  int _varsTop(HTMLDivElement varsDiv) {
    const minTop = 0;
    final num paddingTop = document.body!.offsetTop; //contentEdge.top;
    final DOMRect parent = varsDiv.parentElement!.getBoundingClientRect();
    final int varsHeight = varsDiv.clientHeight;
    final int maxTop = (parent.height - varsHeight).toInt();
    final int adjustedTop = (paddingTop - parent.top).toInt();
    return max(minTop, min(maxTop, adjustedTop));
  }

  void _onScroll(event) {
    if (!_expanded) {
      return;
    }
    String currentTop = _varsDiv.style.top;
    int newTop = _varsTop(_varsDiv);
    if (currentTop != newTop) {
      _varsDiv.style.top = '${newTop}px';
    }
  }

  void _expand() {
    _expanded = true;
    _subscribeToScroll();
    _r.dirty();
  }

  void _unexpand() {
    _expanded = false;
    _unsubscribeToScroll();
    _r.dirty();
  }

  StreamSubscription? _scrollSubscription;
  StreamSubscription? _resizeSubscription;

  void _subscribeToScroll() {
    if (_scrollSubscription == null) {
      _scrollSubscription = _scroller.onScroll.listen(_onScroll);
    }
    if (_resizeSubscription == null) {
      _resizeSubscription = _scroller.onResize.listen(_onScroll);
    }
  }

  void _unsubscribeToScroll() {
    if (_scrollSubscription != null) {
      _scrollSubscription!.cancel();
      _scrollSubscription = null;
    }
    if (_resizeSubscription != null) {
      _resizeSubscription!.cancel();
      _resizeSubscription = null;
    }
  }

  @override
  void attached() {
    super.attached();
    _r.enable();
    if (_expanded) {
      _subscribeToScroll();
    }
  }

  void detached() {
    _r.disable(notify: true);
    super.detached();
    _unsubscribeToScroll();
  }

  Future _toggleExpand() async {
    await _frame.function!.load();
    _pinned = !_pinned;
    if (_pinned) {
      _expand();
    } else {
      _unexpand();
    }
  }
}

class DebuggerMessageElement extends CustomElement implements Renderable {
  late RenderingScheduler<DebuggerMessageElement> _r;

  Stream<RenderedEvent<DebuggerMessageElement>> get onRendered => _r.onRendered;

  late S.Isolate _isolate;
  late S.ServiceMessage _message;
  late S.ServiceObject _preview;
  late M.ObjectRepository _objects;
  late M.ScriptRepository _scripts;
  late M.EventRepository _events;

  // Is this the current message?
  bool _current = false;

  // Has this message been pinned open?
  bool _pinned = false;

  bool _expanded = false;

  factory DebuggerMessageElement(
    S.Isolate isolate,
    S.ServiceMessage message,
    M.ObjectRepository objects,
    M.ScriptRepository scripts,
    M.EventRepository events, {
    RenderingQueue? queue,
  }) {
    final DebuggerMessageElement e = new DebuggerMessageElement.created();
    e._r = new RenderingScheduler<DebuggerMessageElement>(e, queue: queue);
    e._isolate = isolate;
    e._message = message;
    e._objects = objects;
    e._scripts = scripts;
    e._events = events;
    return e;
  }

  DebuggerMessageElement.created() : super.created('debugger-message');

  void render() {
    if (_pinned) {
      className += ' shadow';
    } else {
      className.replaceAll(' shadow', '');
    }
    if (_current) {
      className += ' current';
    } else {
      className.replaceAll(' current', '');
    }
    late HTMLButtonElement expandButton;
    final content = <HTMLElement>[
      expandButton = new HTMLButtonElement()
        ..appendChildren(_createHeader())
        ..onClick.listen((e) async {
          if (e.target is HTMLAnchorElement) {
            return;
          }
          expandButton.disabled = true;
          await _toggleExpand();
          expandButton.disabled = false;
        }),
    ];
    if (_expanded) {
      late HTMLButtonElement collapseButton;
      late HTMLButtonElement previewButton;
      content.addAll([
        new HTMLDivElement()
          ..className = 'messageDetails'
          ..appendChildren(<HTMLElement>[
            new HTMLDivElement()
              ..className = 'flex-row-wrap'
              ..appendChildren(<HTMLElement>[
                new HTMLDivElement()
                  ..className = 'flex-item-script'
                  ..appendChildren(
                    _message.handler == null
                        ? const []
                        : [
                            new SourceInsetElement(
                              _isolate,
                              _message.handler!.location!,
                              _scripts,
                              _objects,
                              _events,
                              inDebuggerContext: true,
                              queue: _r.queue,
                            ).element,
                          ],
                  ),
                new HTMLDivElement()
                  ..className = 'flex-item-vars'
                  ..appendChildren(<HTMLElement>[
                    new HTMLDivElement()
                      ..className = 'memberItem'
                      ..appendChildren(<HTMLElement>[
                        new HTMLDivElement()..className = 'memberName',
                        new HTMLDivElement()
                          ..className = 'memberValue'
                          ..appendChildren(
                            ([
                              previewButton = new HTMLButtonElement()
                                ..textContent = 'preview'
                                ..onClick.listen((_) {
                                  previewButton.disabled = true;
                                }),
                            ]..addAll([
                              anyRef(
                                _isolate,
                                _preview,
                                _objects,
                                queue: _r.queue,
                              ),
                            ])),
                          ),
                      ]),
                  ]),
              ]),
            new HTMLDivElement()
              ..className = 'messageContractor'
              ..appendChildren(<HTMLElement>[
                collapseButton = new HTMLButtonElement()
                  ..onClick.listen((e) async {
                    collapseButton.disabled = true;
                    await _toggleExpand();
                    collapseButton.disabled = false;
                  })
                  ..appendChild(HTMLSpanElement()..textContent = '🔼'),
              ]),
          ]),
      ]);
    }
    setChildren(content);
  }

  void updateMessage(S.ServiceMessage message) {
    _message = message;
    _r.dirty();
  }

  List<HTMLElement> _createHeader() {
    final content = <HTMLElement>[
      new HTMLDivElement()
        ..className = 'messageSummaryText'
        ..appendChildren(<HTMLElement>[
          new HTMLDivElement()
            ..className = 'messageId'
            ..textContent = 'message ${_message.index}',
          new HTMLSpanElement()..appendChildren(
            _message.handler == null
                ? const []
                : [
                    new FunctionRefElement(
                      _isolate,
                      _message.handler!,
                      queue: _r.queue,
                    ).element,
                  ],
          ),
          new HTMLSpanElement()..textContent = ' ( ',
          new HTMLSpanElement()..appendChildren(
            _message.location == null
                ? const []
                : [
                    new SourceLinkElement(
                      _isolate,
                      _message.location!,
                      _scripts,
                      queue: _r.queue,
                    ).element,
                  ],
          ),
          new HTMLSpanElement()..textContent = ' )',
        ]),
    ];
    if (!_expanded) {
      content.add(
        new HTMLDivElement()
          ..className = 'messageExpander'
          ..appendChild(HTMLSpanElement()..textContent = '🔽'),
      );
    }
    return [
      new HTMLDivElement()
        ..className = 'messageSummary'
        ..appendChildren(content),
    ];
  }

  void setCurrent(bool value) {
    _current = value;
    if (_current) {
      _expanded = true;
      scrollIntoView();
      _r.dirty();
    } else {
      _expanded = _pinned;
    }
  }

  @override
  void attached() {
    super.attached();
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    _r.disable(notify: true);
    removeChildren();
  }

  Future _toggleExpand() async {
    var function = _message.handler;
    if (function != null) {
      await function.load();
    }
    _pinned = _pinned;
    _expanded = true;
    _r.dirty();
  }

  Future<S.ServiceObject> previewMessage(_) {
    return _message.isolate!.getObject(_message.messageObjectId!).then((
      result,
    ) {
      _preview = result;
      return result;
    });
  }
}

class DebuggerConsoleElement extends CustomElement implements Renderable {
  factory DebuggerConsoleElement() {
    final DebuggerConsoleElement e = new DebuggerConsoleElement.created();
    e.appendChildren(<HTMLElement>[new HTMLBRElement()]);
    return e;
  }

  DebuggerConsoleElement.created() : super.created('debugger-console');

  /// Is [container] scrolled to the within [threshold] pixels of the bottom?
  // ignore: unused_element_parameter
  static bool _isScrolledToBottom(HTMLDivElement? container) {
    if (container == null) {
      return false;
    }
    // scrollHeight -> complete height of element including scrollable area.
    // clientHeight -> height of element on page.
    // scrollTop -> how far is an element scrolled (from 0 to scrollHeight).
    final distanceFromBottom =
        container.scrollHeight - container.clientHeight - container.scrollTop;
    const threshold = 2; // 2 pixel slop.
    return distanceFromBottom <= threshold;
  }

  /// Scroll [container] so the bottom content is visible.
  static _scrollToBottom(HTMLDivElement? container) {
    if (container == null) {
      return;
    }
    // Adjust scroll so that the bottom of the content is visible.
    container.scrollTop = container.scrollHeight - container.clientHeight;
  }

  void _append(HTMLElement span) {
    bool autoScroll = _isScrolledToBottom(parent as HTMLDivElement?);
    appendChild(span);
    if (autoScroll) {
      _scrollToBottom(parent as HTMLDivElement?);
    }
  }

  void print(String line, {bool newline = true}) {
    _append(
      new HTMLSpanElement()
        ..className = 'normal'
        ..textContent = line + (newline ? "\n" : ""),
    );
  }

  void printBold(String line, {bool newline = true}) {
    _append(
      new HTMLSpanElement()
        ..className = 'bold'
        ..textContent = line + (newline ? "\n" : ""),
    );
  }

  void printRed(String line, {bool newline = true}) {
    _append(
      new HTMLSpanElement()
        ..className = 'red'
        ..textContent = line + (newline ? "\n" : ""),
    );
  }

  void printStdio(List<String> lines) {
    bool autoScroll = _isScrolledToBottom(parent as HTMLDivElement?);
    for (var line in lines) {
      appendChild(
        new HTMLSpanElement()
          ..className = 'green'
          ..textContent = line + "\n",
      );
    }
    if (autoScroll) {
      _scrollToBottom(parent as HTMLDivElement?);
    }
  }

  void printRef(
    S.Isolate isolate,
    S.Instance ref,
    M.ObjectRepository objects, {
    bool newline = true,
  }) {
    _append(
      new InstanceRefElement(isolate, ref, objects, queue: app.queue).element,
    );
    if (newline) {
      this.newline();
    }
  }

  void newline() {
    _append(new HTMLBRElement());
  }

  void clear() {
    removeChildren();
  }

  void render() {
    /* nothing to do */
  }

  ObservatoryApplication get app => ObservatoryApplication.app;
}

class DebuggerInputElement extends CustomElement implements Renderable {
  late ObservatoryDebugger _debugger;
  bool _busy = false;
  final _modalPromptDiv = new HTMLDivElement()
    ..className = 'modalPrompt hidden';
  final _textBox = new HTMLInputElement()
    ..className = 'textBox'
    ..autofocus = true;
  String? get modalPrompt => _modalPromptDiv.textContent;
  set modalPrompt(String? value) {
    if (_modalPromptDiv.textContent == '') {
      _modalPromptDiv.className.replaceAll('hidden', '');
    }
    _modalPromptDiv.textContent = value ?? '';
    if (_modalPromptDiv.textContent == '') {
      _modalPromptDiv.className = 'hidden';
    }
  }

  String? get text => _textBox.value;
  set text(String? value) => _textBox.value = value ?? '';
  var modalCallback = null;

  factory DebuggerInputElement(
    S.Isolate isolate,
    ObservatoryDebugger debugger,
  ) {
    final e = DebuggerInputElement.created();
    return e
      ..appendChildren(<HTMLElement>[e._modalPromptDiv, e._textBox])
      .._textBox.select()
      .._textBox.onKeyDown.listen(e._onKeyDown);
  }

  DebuggerInputElement.created() : super.created('debugger-input');

  void _onKeyDown(KeyboardEvent e) {
    if (_busy) {
      e.preventDefault();
      return;
    }
    _busy = true;
    if (modalCallback != null) {
      if (e.keyCode == KeyCode.ENTER) {
        var response = text;
        modalCallback(response).whenComplete(() {
          text = '';
          _busy = false;
        });
      } else {
        _busy = false;
      }
      return;
    }
    switch (e.keyCode) {
      case KeyCode.TAB:
        e.preventDefault();
        int cursorPos = _textBox.selectionStart!;
        _debugger
            .complete(text!.substring(0, cursorPos))
            .then((completion) {
              text = completion + text!.substring(cursorPos);
              // TODO(turnidge): Move the cursor to the end of the
              // completion, rather than the end of the string.
            })
            .whenComplete(() {
              _busy = false;
            });
        break;

      case KeyCode.ENTER:
        var command = text;
        _debugger.run(command!).whenComplete(() {
          text = '';
          _busy = false;
        });
        break;

      case KeyCode.UP:
        e.preventDefault();
        text = _debugger.historyPrev(text!);
        _busy = false;
        break;

      case KeyCode.DOWN:
        e.preventDefault();
        text = _debugger.historyNext(text!);
        _busy = false;
        break;

      case KeyCode.PAGE_UP:
        e.preventDefault();
        try {
          _debugger.upFrame(1);
        } on RangeError catch (_) {
          // Ignore.
        }
        _busy = false;
        break;

      case KeyCode.PAGE_DOWN:
        e.preventDefault();
        try {
          _debugger.downFrame(1);
        } on RangeError catch (_) {
          // Ignore.
        }
        _busy = false;
        break;

      default:
        switch (e.code) {
          case 'F7':
            e.preventDefault();
            _debugger.resume().whenComplete(() {
              _busy = false;
            });
            break;

          case 'F8':
            e.preventDefault();
            _debugger.toggleBreakpoint().whenComplete(() {
              _busy = false;
            });
            break;

          case 'F9':
            e.preventDefault();
            _debugger.smartNext().whenComplete(() {
              _busy = false;
            });
            break;

          case 'F10':
            e.preventDefault();
            _debugger.step().whenComplete(() {
              _busy = false;
            });
            break;

          case 'Semicolon':
            if (e.ctrlKey) {
              e.preventDefault();
              _debugger.console.printRed('^;');
              _debugger.pause().whenComplete(() {
                _busy = false;
              });
            } else {
              _busy = false;
            }
            break;
          default:
            _busy = false;
            break;
        }
        break;
    }
  }

  void enterMode(String prompt, callback) {
    assert(modalPrompt == null);
    modalPrompt = prompt;
    modalCallback = callback;
  }

  void exitMode() {
    assert(modalPrompt != null);
    modalPrompt = null;
    modalCallback = null;
  }

  void focus() {
    _textBox.focus();
  }

  void render() {
    // Nothing to do.
  }
}
