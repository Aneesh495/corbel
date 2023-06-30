import json
from typing import Any, Dict, Iterable, List, Optional

class StreamingBulkIndexer:
    """Helper formatting and batching document records into Elasticsearch-compatible NDJSON streams."""

    def __init__(self, chunk_size: int = 500) -> None:
        self.chunk_size = chunk_size

    def chunk(self, items: Iterable[Any], batch_size: Optional[int] = None) -> Iterable[List[Any]]:
        """Yields successive slices of [items] of length [batch_size]."""
        size = batch_size or self.chunk_size
        batch: List[Any] = []
        for item in items:
            batch.append(item)
            if len(batch) >= size:
                yield batch
                batch = []
        if batch:
            yield batch

    def format_ndjson(self, actions: Iterable[Dict[str, Any]]) -> str:
        """Serializes action dictionaries into two-line NDJSON format for the _bulk API."""
        lines: List[str] = []
        for item in actions:
            op_type = item.get("_op_type") or item.get("action") or "index"
            index_name = item.get("_index") or item.get("index")
            doc_id = item.get("_id") or item.get("id")

            meta: Dict[str, Any] = {}
            if index_name: meta["_index"] = index_name
            if doc_id is not None: meta["_id"] = str(doc_id)

            lines.append(json.dumps({op_type: meta}))
            if op_type != "delete":
                source = item.get("_source") or item.get("document") or {}
                lines.append(json.dumps(source))

        return "\n".join(lines) + "\n"
