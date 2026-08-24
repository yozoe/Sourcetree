import 'package:flutter_test/flutter_test.dart';
import 'package:git_desktop/src/presentation/presentation.dart';

void main() {
  test('reserves the left lane for a detached HEAD inside branch history', () {
    const base = 'base';
    final graph = buildCommitGraph(
      const [
        CommitGraphNode(oid: 'main-tip', parents: ['main-middle']),
        CommitGraphNode(oid: 'main-middle', parents: ['main-fork']),
        CommitGraphNode(oid: 'main-fork', parents: [base]),
        CommitGraphNode(oid: 'conflict-tip', parents: [base]),
        CommitGraphNode(oid: base),
      ],
      headId: base,
      isDetachedHead: true,
    );

    expect(graph.map((row) => row.lane), [1, 1, 1, 2, 0]);
    expect(graph.map((row) => row.colorIndex), [0, 0, 0, 1, 2]);
    expect(graph, everyElement(isA<CommitGraphViewData>()));
    expect(graph.every((row) => row.hasReservedHeadLane), isTrue);
    expect(graph[0].activeLanes, [1]);
    expect(graph[0].previousLanes, isEmpty);
    expect(graph[1].activeLanes, [1]);
    expect(graph[1].previousLanes, [1]);
    expect(graph[2].parentLanes, [1]);
    expect(graph[2].activeLaneDestinations, [1]);
    expect(graph[3].activeLanes, [1, 2]);
    expect(graph[3].activeLaneDestinations, [1, 2]);
    expect(graph[3].previousLanes, [1]);
    expect(graph[3].parentLanes, [2]);
    expect(graph[4].incomingLanes, [1, 2]);
    expect(graph[4].previousLanes, isEmpty);

    final firstRowWithWorkspace = graph.first.copyWith(
      hasPreviousNode: true,
      additionalPreviousLanes: const {0},
    );
    expect(firstRowWithWorkspace.previousLanes, [0]);
    expect(firstRowWithWorkspace.activeLanes, isNot(contains(0)));
  });

  test('keeps an attached current branch on the normal left lane', () {
    final graph = buildCommitGraph(const [
      CommitGraphNode(oid: 'tip', parents: ['base']),
      CommitGraphNode(oid: 'base'),
    ], headId: 'tip');

    expect(graph.map((row) => row.lane), [0, 0]);
    expect(graph[0].previousLanes, isEmpty);
    expect(graph[1].previousLanes, [0]);
    expect(graph.every((row) => !row.hasReservedHeadLane), isTrue);

    final firstRowWithWorkspace = graph.first.copyWith(
      hasPreviousNode: true,
      additionalPreviousLanes: const {0},
    );
    expect(firstRowWithWorkspace.previousLanes, [0]);
  });

  test('does not reserve a detached lane for an attached ancestor branch', () {
    final graph = buildCommitGraph(
      const [
        CommitGraphNode(oid: 'feature', parents: ['base']),
        CommitGraphNode(oid: 'base', parents: ['root']),
        CommitGraphNode(oid: 'root'),
      ],
      headId: 'base',
      isDetachedHead: false,
    );

    expect(graph.every((row) => !row.hasReservedHeadLane), isTrue);
    expect(graph.map((row) => row.lane), [1, 0, 0]);
    expect(graph.map((row) => row.colorIndex), [1, 0, 0]);
    expect(graph[1].incomingLanes, [1]);
  });

  test('keeps the current branch blue when a side branch sorts first', () {
    final graph = buildCommitGraph(const [
      CommitGraphNode(oid: 'newer-side', parents: ['base']),
      CommitGraphNode(oid: 'main-tip', parents: ['base']),
      CommitGraphNode(oid: 'base'),
    ], headId: 'main-tip');

    expect(graph.map((row) => row.lane), [1, 0, 0]);
    expect(graph.map((row) => row.colorIndex), [1, 0, 0]);
    expect(graph[2].incomingLanes, [1]);
  });

  test('keeps three sibling branches on distinct lanes', () {
    final graph = buildCommitGraph(
      const [
        CommitGraphNode(oid: 'main', parents: ['base']),
        CommitGraphNode(oid: 'red', parents: ['base']),
        CommitGraphNode(oid: 'green', parents: ['base']),
        CommitGraphNode(oid: 'base'),
      ],
      headId: 'base',
      isDetachedHead: true,
    );

    expect(graph.map((row) => row.lane), [1, 2, 3, 0]);
    expect(graph[3].incomingLanes, [1, 2, 3]);
    expect(graph[3].incomingLanes.toSet(), hasLength(3));
  });

  test('compacts nested merge lanes when active paths change', () {
    final graph = buildCommitGraph(const [
      CommitGraphNode(
        oid: 'merge-ui',
        parents: ['merge-foundation', 'ui-merge'],
      ),
      CommitGraphNode(oid: 'ui-merge', parents: ['ui', 'docs']),
      CommitGraphNode(oid: 'docs', parents: ['foundation-base']),
      CommitGraphNode(oid: 'ui', parents: ['foundation-base']),
      CommitGraphNode(
        oid: 'merge-foundation',
        parents: ['old-main', 'foundation-merge'],
      ),
      CommitGraphNode(
        oid: 'foundation-merge',
        parents: ['foundation-base', 'api-2'],
      ),
      CommitGraphNode(oid: 'api-2', parents: ['api-1']),
      CommitGraphNode(oid: 'api-1', parents: ['foundation-base']),
      CommitGraphNode(oid: 'foundation-base', parents: ['old-main']),
      CommitGraphNode(oid: 'old-main'),
    ], headId: 'merge-ui');

    expect(graph.map((row) => row.lane), [0, 1, 2, 1, 0, 1, 2, 2, 1, 0]);
    expect(graph[0].parentLanes, [0, 1]);
    expect(graph[1].parentLanes, [1, 2]);
    expect(graph[4].parentLanes, [0, 1]);
    expect(graph[5].parentLanes, [1, 2]);
    expect(graph[8].incomingLanes, isNotEmpty);
    expect(graph[9].incomingLanes, isNotEmpty);
  });

  test('compacts changed lanes around an internal detached HEAD', () {
    final graph = buildCommitGraph(
      const [
        CommitGraphNode(
          oid: 'merge-ui',
          parents: ['merge-foundation', 'ui-merge'],
        ),
        CommitGraphNode(oid: 'ui-merge', parents: ['ui', 'docs']),
        CommitGraphNode(oid: 'docs', parents: ['foundation-base']),
        CommitGraphNode(oid: 'ui', parents: ['foundation-base']),
        CommitGraphNode(
          oid: 'merge-foundation',
          parents: ['old-main', 'foundation-merge'],
        ),
        CommitGraphNode(
          oid: 'foundation-merge',
          parents: ['foundation-base', 'api-2'],
        ),
        CommitGraphNode(oid: 'api-2', parents: ['api-1']),
        CommitGraphNode(oid: 'api-1', parents: ['foundation-base']),
        CommitGraphNode(oid: 'foundation-base', parents: ['old-main']),
        CommitGraphNode(oid: 'old-main'),
      ],
      headId: 'foundation-base',
      isDetachedHead: true,
    );

    expect(graph.map((row) => row.lane), [1, 2, 3, 2, 1, 2, 3, 3, 0, 0]);
    expect(graph[0].parentLanes, [1, 2]);
    expect(graph[1].parentLanes, [2, 3]);
    expect(graph[4].parentLanes, [1, 2]);
    expect(graph[5].parentLanes, [2, 3]);
    expect(graph[8].incomingLanes, isNotEmpty);
    expect(graph[9].incomingLanes, isNotEmpty);
    expect(graph.every((row) => row.hasReservedHeadLane), isTrue);
  });

  test('shifts only lanes to the right when an active path ends', () {
    final graph = buildCommitGraph(const [
      CommitGraphNode(oid: 'merge', parents: ['main', 'side-one', 'side-two']),
      CommitGraphNode(oid: 'side-one'),
      CommitGraphNode(oid: 'side-two'),
      CommitGraphNode(oid: 'main'),
    ], headId: 'merge');

    expect(graph[0].parentLanes, [0, 1, 2]);
    expect(graph[1].activeLanes, [0, 1, 2]);
    expect(graph[1].activeLaneDestinations, [0, isNull, 1]);
    expect(graph[2].lane, 1);
    expect(graph[2].activeLanes, [0, 1]);
  });

  test('folds overflow paths into the eighth visible lane', () {
    final tips = List<String>.generate(9, (index) => 'tip-$index');
    final graph = buildCommitGraph([
      for (final tip in tips)
        CommitGraphNode(oid: tip, parents: const ['base']),
      const CommitGraphNode(oid: 'base'),
    ], headId: tips.first);

    expect(graph[8].lane, commitGraphMaximumVisibleLanes - 1);
    expect(
      graph.expand(
        (row) => <int>[
          row.lane,
          ...row.activeLanes,
          ...row.incomingLanes,
          ...row.parentLanes,
          ...row.activeLaneDestinations.whereType<int>(),
        ],
      ),
      everyElement(lessThan(commitGraphMaximumVisibleLanes)),
    );
    expect(graph.last.incomingLanes, contains(7));
  });
}
