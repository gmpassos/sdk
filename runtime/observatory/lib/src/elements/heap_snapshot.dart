// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as Math;
import 'dart:typed_data';

import 'package:web/web.dart';

import 'package:observatory/models.dart' as M;
import 'package:observatory/object_graph.dart';
import 'package:observatory/src/elements/containers/virtual_tree.dart';
import 'package:observatory/src/elements/helpers/custom_element.dart';
import 'package:observatory/src/elements/helpers/element_utils.dart';
import 'package:observatory/src/elements/helpers/nav_bar.dart';
import 'package:observatory/src/elements/helpers/nav_menu.dart';
import 'package:observatory/src/elements/helpers/rendering_scheduler.dart';
import 'package:observatory/src/elements/nav/isolate_menu.dart';
import 'package:observatory/src/elements/nav/notify.dart';
import 'package:observatory/src/elements/nav/refresh.dart';
import 'package:observatory/src/elements/nav/top_menu.dart';
import 'package:observatory/src/elements/nav/vm_menu.dart';
import 'package:observatory/src/elements/tree_map.dart';
import 'package:observatory/utils.dart';

enum HeapSnapshotTreeMode {
  classesTable,
  classesTableDiff,
  classesTreeMap,
  classesTreeMapDiff,
  dominatorTree,
  dominatorTreeMap,
  mergedDominatorTree,
  mergedDominatorTreeDiff,
  mergedDominatorTreeMap,
  mergedDominatorTreeMapDiff,
  ownershipTable,
  ownershipTableDiff,
  ownershipTreeMap,
  ownershipTreeMapDiff,
  predecessors,
  successors,
}

// Note the order of these lists is reflected in the UI, and the first option
// is the default.
const viewModes = [
  HeapSnapshotTreeMode.mergedDominatorTreeMap,
  HeapSnapshotTreeMode.mergedDominatorTree,
  HeapSnapshotTreeMode.dominatorTreeMap,
  HeapSnapshotTreeMode.dominatorTree,
  HeapSnapshotTreeMode.ownershipTreeMap,
  HeapSnapshotTreeMode.ownershipTable,
  HeapSnapshotTreeMode.classesTreeMap,
  HeapSnapshotTreeMode.classesTable,
  HeapSnapshotTreeMode.successors,
  HeapSnapshotTreeMode.predecessors,
];

const diffModes = [
  HeapSnapshotTreeMode.mergedDominatorTreeMapDiff,
  HeapSnapshotTreeMode.mergedDominatorTreeDiff,
  HeapSnapshotTreeMode.ownershipTreeMapDiff,
  HeapSnapshotTreeMode.ownershipTableDiff,
  HeapSnapshotTreeMode.classesTreeMapDiff,
  HeapSnapshotTreeMode.classesTableDiff,
];

class DominatorTreeMap extends NormalTreeMap<SnapshotObject> {
  HeapSnapshotElement element;
  DominatorTreeMap(this.element);

  int getSize(SnapshotObject node) => node.retainedSize;
  String getType(SnapshotObject node) => node.klass.name;
  String getName(SnapshotObject node) => node.description;
  SnapshotObject getParent(SnapshotObject node) => node.parent;
  Iterable<SnapshotObject> getChildren(SnapshotObject node) => node.children;
  void onSelect(SnapshotObject node) {
    element.selection = List.from(node.objects);
    element._r.dirty();
  }

  void onDetails(SnapshotObject node) {
    element.selection = List.from(node.objects);
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class MergedDominatorTreeMap extends NormalTreeMap<SnapshotMergedDominator> {
  HeapSnapshotElement element;
  MergedDominatorTreeMap(this.element);

  int getSize(SnapshotMergedDominator node) => node.retainedSize;
  String getType(SnapshotMergedDominator node) => node.klass.name;
  String getName(SnapshotMergedDominator node) => node.description;
  SnapshotMergedDominator getParent(SnapshotMergedDominator node) =>
      node.parent;
  Iterable<SnapshotMergedDominator> getChildren(SnapshotMergedDominator node) =>
      node.children;
  void onSelect(SnapshotMergedDominator node) {
    element.mergedSelection = node;
    element._r.dirty();
  }

  void onDetails(SnapshotMergedDominator node) {
    element.selection = List.from(node.objects);
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class MergedDominatorDiffTreeMap extends DiffTreeMap<MergedDominatorDiff> {
  HeapSnapshotElement element;
  MergedDominatorDiffTreeMap(this.element);

  int getSizeA(MergedDominatorDiff node) => node.retainedSizeA;
  int getSizeB(MergedDominatorDiff node) => node.retainedSizeB;
  int getGain(MergedDominatorDiff node) => node.retainedGain;
  int getLoss(MergedDominatorDiff node) => node.retainedLoss;
  int getCommon(MergedDominatorDiff node) => node.retainedCommon;

  String getType(MergedDominatorDiff node) => node.name;
  String getName(MergedDominatorDiff node) => "instances of ${node.name}";
  MergedDominatorDiff? getParent(MergedDominatorDiff node) => node.parent;
  Iterable<MergedDominatorDiff> getChildren(MergedDominatorDiff node) =>
      node.children!;
  void onSelect(MergedDominatorDiff node) {
    element.mergedDiffSelection = node;
    element._r.dirty();
  }

  void onDetails(MergedDominatorDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesShallowTreeMap extends NormalTreeMap<SnapshotClass> {
  HeapSnapshotElement element;
  SnapshotGraph snapshot;

  ClassesShallowTreeMap(this.element, this.snapshot);

  int getSize(SnapshotClass node) => node.shallowSize;
  String getType(SnapshotClass node) => node.name;
  String getName(SnapshotClass node) =>
      "${node.instanceCount} instances of ${node.name}";

  SnapshotClass? getParent(SnapshotClass node) => null;
  Iterable<SnapshotClass> getChildren(SnapshotClass node) => [];
  void onSelect(SnapshotClass node) {}
  void onDetails(SnapshotClass node) {
    element.selection = List.from(node.instances);
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesShallowDiffTreeMap extends DiffTreeMap<SnapshotClassDiff> {
  HeapSnapshotElement element;
  List<SnapshotClassDiff> classes;

  ClassesShallowDiffTreeMap(this.element, this.classes);

  int getSizeA(SnapshotClassDiff node) {
    return node.shallowSizeA;
  }

  int getSizeB(SnapshotClassDiff node) {
    return node.shallowSizeB;
  }

  int getGain(SnapshotClassDiff node) {
    return node.shallowSizeGain;
  }

  int getLoss(SnapshotClassDiff node) {
    return node.shallowSizeLoss;
  }

  int getCommon(SnapshotClassDiff node) {
    return node.shallowSizeCommon;
  }

  String getType(SnapshotClassDiff node) => node.name;
  String getName(SnapshotClassDiff node) => "instances of ${node.name}";
  SnapshotClassDiff? getParent(SnapshotClassDiff node) => null;
  Iterable<SnapshotClassDiff> getChildren(SnapshotClassDiff node) => [];
  void onSelect(SnapshotClassDiff node) {}
  void onDetails(SnapshotClassDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesOwnershipTreeMap extends NormalTreeMap<SnapshotClass> {
  HeapSnapshotElement element;
  SnapshotGraph snapshot;

  ClassesOwnershipTreeMap(this.element, this.snapshot);

  int getSize(SnapshotClass node) => node.ownedSize;
  String getType(SnapshotClass node) => node.name;
  String getName(SnapshotClass node) =>
      "${node.instanceCount} instances of ${node.name}";
  SnapshotClass? getParent(SnapshotClass node) => null;
  Iterable<SnapshotClass> getChildren(SnapshotClass node) => [];
  void onSelect(SnapshotClass node) {}
  void onDetails(SnapshotClass node) {
    element.selection = List.from(node.instances);
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesOwnershipDiffTreeMap extends DiffTreeMap<SnapshotClassDiff> {
  HeapSnapshotElement element;
  List<SnapshotClassDiff> classes;

  ClassesOwnershipDiffTreeMap(this.element, this.classes);

  int getSizeA(SnapshotClassDiff node) {
    return node.ownedSizeA;
  }

  int getSizeB(SnapshotClassDiff node) {
    return node.ownedSizeB;
  }

  int getGain(SnapshotClassDiff node) {
    return node.ownedSizeGain;
  }

  int getLoss(SnapshotClassDiff node) {
    return node.ownedSizeLoss;
  }

  int getCommon(SnapshotClassDiff node) {
    return node.ownedSizeCommon;
  }

  String getType(SnapshotClassDiff node) => node.name;
  String getName(SnapshotClassDiff node) => "instances of ${node.name}";
  SnapshotClassDiff? getParent(SnapshotClassDiff node) => null;
  Iterable<SnapshotClassDiff> getChildren(SnapshotClassDiff node) => [];
  void onSelect(SnapshotClassDiff node) {}
  void onDetails(SnapshotClassDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class SnapshotClassDiff {
  SnapshotClass? _a;
  SnapshotClass? _b;

  int get shallowSizeA => _a == null ? 0 : _a!.shallowSize;
  int get ownedSizeA => _a == null ? 0 : _a!.ownedSize;
  int get instanceCountA => _a == null ? 0 : _a!.instanceCount;

  int get shallowSizeB => _b == null ? 0 : _b!.shallowSize;
  int get ownedSizeB => _b == null ? 0 : _b!.ownedSize;
  int get instanceCountB => _b == null ? 0 : _b!.instanceCount;

  int get shallowSizeDiff => shallowSizeB - shallowSizeA;
  int get ownedSizeDiff => ownedSizeB - ownedSizeA;
  int get instanceCountDiff => instanceCountB - instanceCountA;

  int get shallowSizeGain =>
      shallowSizeB > shallowSizeA ? shallowSizeB - shallowSizeA : 0;
  int get ownedSizeGain =>
      ownedSizeB > ownedSizeA ? ownedSizeB - ownedSizeA : 0;
  int get shallowSizeLoss =>
      shallowSizeA > shallowSizeB ? shallowSizeA - shallowSizeB : 0;
  int get ownedSizeLoss =>
      ownedSizeA > ownedSizeB ? ownedSizeA - ownedSizeB : 0;
  int get shallowSizeCommon =>
      shallowSizeB > shallowSizeA ? shallowSizeA : shallowSizeB;
  int get ownedSizeCommon => ownedSizeB > ownedSizeA ? ownedSizeA : ownedSizeB;

  String get name => _a == null ? _b!.name : _a!.name;

  List<SnapshotObject> get objectsA =>
      _a == null ? const <SnapshotObject>[] : _a!.instances.toList();
  List<SnapshotObject> get objectsB =>
      _b == null ? const <SnapshotObject>[] : _b!.instances.toList();

  static List<SnapshotClassDiff> from(
      SnapshotGraph graphA, SnapshotGraph graphB) {
    // Matching classes by SnapshotClass.qualifiedName.
    var classesB = new Map<String, SnapshotClass>();
    var classesDiff = <SnapshotClassDiff>[];
    for (var classB in graphB.classes) {
      classesB[classB.qualifiedName] = classB;
    }
    for (var classA in graphA.classes) {
      var classDiff = new SnapshotClassDiff();
      var qualifiedName = classA.qualifiedName;
      classDiff._a = classA;
      var classB = classesB[qualifiedName];
      if (classB != null) {
        classesB.remove(qualifiedName);
        classDiff._b = classB;
      }
      classesDiff.add(classDiff);
    }
    for (var classB in classesB.values) {
      var classDiff = new SnapshotClassDiff();
      classDiff._b = classB;
      classesDiff.add(classDiff);
    }
    return classesDiff;
  }
}

class MergedDominatorDiff {
  SnapshotMergedDominator? _a;
  SnapshotMergedDominator? _b;
  MergedDominatorDiff? parent;
  List<MergedDominatorDiff>? children;
  int retainedGain = -1;
  int retainedLoss = -1;
  int retainedCommon = -1;

  int get shallowSizeA => _a == null ? 0 : _a!.shallowSize;
  int get retainedSizeA => _a == null ? 0 : _a!.retainedSize;
  int get instanceCountA => _a == null ? 0 : _a!.instanceCount;

  int get shallowSizeB => _b == null ? 0 : _b!.shallowSize;
  int get retainedSizeB => _b == null ? 0 : _b!.retainedSize;
  int get instanceCountB => _b == null ? 0 : _b!.instanceCount;

  int get shallowSizeDiff => shallowSizeB - shallowSizeA;
  int get retainedSizeDiff => retainedSizeB - retainedSizeA;
  int get instanceCountDiff => instanceCountB - instanceCountA;

  String get name => _a == null ? _b!.klass.name : _a!.klass.name;

  List<SnapshotObject> get objectsA =>
      _a == null ? const <SnapshotObject>[] : _a!.objects.toList();
  List<SnapshotObject> get objectsB =>
      _b == null ? const <SnapshotObject>[] : _b!.objects.toList();

  static MergedDominatorDiff from(
      SnapshotMergedDominator a, SnapshotMergedDominator b) {
    var root = new MergedDominatorDiff();
    root._a = a;
    root._b = b;

    // We must use an explicit stack instead of the call stack because the
    // dominator tree can be arbitrarily deep. We need to compute the full
    // tree to compute areas, so we do this eagerly to avoid having to
    // repeatedly test for initialization.
    var worklist = <MergedDominatorDiff>[];
    worklist.add(root);
    // Compute children top-down.
    for (var i = 0; i < worklist.length; i++) {
      worklist[i]._computeChildren(worklist);
    }
    // Compute area bottom-up.
    for (var i = worklist.length - 1; i >= 0; i--) {
      worklist[i]._computeArea();
    }

    return root;
  }

  void _computeChildren(List<MergedDominatorDiff> worklist) {
    assert(children == null);
    children = <MergedDominatorDiff>[];

    // Matching children by MergedObjectVertex.klass.qualifiedName.
    final childrenB = <String, SnapshotMergedDominator>{};
    if (_b != null)
      for (var childB in _b!.children) {
        childrenB[childB.klass.qualifiedName] = childB;
      }
    if (_a != null)
      for (var childA in _a!.children) {
        var childDiff = new MergedDominatorDiff();
        childDiff.parent = this;
        childDiff._a = childA;
        var qualifiedName = childA.klass.qualifiedName;
        var childB = childrenB[qualifiedName];
        if (childB != null) {
          childrenB.remove(qualifiedName);
          childDiff._b = childB;
        }
        children!.add(childDiff);
        worklist.add(childDiff);
      }
    for (var childB in childrenB.values) {
      var childDiff = new MergedDominatorDiff();
      childDiff.parent = this;
      childDiff._b = childB;
      children!.add(childDiff);
      worklist.add(childDiff);
    }

    if (children!.length == 0) {
      // Compress.
      children = const <MergedDominatorDiff>[];
    }
  }

  void _computeArea() {
    int g = 0;
    int l = 0;
    int c = 0;
    for (var child in children!) {
      g += child.retainedGain;
      l += child.retainedLoss;
      c += child.retainedCommon;
    }
    int d = shallowSizeDiff;
    if (d > 0) {
      g += d;
      c += shallowSizeA;
    } else {
      l -= d;
      c += shallowSizeB;
    }
    assert(retainedSizeA + g - l == retainedSizeB);
    retainedGain = g;
    retainedLoss = l;
    retainedCommon = c;
  }
}

class HeapSnapshotElement extends CustomElement implements Renderable {
  late RenderingScheduler<HeapSnapshotElement> _r;

  Stream<RenderedEvent<HeapSnapshotElement>> get onRendered => _r.onRendered;

  late M.VM _vm;
  late M.IsolateRef _isolate;
  late M.EventRepository _events;
  late M.NotificationRepository _notifications;
  late M.HeapSnapshotRepository _snapshots;
  SnapshotReader? _reader;
  String? _status;
  List<SnapshotGraph> _loadedSnapshots = <SnapshotGraph>[];
  SnapshotGraph? _snapshotA;
  SnapshotGraph? _snapshotB;
  HeapSnapshotTreeMode _mode = HeapSnapshotTreeMode.mergedDominatorTreeMap;
  M.IsolateRef get isolate => _isolate;
  M.NotificationRepository get notifications => _notifications;
  M.HeapSnapshotRepository get profiles => _snapshots;
  M.VMRef get vm => _vm;

  List<SnapshotObject>? selection;
  SnapshotMergedDominator? mergedSelection;
  MergedDominatorDiff? mergedDiffSelection;

  factory HeapSnapshotElement(
      M.VM vm,
      M.IsolateRef isolate,
      M.EventRepository events,
      M.NotificationRepository notifications,
      M.HeapSnapshotRepository snapshots,
      M.ObjectRepository objects,
      {RenderingQueue? queue}) {
    HeapSnapshotElement e = new HeapSnapshotElement.created();
    e._r = new RenderingScheduler<HeapSnapshotElement>(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._events = events;
    e._notifications = notifications;
    e._snapshots = snapshots;
    return e;
  }

  HeapSnapshotElement.created() : super.created('heap-snapshot');

  @override
  attached() {
    super.attached();
    _r.enable();
    _refresh();
  }

  @override
  detached() {
    super.detached();
    _r.disable(notify: true);
    removeChildren();
  }

  void render() {
    final content = <HTMLElement>[
      navBar(<HTMLElement>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavVMMenuElement(_vm, _events, queue: _r.queue).element,
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue).element,
        navMenu('heap snapshot'),
        (new NavRefreshElement(queue: _r.queue)
              ..disabled = _reader != null
              ..onRefresh.listen((e) {
                _refresh();
              }))
            .element,
        (new NavRefreshElement(label: 'save', queue: _r.queue)
              ..disabled = _reader != null
              ..onRefresh.listen((e) {
                _save();
              }))
            .element,
        (new NavRefreshElement(label: 'load', queue: _r.queue)
              ..disabled = _reader != null
              ..onRefresh.listen((e) {
                _load();
              }))
            .element,
        new NavNotifyElement(_notifications, queue: _r.queue).element
      ]),
    ];
    if (_reader != null) {
      // Loading
      content.addAll(_createStatusMessage('Loading snapshot...',
          description: _status!, progress: 1));
    } else if (_snapshotA != null) {
      // Loaded
      content.addAll(_createReport());
    }
    setChildren(content);
  }

  _refresh() {
    _reader = null;
    _snapshotLoading(_snapshots.get(isolate));
  }

  _save() {
    final blob = Blob(_snapshotA!.chunks as JSArray<JSAny>,
        BlobPropertyBag(type: 'application/octet-stream'));
    var blobUrl = URL.createObjectURL(blob);
    var link = new HTMLAnchorElement();
    link.href = blobUrl;
    var now = new DateTime.now();
    link.download = 'dart-heap-${now.year}-${now.month}-${now.day}.bin';
    link.click();
  }

  _load() {
    var input = new HTMLInputElement();
    input.type = 'file';
    input.multiple = false;
    input.onChange.listen((_) {
      File file = input.files!.item(0) as File;
      final reader = FileReader();
      reader
        ..onLoadEnd.first.then((_) async {
          final snapshotReader = new SnapshotReader();
          _snapshotLoading(snapshotReader);
          snapshotReader.add((reader.result as ByteBuffer).asUint8List());
          snapshotReader.close();
        })
        ..readAsArrayBuffer(file);
    });
    input.click();
  }

  _snapshotLoading(SnapshotReader reader) async {
    _status = '';
    _reader = reader;
    reader.onProgress.listen((String status) {
      _status = status;
      _r.dirty();
    });
    _snapshotLoaded(await reader.done);
  }

  _snapshotLoaded(SnapshotGraph snapshot) {
    _reader = null;
    _loadedSnapshots.add(snapshot);
    _snapshotA = snapshot;
    _snapshotB = snapshot;
    selection = null;
    mergedSelection = null;
    mergedDiffSelection = null;
    _r.dirty();
  }

  static List<HTMLElement> _createStatusMessage(String message,
      {String description = '', double progress = 0.0}) {
    return [
      new HTMLDivElement()
        ..className = 'content-centered-big'
        ..appendChildren(<HTMLElement>[
          new HTMLDivElement()
            ..className = 'statusBox shadow center'
            ..appendChildren(<HTMLElement>[
              new HTMLDivElement()
                ..className = 'statusMessage'
                ..textContent = message,
              new HTMLDivElement()
                ..className = 'statusDescription'
                ..textContent = description,
              new HTMLDivElement()
                ..style.background = '#0489c3'
                ..style.width = '$progress%'
                ..style.height = '15px'
                ..style.borderRadius = '4px'
            ])
        ])
    ];
  }

  VirtualTreeElement? _tree;

  void _createTreeMap<T>(List<HTMLElement> report, TreeMap<T> treemap, T root) {
    final content = new HTMLDivElement();
    content.style.border = '1px solid black';
    content.style.width = '100%';
    content.style.height = '100%';
    content.textContent = 'Performing layout...';
    Timer.run(() {
      // Generate the treemap after the content div has been added to the
      // document so that we can ask the browser how much space is
      // available for treemap layout.
      treemap.showIn(root, content);
    });

    final text =
        'Double-click a tile to zoom in. Double-click the outermost tile to zoom out. Right-click a tile to inspect its objects.';
    report.addAll([
      new HTMLDivElement()
        ..className = 'content-centered-big explanation'
        ..textContent = text,
      new HTMLDivElement()
        ..className = 'content-centered-big'
        ..style.width = '100%'
        ..style.height = '100%'
        ..appendChild(content)
    ]);
  }

  List<HTMLElement> _createReport() {
    var report = <HTMLElement>[
      new HTMLDivElement()
        ..className = 'content-centered-big'
        ..appendChildren(<HTMLElement>[
          new HTMLDivElement()
            ..className = 'memberList'
            ..appendChildren(<HTMLElement>[
              new HTMLDivElement()
                ..className = 'memberItem'
                ..appendChildren(<HTMLElement>[
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..textContent = 'Snapshot A',
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..appendChildren(_createSnapshotSelectA())
                ]),
              new HTMLDivElement()
                ..className = 'memberItem'
                ..appendChildren(<HTMLElement>[
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..textContent = 'Snapshot B',
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..appendChildren(_createSnapshotSelectB())
                ]),
              new HTMLDivElement()
                ..className = 'memberItem'
                ..appendChildren(<HTMLElement>[
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..textContent =
                        (_snapshotA == _snapshotB) ? 'View ' : 'Compare ',
                  new HTMLDivElement()
                    ..className = 'memberName'
                    ..appendChildren(_createModeSelect())
                ])
            ])
        ]),
    ];
    switch (_mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        if (selection == null) {
          selection = List.from(_snapshotA!.extendedRoot.objects);
        }
        _tree = new VirtualTreeElement(
            _createDominator, _updateDominator, _getChildrenDominator,
            items: selection!, queue: _r.queue);
        if (selection!.length == 1) {
          _tree!.expand(selection!.first);
        }
        final text = 'In a heap dominator tree, an object X is a parent of '
            'object Y if every path from the root to Y goes through '
            'X. This allows you to find "choke points" that are '
            'holding onto a lot of memory. If an object becomes '
            'garbage, all its children in the dominator tree become '
            'garbage as well.';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.dominatorTreeMap:
        if (selection == null) {
          selection = List.from(_snapshotA!.extendedRoot.objects);
        }
        _createTreeMap(report, new DominatorTreeMap(this), selection!.first);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTree:
        _tree = new VirtualTreeElement(_createMergedDominator,
            _updateMergedDominator, _getChildrenMergedDominator,
            items: _getChildrenMergedDominator(_snapshotA!.extendedMergedRoot),
            queue: _r.queue);
        _tree!.expand(_snapshotA!.extendedMergedRoot);
        final text = 'A heap dominator tree, where siblings with the same class'
            ' have been merged into a single node.';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeDiff:
        var root = MergedDominatorDiff.from(
            _snapshotA!.extendedMergedRoot, _snapshotB!.extendedMergedRoot);
        _tree = new VirtualTreeElement(_createMergedDominatorDiff,
            _updateMergedDominatorDiff, _getChildrenMergedDominatorDiff,
            items: _getChildrenMergedDominatorDiff(root), queue: _r.queue);
        _tree!.expand(root);
        final text = 'A heap dominator tree, where siblings with the same class'
            ' have been merged into a single node.';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeMap:
        if (mergedSelection == null) {
          mergedSelection = _snapshotA!.extendedMergedRoot;
        }
        _createTreeMap(
            report, new MergedDominatorTreeMap(this), mergedSelection);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeMapDiff:
        if (mergedDiffSelection == null) {
          mergedDiffSelection = MergedDominatorDiff.from(
              _snapshotA!.extendedMergedRoot, _snapshotB!.extendedMergedRoot);
        }
        _createTreeMap(
            report, new MergedDominatorDiffTreeMap(this), mergedDiffSelection);
        break;
      case HeapSnapshotTreeMode.ownershipTable:
        final items =
            _snapshotA!.classes.where((c) => c.ownedSize > 0).toList();
        items.sort((a, b) => b.ownedSize - a.ownedSize);
        _tree = new VirtualTreeElement(
            _createOwnership, _updateOwnership, _getChildrenOwnership,
            items: items, queue: _r.queue);
        _tree!.expand(_snapshotA!.root);
        final text = 'An object X is said to "own" object Y if X is the only '
            'object that references Y, or X owns the only object that '
            'references Y. In particular, objects "own" the space of any '
            'unshared lists or maps they reference.';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.ownershipTableDiff:
        final items = SnapshotClassDiff.from(_snapshotA!, _snapshotB!);
        items.sort((a, b) => b.ownedSizeB - a.ownedSizeB);
        items.sort((a, b) => b.ownedSizeA - a.ownedSizeA);
        items.sort((a, b) => b.ownedSizeDiff - a.ownedSizeDiff);
        _tree = new VirtualTreeElement(_createOwnershipDiff,
            _updateOwnershipDiff, _getChildrenOwnershipDiff,
            items: items, queue: _r.queue);
        _tree!.expand(_snapshotA!.root);
        final text = 'An object X is said to "own" object Y if X is the only '
            'object that references Y, or X owns the only object that '
            'references Y. In particular, objects "own" the space of any '
            'unshared lists or maps they reference.';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.ownershipTreeMap:
        _createTreeMap(
            report, new ClassesOwnershipTreeMap(this, _snapshotA!), null);
        break;
      case HeapSnapshotTreeMode.ownershipTreeMapDiff:
        final items = SnapshotClassDiff.from(_snapshotA!, _snapshotB!);
        _createTreeMap(
            report, new ClassesOwnershipDiffTreeMap(this, items), null);
        break;
      case HeapSnapshotTreeMode.successors:
        if (selection == null) {
          selection = List.from(_snapshotA!.root.objects);
        }
        _tree = new VirtualTreeElement(
            _createSuccessor, _updateSuccessor, _getChildrenSuccessor,
            items: selection!, queue: _r.queue);
        if (selection!.length == 1) {
          _tree!.expand(selection!.first);
        }
        final text = '';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.predecessors:
        if (selection == null) {
          selection = List.from(_snapshotA!.root.objects);
        }
        _tree = new VirtualTreeElement(
            _createPredecessor, _updatePredecessor, _getChildrenPredecessor,
            items: selection!, queue: _r.queue);
        if (selection!.length == 1) {
          _tree!.expand(selection!.first);
        }
        final text = '';
        report.addAll([
          new HTMLDivElement()
            ..className = 'content-centered-big explanation'
            ..textContent = text,
          _tree!.element
        ]);
        break;
      case HeapSnapshotTreeMode.classesTable:
        final items = _snapshotA!.classes.toList();
        items.sort((a, b) => b.shallowSize - a.shallowSize);
        _tree = new VirtualTreeElement(
            _createClass, _updateClass, _getChildrenClass,
            items: items, queue: _r.queue);
        report.add(_tree!.element);
        break;
      case HeapSnapshotTreeMode.classesTableDiff:
        final items = SnapshotClassDiff.from(_snapshotA!, _snapshotB!);
        items.sort((a, b) => b.shallowSizeB - a.shallowSizeB);
        items.sort((a, b) => b.shallowSizeA - a.shallowSizeA);
        items.sort((a, b) => b.shallowSizeDiff - a.shallowSizeDiff);
        _tree = new VirtualTreeElement(
            _createClassDiff, _updateClassDiff, _getChildrenClassDiff,
            items: items, queue: _r.queue);
        report.add(_tree!.element);
        break;
      case HeapSnapshotTreeMode.classesTreeMap:
        _createTreeMap(
            report, new ClassesShallowTreeMap(this, _snapshotA!), null);
        break;

      case HeapSnapshotTreeMode.classesTreeMapDiff:
        final items = SnapshotClassDiff.from(_snapshotA!, _snapshotB!);
        _createTreeMap(
            report, new ClassesShallowDiffTreeMap(this, items), null);
        break;
    }
    return report;
  }

  static HTMLElement _createDominator(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap being retained',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size',
        new HTMLSpanElement()..className = 'lines',
        new HTMLButtonElement()
          ..className = 'expander'
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new HTMLSpanElement()..className = 'name',
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[inspect]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[incoming]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[dominator-map]",
      ]);
  }

  static HTMLElement _createSuccessor(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()..className = 'lines',
        new HTMLButtonElement()
          ..className = 'expander'
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size',
        new HTMLSpanElement()
          ..className = 'edge'
          ..title = 'name of outgoing field',
        new HTMLSpanElement()..className = 'name',
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[incoming]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[dominator-tree]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[dominator-map]",
      ]);
  }

  static HTMLElement _createPredecessor(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()..className = 'lines',
        new HTMLButtonElement()
          ..className = 'expander'
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size',
        new HTMLSpanElement()
          ..className = 'edge'
          ..title = 'name of incoming field',
        new HTMLSpanElement()..className = 'name',
        new HTMLSpanElement()
          ..className = 'link'
          ..textContent = "[inspect]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[dominator-tree]",
        new HTMLAnchorElement()
          ..className = 'link'
          ..textContent = "[dominator-map]",
      ]);
  }

  static HTMLElement _createMergedDominator(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap being retained',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size',
        new HTMLSpanElement()..className = 'lines',
        new HTMLButtonElement()
          ..className = 'expander'
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static HTMLElement _createMergedDominatorDiff(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap being retained',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size A',
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap being retained',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size B',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'retained size change',
        new HTMLSpanElement()..className = 'lines',
        new HTMLButtonElement()
          ..className = 'expander'
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static HTMLElement _createOwnership(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap owned',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'owned size',
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static HTMLElement _createOwnershipDiff(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap owned A',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'owned size A',
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap owned B',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'owned size B',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'owned size change',
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static HTMLElement _createClass(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'percentage'
          ..title = 'percentage of heap owned',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'shallow size',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'instance count',
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static HTMLElement _createClassDiff(toggle) {
    return new HTMLDivElement()
      ..className = 'tree-item'
      ..appendChildren(<HTMLElement>[
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'shallow size A',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'instance count A',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'shallow size B',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'instance count B',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'shallow size diff',
        new HTMLSpanElement()
          ..className = 'size'
          ..title = 'instance count diff',
        new HTMLSpanElement()..className = 'name'
      ]);
  }

  static const int kMaxChildren = 100;
  static const int kMinRetainedSize = 4096;

  static Iterable _getChildrenDominator(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    final list = node.children
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list.take(kMaxChildren).toList();
  }

  static Iterable _getChildrenSuccessor(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    return node.successors.toList();
  }

  static Iterable _getChildrenPredecessor(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    return node.predecessors.take(kMaxChildren).toList();
  }

  static Iterable _getChildrenMergedDominator(nodeDynamic) {
    SnapshotMergedDominator node = nodeDynamic;
    final list = node.children
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list.take(kMaxChildren).toList();
  }

  static Iterable _getChildrenMergedDominatorDiff(nodeDynamic) {
    MergedDominatorDiff node = nodeDynamic;
    final list = node.children!
        .where((child) =>
            child.retainedSizeA >= kMinRetainedSize ||
            child.retainedSizeB >= kMinRetainedSize)
        .toList();
    list.sort((a, b) => b.retainedSizeDiff - a.retainedSizeDiff);
    return list.take(kMaxChildren).toList();
  }

  static Iterable _getChildrenOwnership(item) {
    return const [];
  }

  static Iterable _getChildrenOwnershipDiff(item) {
    return const [];
  }

  static Iterable _getChildrenClass(item) {
    return const [];
  }

  static Iterable _getChildrenClassDiff(item) {
    return const [];
  }

  void _updateDominator(HTMLElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(
            node.retainedSize * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSize);
    _updateLines(element.children.item(2) as HTMLElement, depth);
    if (_getChildrenDominator(node).isNotEmpty) {
      (element.children.item(3) as HTMLElement).textContent =
          _tree!.isExpanded(node) ? '▼' : '►';
    } else {
      (element.children.item(3) as HTMLElement).textContent = '';
    }
    (element.children.item(4) as HTMLElement).textContent = node.description;
    (element.children.item(5) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.successors;
      _r.dirty();
    });
    (element.children.item(6) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.predecessors;
      _r.dirty();
    });
    (element.children.item(7) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updateSuccessor(HTMLElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    _updateLines(element.children.item(0) as HTMLElement, depth);
    if (_getChildrenSuccessor(node).isNotEmpty) {
      (element.children.item(1) as HTMLElement).textContent =
          _tree!.isExpanded(node) ? '▼' : '►';
    } else {
      (element.children.item(1) as HTMLElement).textContent = '';
    }
    (element.children.item(2) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSize);
    (element.children.item(3) as HTMLElement).textContent = node.label;
    (element.children.item(4) as HTMLElement).textContent = node.description;
    (element.children.item(5) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.predecessors;
      _r.dirty();
    });
    (element.children.item(6) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.dominatorTree;
      _r.dirty();
    });
    (element.children.item(7) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updatePredecessor(HTMLElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    _updateLines(element.children.item(0) as HTMLElement, depth);
    if (_getChildrenSuccessor(node).isNotEmpty) {
      (element.children.item(1) as HTMLElement).textContent =
          _tree!.isExpanded(node) ? '▼' : '►';
    } else {
      (element.children.item(1) as HTMLElement).textContent = '';
    }
    (element.children.item(2) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSize);
    (element.children.item(3) as HTMLElement).textContent = node.label;
    (element.children.item(4) as HTMLElement).textContent = node.description;
    (element.children.item(5) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.successors;
      _r.dirty();
    });
    (element.children.item(6) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.dominatorTree;
      _r.dirty();
    });
    (element.children.item(7) as HTMLElement).onClick.listen((_) {
      selection = List.from(node.objects);
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updateMergedDominator(HTMLElement element, nodeDynamic, int depth) {
    SnapshotMergedDominator node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(
            node.retainedSize * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSize);
    _updateLines(element.children.item(2) as HTMLElement, depth);
    if (_getChildrenMergedDominator(node).isNotEmpty) {
      (element.children.item(3) as HTMLElement).textContent =
          _tree!.isExpanded(node) ? '▼' : '►';
    } else {
      (element.children.item(3) as HTMLElement).textContent = '';
    }
    (element.children.item(4) as HTMLElement)
      ..textContent = '${node.instanceCount} instances of ${node.klass.name}';
  }

  void _updateMergedDominatorDiff(HTMLElement element, nodeDynamic, int depth) {
    MergedDominatorDiff node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(
            node.retainedSizeA * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSizeA);
    (element.children.item(2) as HTMLElement).textContent =
        Utils.formatPercentNormalized(
            node.retainedSizeB * 1.0 / _snapshotB!.size);
    (element.children.item(3) as HTMLElement).textContent =
        Utils.formatSize(node.retainedSizeB);
    (element.children.item(4) as HTMLElement).textContent =
        (node.retainedSizeDiff > 0 ? '+' : '') +
            Utils.formatSize(node.retainedSizeDiff);
    (element.children.item(4) as HTMLElement).style.color =
        node.retainedSizeDiff > 0 ? "red" : "green";
    _updateLines(element.children.item(5) as HTMLElement, depth);
    if (_getChildrenMergedDominatorDiff(node).isNotEmpty) {
      (element.children.item(6) as HTMLElement).textContent =
          _tree!.isExpanded(node) ? '▼' : '►';
    } else {
      (element.children.item(6) as HTMLElement).textContent = '';
    }
    (element.children.item(7) as HTMLElement)
      ..textContent =
          '${node.instanceCountA} → ${node.instanceCountB} instances of ${node.name}';
  }

  void _updateOwnership(HTMLElement element, nodeDynamic, int depth) {
    SnapshotClass node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(node.ownedSize * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.ownedSize);
    (element.children.item(2) as HTMLElement).textContent = node.name;
  }

  void _updateOwnershipDiff(HTMLElement element, nodeDynamic, int depth) {
    SnapshotClassDiff node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(node.ownedSizeA * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.ownedSizeA);
    (element.children.item(2) as HTMLElement).textContent =
        Utils.formatPercentNormalized(node.ownedSizeB * 1.0 / _snapshotB!.size);
    (element.children.item(3) as HTMLElement).textContent =
        Utils.formatSize(node.ownedSizeB);
    (element.children.item(4) as HTMLElement).textContent =
        (node.ownedSizeDiff > 0 ? "+" : "") +
            Utils.formatSize(node.ownedSizeDiff);
    (element.children.item(4) as HTMLElement).style.color =
        node.ownedSizeDiff > 0 ? "red" : "green";
    (element.children.item(5) as HTMLElement).textContent = node.name;
  }

  void _updateClass(HTMLElement element, nodeDynamic, int depth) {
    SnapshotClass node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatPercentNormalized(
            node.shallowSize * 1.0 / _snapshotA!.size);
    (element.children.item(1) as HTMLElement).textContent =
        Utils.formatSize(node.shallowSize);
    (element.children.item(2) as HTMLElement).textContent =
        node.instanceCount.toString();
    (element.children.item(3) as HTMLElement).textContent = node.name;
  }

  void _updateClassDiff(HTMLElement element, nodeDynamic, int depth) {
    SnapshotClassDiff node = nodeDynamic;
    (element.children.item(0) as HTMLElement).textContent =
        Utils.formatSize(node.shallowSizeA);
    (element.children.item(1) as HTMLElement).textContent =
        node.instanceCountA.toString();
    (element.children.item(2) as HTMLElement).textContent =
        Utils.formatSize(node.shallowSizeB);
    (element.children.item(3) as HTMLElement).textContent =
        node.instanceCountB.toString();
    (element.children.item(4) as HTMLElement).textContent =
        (node.shallowSizeDiff > 0 ? "+" : "") +
            Utils.formatSize(node.shallowSizeDiff);
    (element.children.item(4) as HTMLElement).style.color =
        node.shallowSizeDiff > 0 ? "red" : "green";
    (element.children.item(5) as HTMLElement).textContent =
        (node.instanceCountDiff > 0 ? "+" : "") +
            node.instanceCountDiff.toString();
    (element.children.item(5) as HTMLElement).style.color =
        node.instanceCountDiff > 0 ? "red" : "green";
    (element.children.item(6) as HTMLElement).textContent = node.name;
  }

  static _updateLines(HTMLElement element, int n) {
    n = Math.max(0, n);
    while (element.childNodes.length > n) {
      element
          .removeChild(element.childNodes.item(element.childNodes.length - 1)!);
    }
    while (element.childNodes.length < n) {
      element.appendChild(new HTMLSpanElement());
    }
  }

  static String modeToString(HeapSnapshotTreeMode mode) {
    switch (mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        return 'Dominators (tree)';
      case HeapSnapshotTreeMode.dominatorTreeMap:
        return 'Dominators (treemap)';
      case HeapSnapshotTreeMode.mergedDominatorTree:
      case HeapSnapshotTreeMode.mergedDominatorTreeDiff:
        return 'Dominators (tree, siblings merged by class)';
      case HeapSnapshotTreeMode.mergedDominatorTreeMap:
      case HeapSnapshotTreeMode.mergedDominatorTreeMapDiff:
        return 'Dominators (treemap, siblings merged by class)';
      case HeapSnapshotTreeMode.ownershipTable:
      case HeapSnapshotTreeMode.ownershipTableDiff:
        return 'Ownership (table)';
      case HeapSnapshotTreeMode.ownershipTreeMap:
      case HeapSnapshotTreeMode.ownershipTreeMapDiff:
        return 'Ownership (treemap)';
      case HeapSnapshotTreeMode.classesTable:
      case HeapSnapshotTreeMode.classesTableDiff:
        return 'Classes (table)';
      case HeapSnapshotTreeMode.classesTreeMap:
      case HeapSnapshotTreeMode.classesTreeMapDiff:
        return 'Classes (treemap)';
      case HeapSnapshotTreeMode.successors:
        return 'Successors / outgoing references';
      case HeapSnapshotTreeMode.predecessors:
        return 'Predecessors / incoming references';
    }
  }

  List<HTMLElement> _createModeSelect() {
    var modes = _snapshotA == _snapshotB ? viewModes : diffModes;
    if (!modes.contains(_mode)) {
      _mode = modes[0];
      _r.dirty();
    }
    final s = HTMLSelectElement()
      ..className = 'analysis-select'
      ..value = modeToString(_mode)
      ..appendChildren(modes.map((mode) => HTMLOptionElement()
        ..value = modeToString(mode)
        ..selected = _mode == mode
        ..textContent = modeToString(mode)));
    return [
      s
        ..onChange.listen((_) {
          _mode = modes[s.selectedIndex];
          _r.dirty();
        })
    ];
  }

  String snapshotToString(snapshot) {
    if (snapshot == null) return "None";
    return snapshot.description +
        " " +
        Utils.formatSize(snapshot.capacity + snapshot.externalSize);
  }

  List<HTMLElement> _createSnapshotSelectA() {
    final s = new HTMLSelectElement()
      ..className = 'analysis-select'
      ..value = snapshotToString(_snapshotA)
      ..appendChildren(_loadedSnapshots.map((snapshot) {
        return HTMLOptionElement()
          ..value = snapshotToString(snapshot)
          ..selected = _snapshotA == snapshot
          ..textContent = snapshotToString(snapshot);
      }));
    return [
      s
        ..onChange.listen((_) {
          _snapshotA = _loadedSnapshots[s.selectedIndex];
          selection = null;
          mergedSelection = null;
          mergedDiffSelection = null;
          _r.dirty();
        })
    ];
  }

  List<HTMLElement> _createSnapshotSelectB() {
    var s;
    return [
      s = new HTMLSelectElement()
        ..className = 'analysis-select'
        ..value = snapshotToString(_snapshotB)
        ..appendChildren(_loadedSnapshots.map((snapshot) => HTMLOptionElement()
          ..value = snapshotToString(snapshot)
          ..selected = _snapshotB == snapshot
          ..textContent = snapshotToString(snapshot)))
        ..onChange.listen((_) {
          _snapshotB = _loadedSnapshots[s.selectedIndex];
          selection = null;
          mergedSelection = null;
          mergedDiffSelection = null;
          _r.dirty();
        })
    ];
  }
}
