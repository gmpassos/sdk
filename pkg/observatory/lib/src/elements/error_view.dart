// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library error_view_element;

import 'dart:async';

import 'package:web/web.dart';

import '../../models.dart' as M;
import 'helpers/custom_element.dart';
import 'helpers/element_utils.dart';
import 'helpers/nav_bar.dart';
import 'helpers/rendering_scheduler.dart';
import 'nav/notify.dart';
import 'nav/top_menu.dart';

class ErrorViewElement extends CustomElement implements Renderable {
  late RenderingScheduler<ErrorViewElement> _r;

  Stream<RenderedEvent<ErrorViewElement>> get onRendered => _r.onRendered;

  late M.Error _error;
  late M.NotificationRepository _notifications;

  M.Error get error => _error;

  factory ErrorViewElement(
    M.NotificationRepository notifications,
    M.Error error, {
    RenderingQueue? queue,
  }) {
    ErrorViewElement e = new ErrorViewElement.created();
    e._r = new RenderingScheduler<ErrorViewElement>(e, queue: queue);
    e._error = error;
    e._notifications = notifications;
    return e;
  }

  ErrorViewElement.created() : super.created('error-view');

  @override
  void attached() {
    super.attached();
    _r.enable();
  }

  @override
  void detached() {
    super.detached();
    removeChildren();
    _r.disable(notify: true);
  }

  void render() {
    setChildren(<HTMLElement>[
      navBar(<HTMLElement>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavNotifyElement(_notifications, queue: _r.queue).element,
      ]),
      new HTMLDivElement()
        ..className = 'content-centered'
        ..appendChildren(<HTMLElement>[
          new HTMLHeadingElement.h1()
            ..textContent = 'Error: ${_kindToString(_error.kind)}',
          new HTMLBRElement(),
          new HTMLDivElement()
            ..className = 'well'
            ..appendChild(
              new HTMLPreElement.pre()..textContent = error.message ?? '',
            ),
        ]),
    ]);
  }

  static String _kindToString(M.ErrorKind? kind) {
    switch (kind) {
      case M.ErrorKind.unhandledException:
        return 'Unhandled Exception';
      case M.ErrorKind.languageError:
        return 'Language Error';
      case M.ErrorKind.internalError:
        return 'Internal Error';
      case M.ErrorKind.terminationError:
        return 'Termination Error';
      default:
        throw new Exception('Unknown M.ErrorKind ($kind)');
    }
  }
}
