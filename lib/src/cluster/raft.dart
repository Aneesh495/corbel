import 'dart:math' as math;

/// Node roles in the Raft consensus protocol.
enum RaftRole {
  follower,
  candidate,
  leader,
}

/// Single replicated log entry in the consensus log.
class RaftLogEntry {
  final int term;
  final int index;
  final String command;
  final Map<String, dynamic> payload;

  const RaftLogEntry({
    required this.term,
    required this.index,
    required this.command,
    this.payload = const {},
  });

  Map<String, dynamic> toJson() => {
        'term': term,
        'index': index,
        'command': command,
        'payload': payload,
      };

  factory RaftLogEntry.fromJson(Map<String, dynamic> json) {
    return RaftLogEntry(
      term: json['term'] as int,
      index: json['index'] as int,
      command: json['command'] as String,
      payload: json['payload'] as Map<String, dynamic>? ?? const {},
    );
  }
}

/// RequestVote RPC arguments sent by candidate nodes during leader election.
class RequestVoteArgs {
  final int term;
  final String candidateId;
  final int lastLogIndex;
  final int lastLogTerm;

  const RequestVoteArgs({
    required this.term,
    required this.candidateId,
    required this.lastLogIndex,
    required this.lastLogTerm,
  });
}

/// RequestVote RPC reply.
class RequestVoteReply {
  final int term;
  final bool voteGranted;

  const RequestVoteReply({
    required this.term,
    required this.voteGranted,
  });
}

/// AppendEntries RPC arguments sent by leader for log replication and heartbeats.
class AppendEntriesArgs {
  final int term;
  final String leaderId;
  final int prevLogIndex;
  final int prevLogTerm;
  final List<RaftLogEntry> entries;
  final int leaderCommit;

  const AppendEntriesArgs({
    required this.term,
    required this.leaderId,
    required this.prevLogIndex,
    required this.prevLogTerm,
    this.entries = const [],
    required this.leaderCommit,
  });
}

/// AppendEntries RPC reply.
class AppendEntriesReply {
  final int term;
  final bool success;
  final int matchIndex;

  const AppendEntriesReply({
    required this.term,
    required this.success,
    required this.matchIndex,
  });
}

/// Distributed Raft consensus state machine governing cluster coordination.
/// Reference: Diego Ongaro, John Ousterhout, "In Search of an Understandable Consensus Algorithm", USENIX ATC 2014.
class RaftNode {
  final String nodeId;
  final List<String> peers;

  RaftRole _role = RaftRole.follower;
  int _currentTerm = 0;
  String? _votedFor;
  final List<RaftLogEntry> _log = [];

  int _commitIndex = 0;
  int _lastApplied = 0;

  // Leader-specific state
  final Map<String, int> _nextIndex = {};
  final Map<String, int> _matchIndex = {};

  int _electionTicks = 0;
  final int electionTimeoutTicks;
  final int heartbeatIntervalTicks;

  RaftNode({
    required this.nodeId,
    required this.peers,
    this.electionTimeoutTicks = 10,
    this.heartbeatIntervalTicks = 3,
  });

  RaftRole get role => _role;
  int get currentTerm => _currentTerm;
  String? get votedFor => _votedFor;
  int get commitIndex => _commitIndex;
  int get lastApplied => _lastApplied;
  int get logLength => _log.length;

  int get lastLogIndex => _log.isEmpty ? 0 : _log.last.index;
  int get lastLogTerm => _log.isEmpty ? 0 : _log.last.term;

  /// Advances logical cluster clock by one tick.
  void tick() {
    _electionTicks++;

    if (_role == RaftRole.leader) {
      if (_electionTicks >= heartbeatIntervalTicks) {
        _electionTicks = 0;
      }
    } else {
      if (_electionTicks >= electionTimeoutTicks) {
        startElection();
      }
    }
  }

  /// Initiates a new leader election round.
  void startElection() {
    _role = RaftRole.candidate;
    _currentTerm++;
    _votedFor = nodeId;
    _electionTicks = 0;

    var votesGranted = 1; // Vote for self
    final quorum = ((peers.length + 1) ~/ 2) + 1;

    if (votesGranted >= quorum) {
      _becomeLeader();
      return;
    }
  }

  void _becomeLeader() {
    _role = RaftRole.leader;
    for (final peer in peers) {
      _nextIndex[peer] = lastLogIndex + 1;
      _matchIndex[peer] = 0;
    }
  }

  /// Proposes a new command to be appended to the consensus log (Leader only).
  bool propose(String command, Map<String, dynamic> payload) {
    if (_role != RaftRole.leader) return false;

    final newIndex = lastLogIndex + 1;
    final entry = RaftLogEntry(
      term: _currentTerm,
      index: newIndex,
      command: command,
      payload: payload,
    );
    _log.add(entry);
    return true;
  }

  /// Processes RequestVote RPC request from a candidate.
  RequestVoteReply handleRequestVote(RequestVoteArgs args) {
    if (args.term > _currentTerm) {
      _currentTerm = args.term;
      _role = RaftRole.follower;
      _votedFor = null;
    }

    var voteGranted = false;
    final canVote = (_votedFor == null || _votedFor == args.candidateId);
    final isUpToDate = _isLogUpToDate(args.lastLogTerm, args.lastLogIndex);

    if (args.term == _currentTerm && canVote && isUpToDate) {
      voteGranted = true;
      _votedFor = args.candidateId;
      _electionTicks = 0; // Reset election timer upon granting vote
    }

    return RequestVoteReply(
      term: _currentTerm,
      voteGranted: voteGranted,
    );
  }

  bool _isLogUpToDate(int candidateLastTerm, int candidateLastIndex) {
    final myLastTerm = lastLogTerm;
    final myLastIndex = lastLogIndex;

    if (candidateLastTerm != myLastTerm) {
      return candidateLastTerm > myLastTerm;
    }
    return candidateLastIndex >= myLastIndex;
  }

  /// Processes AppendEntries RPC request from a leader.
  AppendEntriesReply handleAppendEntries(AppendEntriesArgs args) {
    if (args.term < _currentTerm) {
      return AppendEntriesReply(
        term: _currentTerm,
        success: false,
        matchIndex: lastLogIndex,
      );
    }

    if (args.term > _currentTerm || _role == RaftRole.candidate) {
      _currentTerm = args.term;
      _role = RaftRole.follower;
      _votedFor = null;
    }

    _electionTicks = 0; // Reset election timer upon heartbeat from valid leader

    // Verify log consistency at prevLogIndex
    if (args.prevLogIndex > 0) {
      if (args.prevLogIndex > _log.length) {
        return AppendEntriesReply(
          term: _currentTerm,
          success: false,
          matchIndex: _log.length,
        );
      }
      final entryAtPrev = _log[args.prevLogIndex - 1];
      if (entryAtPrev.term != args.prevLogTerm) {
        // Log conflict: truncate and reject
        _log.removeRange(args.prevLogIndex - 1, _log.length);
        return AppendEntriesReply(
          term: _currentTerm,
          success: false,
          matchIndex: _log.length,
        );
      }
    }

    // Append new entries not already in log
    for (var i = 0; i < args.entries.length; i++) {
      final entry = args.entries[i];
      final targetIdx = args.prevLogIndex + 1 + i;
      if (targetIdx <= _log.length) {
        if (_log[targetIdx - 1].term != entry.term) {
          _log.removeRange(targetIdx - 1, _log.length);
          _log.add(entry);
        }
      } else {
        _log.add(entry);
      }
    }

    // Update commit index
    if (args.leaderCommit > _commitIndex) {
      _commitIndex = math.min(args.leaderCommit, lastLogIndex);
    }

    return AppendEntriesReply(
      term: _currentTerm,
      success: true,
      matchIndex: lastLogIndex,
    );
  }

  /// Leader update: records AppendEntries response from [peer].
  void handleAppendEntriesResponse(String peer, AppendEntriesReply reply) {
    if (_role != RaftRole.leader) return;

    if (reply.term > _currentTerm) {
      _currentTerm = reply.term;
      _role = RaftRole.follower;
      _votedFor = null;
      return;
    }

    if (reply.success) {
      _nextIndex[peer] = reply.matchIndex + 1;
      _matchIndex[peer] = reply.matchIndex;
      _checkAndUpdateCommitIndex();
    } else {
      // Decrement nextIndex and retry on log mismatch
      final currentNext = _nextIndex[peer] ?? (lastLogIndex + 1);
      _nextIndex[peer] = math.max(1, currentNext - 1);
    }
  }

  void _checkAndUpdateCommitIndex() {
    final matches = [_log.length, ..._matchIndex.values].toList()..sort();
    final quorumIndex = matches[matches.length ~/ 2];

    if (quorumIndex > _commitIndex && quorumIndex <= _log.length) {
      if (_log[quorumIndex - 1].term == _currentTerm) {
        _commitIndex = quorumIndex;
      }
    }
  }

  /// Applies newly committed entries to the local state machine.
  List<RaftLogEntry> applyEntries() {
    final applied = <RaftLogEntry>[];
    while (_lastApplied < _commitIndex) {
      _lastApplied++;
      applied.add(_log[_lastApplied - 1]);
    }
    return applied;
  }
}
