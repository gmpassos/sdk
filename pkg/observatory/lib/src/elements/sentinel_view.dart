// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:web/web.dart';

import '../../models.dart' as M;
import 'helpers/custom_element.dart';
import 'helpers/element_utils.dart';
import 'helpers/nav_bar.dart';
import 'helpers/nav_menu.dart';
import 'helpers/rendering_scheduler.dart';
import 'nav/isolate_menu.dart';
import 'nav/notify.dart';
import 'nav/top_menu.dart';
import 'nav/vm_menu.dart';

class SentinelViewElement extends CustomElement implements Renderable {
  late RenderingScheduler<SentinelViewElement> _r;

  Stream<RenderedEvent<SentinelViewElement>> get onRendered => _r.onRendered;

  late M.VM _vm;
  late M.IsolateRef _isolate;
  late M.Sentinel _sentinel;
  late M.EventRepository _events;
  late M.NotificationRepository _notifications;

  M.Sentinel get sentinel => _sentinel;

  factory SentinelViewElement(
    M.VM vm,
    M.IsolateRef isolate,
    M.Sentinel sentinel,
    M.EventRepository events,
    M.NotificationRepository notifications, {
    RenderingQueue? queue,
  }) {
    SentinelViewElement e = new SentinelViewElement.created();
    e._r = new RenderingScheduler<SentinelViewElement>(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._sentinel = sentinel;
    e._events = events;
    e._notifications = notifications;
    return e;
  }

  SentinelViewElement.created() : super.created('sentinel-view');

  @override
  void attached() {
    super.attached();
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    _r.disable(notify: true);
    innerText = '';
    title = '';
  }

  void render() {
    setChildren(<HTMLElement>[
      navBar(<HTMLElement>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavVMMenuElement(_vm, _events, queue: _r.queue).element,
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue).element,
        navMenu('sentinel'),
        new NavNotifyElement(_notifications, queue: _r.queue).element,
      ]),
      new HTMLDivElement()
        ..className = 'content-centered-big'
        ..appendChildren(<HTMLElement>[
          new HTMLHeadingElement.h2()
            ..textContent = 'Sentinel: #{_sentinel.valueAsString}',
          new HTMLHRElement(),
          new HTMLDivElement()
            ..textContent = _sentinelKindToDescription(_sentinel.kind),
        ]),
    ]);
  }

  static String _sentinelKindToDescription(M.SentinelKind kind) {
    switch (kind) {
      case M.SentinelKind.collected:
        return 'This object has been reclaimed by the garbage collector.';
      case M.SentinelKind.expired:
        return 'The handle to this object has expired. '
            'Consider refreshing the page.';
      case M.SentinelKind.notInitialized:
        return 'This object will be initialized once it is accessed by '
            'the program.';
      case M.SentinelKind.optimizedOut:
        return 'This object is no longer needed and has been removed by the '
            'optimizing compiler.';
      case M.SentinelKind.free:
        return '';
    }
  }
}
