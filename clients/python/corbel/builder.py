from typing import Any, Dict, List, Optional, Union

class Query:
    """Fluent query builder constructing Corbel AST JSON search specifications."""

    @staticmethod
    def term(field: str, value: Any, boost: float = 1.0) -> Dict[str, Any]:
        return {
            "term": {
                field: {
                    "value": value,
                    "boost": boost,
                }
            }
        }

    @staticmethod
    def match(field: str, query: str, boost: float = 1.0) -> Dict[str, Any]:
        return {
            "match": {
                field: {
                    "query": query,
                    "boost": boost,
                }
            }
        }

    @staticmethod
    def range(
        field: str,
        gt: Optional[Union[int, float]] = None,
        gte: Optional[Union[int, float]] = None,
        lt: Optional[Union[int, float]] = None,
        lte: Optional[Union[int, float]] = None,
        boost: float = 1.0,
    ) -> Dict[str, Any]:
        bounds: Dict[str, Any] = {"boost": boost}
        if gt is not None: bounds["gt"] = gt
        if gte is not None: bounds["gte"] = gte
        if lt is not None: bounds["lt"] = lt
        if lte is not None: bounds["lte"] = lte
        return {"range": {field: bounds}}

    @staticmethod
    def knn(field: str, vector: List[float], k: int = 10, ef_search: int = 64) -> Dict[str, Any]:
        return {
            "knn": {
                "field": field,
                "vector": vector,
                "k": k,
                "ef_search": ef_search,
            }
        }

    @staticmethod
    def hybrid(
        lexical_query: Dict[str, Any],
        vector_query: Dict[str, Any],
        mode: str = "rrf",
        alpha: float = 0.5,
        rrf_k: int = 60,
    ) -> Dict[str, Any]:
        return {
            "hybrid": {
                "lexical": lexical_query,
                "vector": vector_query,
                "mode": mode,
                "alpha": alpha,
                "rrf_k": rrf_k,
            }
        }

    @classmethod
    def bool(cls) -> "BoolQueryBuilder":
        return BoolQueryBuilder()

class BoolQueryBuilder:
    def __init__(self) -> None:
        self._must: List[Dict[str, Any]] = []
        self._filter: List[Dict[str, Any]] = []
        self._should: List[Dict[str, Any]] = []
        self._must_not: List[Dict[str, Any]] = []
        self._minimum_should_match: int = 0
        self._boost: float = 1.0

    def must(self, clause: Dict[str, Any]) -> "BoolQueryBuilder":
        self._must.append(clause)
        return self

    def filter(self, clause: Dict[str, Any]) -> "BoolQueryBuilder":
        self._filter.append(clause)
        return self

    def should(self, clause: Dict[str, Any]) -> "BoolQueryBuilder":
        self._should.append(clause)
        return self

    def must_not(self, clause: Dict[str, Any]) -> "BoolQueryBuilder":
        self._must_not.append(clause)
        return self

    def minimum_should_match(self, count: int) -> "BoolQueryBuilder":
        self._minimum_should_match = count
        return self

    def boost(self, val: float) -> "BoolQueryBuilder":
        self._boost = val
        return self

    def build(self) -> Dict[str, Any]:
        res: Dict[str, Any] = {"boost": self._boost}
        if self._must: res["must"] = self._must
        if self._filter: res["filter"] = self._filter
        if self._should: res["should"] = self._should
        if self._must_not: res["must_not"] = self._must_not
        if self._minimum_should_match > 0:
            res["minimum_should_match"] = self._minimum_should_match
        return {"bool": res}
