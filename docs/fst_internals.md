# Finite State Transducer (FST) Theory and Algorithms

Corbel uses minimal acyclic finite-state transducers (FST) to represent segment term dictionaries. An FST maps input byte sequences (strings) to numerical outputs (file offsets into postings lists) while sharing both common prefixes and common suffixes.

---

## 1. Algorithmic Background

Traditional prefix tries only share leading prefixes ($O(N)$ state explosion for dictionary terms). Directed Acyclic Word Graphs (DAWG) and minimal FSTs (Daciuk et al., 2000) identify and merge equivalent right languages (suffixes), producing a minimal deterministic automaton.

### Key Characteristics in Corbel:
- **Input Alphabet**: Bytes ($\Sigma = [0..255]$).
- **Outputs**: Integer monoid $(\mathbb{N}_0, +, 0)$ where outputs are distributed along transitions and accumulated along paths.
- **Ordered Construction**: Terms must be presented to `FstBuilder` in strict lexicographical order.

---

## 2. Online Minimal Automata Compilation

The compilation algorithm uses a frontier stack (`_frontier`) representing unfinalized states for the current prefix, and an LRU state registry (`_dedupCache`) mapping state signatures to canonical states.

```
Input: "cat", output=10
Input: "car", output=20
Input: "cars", output=35
```

When inserting string $W_{k+1}$ after $W_k$:
1. Compute the longest common prefix (LCP) between $W_k$ and $W_{k+1}$.
2. Freeze states on the frontier beyond the LCP, from right to left (deepest to shallowest).
3. For each frozen state, query the dedup cache:
   - If an identical state exists (same transitions, targets, outputs, and finality), point the incoming transition to the existing canonical state.
   - Otherwise, insert the new state into the cache.
4. Push new mutable states onto the frontier for characters in $W_{k+1}$ beyond the LCP.
5. Distribute outputs along transitions.

---

## 3. Levenshtein Automata Intersection

For fuzzy search queries within edit distance $K \in \{1, 2\}$, Corbel intersects the FST with a parametric Levenshtein automaton:

1. Rather than checking Levenshtein distance against every term sequentially ($O(N \cdot L)$), Corbel traverses the FST graph directly.
2. At each FST node, a dynamic programming vector representing edit distances for the search target is maintained.
3. If the minimum edit distance across all columns exceeds $K$, the entire subtree is pruned ($O(1)$ branch cutoff).
4. When a final state is reached with distance $\le K$, the accumulated term string and postings offset are emitted.

This guarantees sub-millisecond fuzzy lookups across millions of terms.
