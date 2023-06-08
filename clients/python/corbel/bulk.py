import json
from typing import Any, Dict, Iterable, List

class StreamingBulkIndexer:
    """Helper formatting and batching document records into Elasticsearch-compatible NDJSON streams."""

    def __init__(self, chunk_size: int = 500) -> None:
        self.chunk_size = chunk_size

    def format_ndjson(self, actions: Iterable[Dict[str, Any]]) -> str:
        lines: List[str] = []
        for item in actions:
            op_type = item.get("_op_type", "index")
            index_name = item.get("_index")
            doc_id = item.get("_id")

            meta: Dict[str, Any] = {}
            if index_name: meta["_index"] = index_name
            if doc_id is not None: meta["_id"] = doc_id

            lines.append(json.dumps({op_type: meta}))
            if op_type != "delete":
                source = item.get("_source", {})
                lines.append(json.dumps(source))

        return "\n".join(lines) + "\n"
