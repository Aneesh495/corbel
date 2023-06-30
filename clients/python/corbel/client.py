import json
import urllib.request
import urllib.error
from typing import Any, Dict, List, Optional, Union
from .bulk import StreamingBulkIndexer

class CorbelClient:
    """Official Python SDK client communicating with Corbel Search Engine cluster nodes."""

    def __init__(self, base_url: str = "http://localhost:9200", timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.bulk_helper = StreamingBulkIndexer()

    def _request(
        self,
        method: str,
        path: str,
        data: Optional[Union[Dict[str, Any], str]] = None,
        content_type: str = "application/json",
    ) -> Dict[str, Any]:
        url = f"{self.base_url}/{path.lstrip('/')}"
        encoded_data = None

        if data is not None:
            if isinstance(data, dict):
                encoded_data = json.dumps(data).encode("utf-8")
            elif isinstance(data, str):
                encoded_data = data.encode("utf-8")

        req = urllib.request.Request(
            url,
            data=encoded_data,
            headers={
                "Content-Type": content_type,
                "Accept": "application/json",
            },
            method=method.upper(),
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body) if body.strip() else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8")
            try:
                err_json = json.loads(err_body)
                raise RuntimeError(f"Corbel HTTP {e.code}: {err_json}") from e
            except json.JSONDecodeError:
                raise RuntimeError(f"Corbel HTTP {e.code}: {err_body}") from e

    def ping(self) -> Dict[str, Any]:
        return self._request("GET", "/")

    def cluster_health(self) -> Dict[str, Any]:
        return self._request("GET", "/_cluster/health")

    def metrics(self) -> Dict[str, Any]:
        return self._request("GET", "/_metrics")

    def list_indices(self) -> List[Dict[str, Any]]:
        res = self._request("GET", "/_cat/indices")
        return res.get("indices", [])

    def create_index(self, index: str, schema: Dict[str, Any]) -> Dict[str, Any]:
        return self._request("PUT", f"/{index}", data=schema)

    def drop_index(self, index: str) -> Dict[str, Any]:
        return self._request("DELETE", f"/{index}")

    def index(
        self,
        index: str,
        document: Dict[str, Any],
        doc_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        if doc_id:
            return self._request("PUT", f"/{index}/_doc/{doc_id}", data=document)
        return self._request("POST", f"/{index}/_doc", data=document)

    def delete(self, index: str, doc_id: str) -> Dict[str, Any]:
        return self._request("DELETE", f"/{index}/_doc/{doc_id}")

    def refresh(self, index: str) -> Dict[str, Any]:
        return self._request("POST", f"/{index}/_refresh")

    def search(
        self,
        index: str,
        query: Union[str, Dict[str, Any]],
        size: int = 10,
    ) -> Dict[str, Any]:
        payload: Dict[str, Any] = {"size": size}
        if isinstance(query, str):
            payload["query"] = query
        else:
            payload["query_ast"] = query
        return self._request("POST", f"/{index}/_search", data=payload)

    def suggest(
        self,
        index: str,
        field: str,
        prefix: str,
        size: int = 5,
        fuzzy: bool = False,
    ) -> Dict[str, Any]:
        payload = {
            "field": field,
            "prefix": prefix,
            "size": size,
            "fuzzy": fuzzy,
        }
        return self._request("POST", f"/{index}/_suggest", data=payload)

    def spellcheck(
        self,
        index: str,
        text: str,
        max_edit_distance: int = 2,
    ) -> Dict[str, Any]:
        payload = {
            "text": text,
            "max_edit_distance": max_edit_distance,
        }
        return self._request("POST", f"/{index}/_spellcheck", data=payload)

    def bulk(self, actions: List[Dict[str, Any]]) -> Dict[str, Any]:
        ndjson_body = self.bulk_helper.format_ndjson(actions)
        return self._request(
            "POST",
            "/_bulk",
            data=ndjson_body,
            content_type="application/x-ndjson",
        )
