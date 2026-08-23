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
    expect(graph[2].parentLanes, [0]);
    expect(graph[2].activeLaneDestinations, [1]);
    expect(graph[3].activeLanes, [0, 2, 1]);
    expect(graph[3].activeLaneDestinations, [0, 2, 1]);
    expect(graph[3].previousLanes, [1]);
    expect(graph[3].parentLanes, [0]);
    expect(graph[4].incomingLanes, [1, 2]);
    expect(graph[4].previousLanes, [0]);

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
    expect(graph.map((row) => row.lane), [0, 0, 0]);
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
}
