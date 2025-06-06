// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library logging_page;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:web/web.dart';

import '../../models.dart' as M;
import 'helpers/custom_element.dart';
import 'helpers/element_utils.dart';
import 'helpers/nav_bar.dart';
import 'helpers/nav_menu.dart';
import 'helpers/rendering_scheduler.dart';
import 'logging_list.dart';
import 'nav/isolate_menu.dart';
import 'nav/notify.dart';
import 'nav/refresh.dart';
import 'nav/top_menu.dart';
import 'nav/vm_menu.dart';

class LoggingPageElement extends CustomElement implements Renderable {
  late RenderingScheduler<LoggingPageElement> _r;

  Stream<RenderedEvent<LoggingPageElement>> get onRendered => _r.onRendered;

  late M.VM _vm;
  late M.IsolateRef _isolate;
  late M.EventRepository _events;
  late M.NotificationRepository _notifications;
  late Level _level = Level.ALL;

  M.VMRef get vm => _vm;
  M.IsolateRef get isolate => _isolate;
  M.NotificationRepository get notifications => _notifications;

  factory LoggingPageElement(
    M.VM vm,
    M.IsolateRef isolate,
    M.EventRepository events,
    M.NotificationRepository notifications, {
    RenderingQueue? queue,
  }) {
    LoggingPageElement e = new LoggingPageElement.created();
    e._r = new RenderingScheduler<LoggingPageElement>(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._events = events;
    e._notifications = notifications;
    return e;
  }

  LoggingPageElement.created() : super.created('logging-page');

  @override
  attached() {
    super.attached();
    _r.enable();
  }

  @override
  detached() {
    super.detached();
    _r.disable(notify: true);
    removeChildren();
  }

  LoggingListElement? _logs;

  void render() {
    _logs = _logs ?? new LoggingListElement(_isolate, _events);
    _logs!.level = _level;
    children = <HTMLElement>[
      navBar(<HTMLElement>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavVMMenuElement(_vm, _events, queue: _r.queue).element,
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue).element,
        navMenu('logging'),
        (new NavRefreshElement(label: 'clear', queue: _r.queue)
              ..onRefresh.listen((e) async {
                e.element.disabled = true;
                _logs = null;
                _r.dirty();
              }))
            .element,
        new NavNotifyElement(_notifications, queue: _r.queue).element,
      ]),
      new HTMLDivElement()
        ..className = 'content-centered-big'
        ..appendChildren(<HTMLElement>[
          new HTMLHeadingElement.h2()..textContent = 'Logging',
          new HTMLSpanElement()..textContent = 'Show messages with severity ',
          _createLevelSelector(),
          new HTMLHRElement(),
          _logs!.element,
        ]),
    ];
  }

  HTMLElement _createLevelSelector() {
    final s = HTMLSelectElement()
      ..value = _level.name
      ..appendChildren(
        Level.LEVELS.map(
          (level) => HTMLOptionElement()
            ..value = level.name
            ..selected = _level == level
            ..text = level.name,
        ),
      );
    s.onChange.listen((_) {
      _level = Level.LEVELS[s.selectedIndex];
      _r.dirty();
    });
    return s;
  }
}
