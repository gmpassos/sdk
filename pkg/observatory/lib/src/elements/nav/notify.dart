// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:web/web.dart';

import '../../../models.dart' as M;
import '../helpers/custom_element.dart';
import '../helpers/element_utils.dart';
import '../helpers/rendering_scheduler.dart';
import 'notify_event.dart';
import 'notify_exception.dart';

class NavNotifyElement extends CustomElement implements Renderable {
  late RenderingScheduler<NavNotifyElement> _r;

  Stream<RenderedEvent<NavNotifyElement>> get onRendered => _r.onRendered;

  late M.NotificationRepository _repository;
  StreamSubscription? _subscription;

  late bool _notifyOnPause;

  bool get notifyOnPause => _notifyOnPause;

  set notifyOnPause(bool value) =>
      _notifyOnPause = _r.checkAndReact(_notifyOnPause, value);

  factory NavNotifyElement(
    M.NotificationRepository repository, {
    bool notifyOnPause = true,
    RenderingQueue? queue,
  }) {
    NavNotifyElement e = new NavNotifyElement.created();
    e._r = new RenderingScheduler<NavNotifyElement>(e, queue: queue);
    e._repository = repository;
    e._notifyOnPause = notifyOnPause;
    return e;
  }

  NavNotifyElement.created() : super.created('nav-notify');

  @override
  void attached() {
    super.attached();
    _subscription = _repository.onChange.listen((_) => _r.dirty());
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
    _subscription!.cancel();
  }

  void render() {
    children = <HTMLElement>[
      new HTMLDivElement()..appendChildren(<HTMLElement>[
        new HTMLDivElement()..appendChildren(
          _repository
              .list()
              .where(_filter)
              .map<HTMLElement>(_toElement)
              .toList(),
        ),
      ]),
    ];
  }

  bool _filter(M.Notification notification) {
    if (!_notifyOnPause && notification is M.EventNotification) {
      return notification.event is! M.PauseEvent;
    }
    return true;
  }

  HTMLElement _toElement(M.Notification notification) {
    if (notification is M.EventNotification) {
      return (new NavNotifyEventElement(
        notification.event,
        queue: _r.queue,
      )..onDelete.listen((_) => _repository.delete(notification))).element;
    } else if (notification is M.ExceptionNotification) {
      return (new NavNotifyExceptionElement(
        notification.exception,
        stacktrace: notification.stacktrace,
        queue: _r.queue,
      )..onDelete.listen((_) => _repository.delete(notification))).element;
    } else {
      assert(false);
      return new HTMLDivElement()..textContent = 'Invalid Notification Type';
    }
  }
}
