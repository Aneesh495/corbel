/// Identifier for a specific shard partition of an index.
class ShardId {
  final String indexName;
  final int shardIndex;

  const ShardId(this.indexName, this.shardIndex);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShardId &&
          runtimeType == other.runtimeType &&
          indexName == other.indexName &&
          shardIndex == other.shardIndex;

  @override
  int get hashCode => Object.hash(indexName, shardIndex);

  @override
  String toString() => '$indexName#$shardIndex';
}

/// Lifecycle state of a shard instance on a cluster node.
enum ShardState {
  unassigned,
  initializing,
  started,
  relocating,
}

/// Routing descriptor mapping a shard instance to a cluster node.
class ShardRouting {
  final ShardId shardId;
  final String nodeId;
  final bool isPrimary;
  final ShardState state;

  const ShardRouting({
    required this.shardId,
    required this.nodeId,
    required this.isPrimary,
    this.state = ShardState.started,
  });

  bool get isStarted => state == ShardState.started;

  Map<String, dynamic> toJson() => {
        'shard_id': shardId.toString(),
        'node_id': nodeId,
        'is_primary': isPrimary,
        'state': state.name,
      };

  @override
  String toString() =>
      'ShardRouting($shardId, node: $nodeId, primary: $isPrimary, state: ${state.name})';
}

/// Routing table mapping document routing keys to primary and replica shards.
class IndexRoutingTable {
  final String indexName;
  final int numShards;
  final int replicationFactor;

  final Map<int, List<ShardRouting>> _shardMap = {};

  IndexRoutingTable({
    required this.indexName,
    required this.numShards,
    this.replicationFactor = 1,
  }) : assert(numShards > 0, 'Shard count must be positive');

  /// Adds a shard routing entry.
  void addRouting(ShardRouting routing) {
    if (routing.shardId.indexName != indexName) {
      throw ArgumentError(
          'Shard ${routing.shardId} does not belong to index $indexName');
    }
    _shardMap.putIfAbsent(routing.shardId.shardIndex, () => []).add(routing);
  }

  /// Calculates the destination shard index for a given document [routingKey].
  int route(String routingKey) {
    var hash = 0;
    for (var i = 0; i < routingKey.length; i++) {
      hash = (31 * hash + routingKey.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return hash % numShards;
  }

  /// Retrieves the active primary routing for [shardIndex].
  ShardRouting? getPrimaryShard(int shardIndex) {
    final list = _shardMap[shardIndex];
    if (list == null) return null;
    for (final s in list) {
      if (s.isPrimary && s.isStarted) return s;
    }
    return null;
  }

  /// Retrieves all active replicas for [shardIndex].
  List<ShardRouting> getReplicaShards(int shardIndex) {
    final list = _shardMap[shardIndex];
    if (list == null) return const [];
    return list.where((s) => !s.isPrimary && s.isStarted).toList();
  }

  /// All shard entries in this routing table.
  List<ShardRouting> get allShards =>
      _shardMap.values.expand((list) => list).toList();
}
