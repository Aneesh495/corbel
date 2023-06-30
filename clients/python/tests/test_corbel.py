import io
import json
import unittest
from unittest.mock import MagicMock, patch

from corbel import CorbelClient, Query, StreamingBulkIndexer

class TestQueryBuilder(unittest.TestCase):
    def test_term_query(self):
        q = Query.term("title", "database", boost=2.0)
        self.assertEqual(q, {
            "term": {
                "title": {
                    "value": "database",
                    "boost": 2.0,
                }
            }
        })

    def test_match_query(self):
        q = Query.match("body", "search engine")
        self.assertEqual(q, {
            "match": {
                "body": {
                    "query": "search engine",
                    "boost": 1.0,
                }
            }
        })

    def test_range_query(self):
        q = Query.range("price", gte=10, lt=100)
        self.assertEqual(q, {
            "range": {
                "price": {
                    "boost": 1.0,
                    "gte": 10,
                    "lt": 100,
                }
            }
        })

    def test_knn_and_hybrid_queries(self):
        knn_q = Query.knn("embedding", [0.1, 0.2, 0.3], k=5)
        self.assertEqual(knn_q, {
            "knn": {
                "field": "embedding",
                "vector": [0.1, 0.2, 0.3],
                "k": 5,
                "ef_search": 64,
            }
        })

        lex_q = Query.match("title", "quantization")
        hybrid_q = Query.hybrid(lex_q, knn_q, mode="rrf", alpha=0.7, rrf_k=60)
        self.assertEqual(hybrid_q["hybrid"]["mode"], "rrf")
        self.assertEqual(hybrid_q["hybrid"]["alpha"], 0.7)

    def test_geospatial_queries(self):
        dist_q = Query.geo_distance("location", 37.7749, -122.4194, distance_km=5.0)
        self.assertEqual(dist_q, {
            "geo_distance": {
                "location": {
                    "lat": 37.7749,
                    "lon": -122.4194,
                    "distance_km": 5.0,
                }
            }
        })

        bbox_q = Query.geo_bounding_box("location", 40.0, -75.0, 39.0, -74.0)
        self.assertIn("geo_bounding_box", bbox_q)
        self.assertEqual(bbox_q["geo_bounding_box"]["location"]["top_left"]["lat"], 40.0)

        poly_q = Query.geo_polygon("location", [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0)])
        self.assertIn("geo_polygon", poly_q)
        self.assertEqual(len(poly_q["geo_polygon"]["location"]["points"]), 3)

    def test_span_queries(self):
        st1 = Query.span_term("body", "neural")
        st2 = Query.span_term("body", "networks")
        near_q = Query.span_near([st1, st2], slop=2, in_order=True)
        self.assertEqual(near_q["span_near"]["slop"], 2)
        self.assertTrue(near_q["span_near"]["in_order"])

        or_q = Query.span_or([st1, st2])
        self.assertEqual(len(or_q["span_or"]["clauses"]), 2)

        not_q = Query.span_not(include=st1, exclude=st2, pre=1, post=1)
        self.assertEqual(not_q["span_not"]["pre"], 1)

        first_q = Query.span_first(match=st1, end=3)
        self.assertEqual(first_q["span_first"]["end"], 3)

    def test_function_score_query(self):
        base = Query.match("content", "machine learning")
        funcs = [
            {"field_value_factor": {"field": "votes", "factor": 1.2, "modifier": "sqrt"}},
            {"decay": {"field": "timestamp", "origin": 1000.0, "scale": 50.0, "type": "gauss"}},
        ]
        fs = Query.function_score(
            query=base,
            functions=funcs,
            boost_mode="multiply",
            score_mode="sum",
            max_boost=10.0,
            min_score=0.5,
        )
        self.assertEqual(fs["function_score"]["boost_mode"], "multiply")
        self.assertEqual(fs["function_score"]["score_mode"], "sum")
        self.assertEqual(fs["function_score"]["max_boost"], 10.0)
        self.assertEqual(fs["function_score"]["min_score"], 0.5)

    def test_bool_query_builder(self):
        bq = (
            Query.bool()
            .must(Query.term("status", "published"))
            .filter(Query.range("price", lte=50))
            .should(Query.match("title", "sale"))
            .must_not(Query.term("out_of_stock", True))
            .minimum_should_match(1)
            .boost(1.5)
            .build()
        )
        self.assertEqual(bq["bool"]["boost"], 1.5)
        self.assertEqual(bq["bool"]["minimum_should_match"], 1)
        self.assertEqual(len(bq["bool"]["must"]), 1)
        self.assertEqual(len(bq["bool"]["filter"]), 1)
        self.assertEqual(len(bq["bool"]["should"]), 1)
        self.assertEqual(len(bq["bool"]["must_not"]), 1)

class TestStreamingBulkIndexer(unittest.TestCase):
    def test_format_ndjson(self):
        indexer = StreamingBulkIndexer()
        actions = [
            {"action": "index", "index": "articles", "id": "1", "document": {"title": "First"}},
            {"action": "delete", "index": "articles", "id": "2"},
        ]
        ndjson = indexer.format_ndjson(actions)
        lines = [json.loads(line) for line in ndjson.strip().split("\n")]
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], {"index": {"_index": "articles", "_id": "1"}})
        self.assertEqual(lines[1], {"title": "First"})
        self.assertEqual(lines[2], {"delete": {"_index": "articles", "_id": "2"}})

    def test_chunk(self):
        indexer = StreamingBulkIndexer()
        items = list(range(10))
        chunks = list(indexer.chunk(items, batch_size=3))
        self.assertEqual(chunks, [[0, 1, 2], [3, 4, 5], [6, 7, 8], [9]])

class TestCorbelClient(unittest.TestCase):
    @patch("urllib.request.urlopen")
    def test_ping_and_cluster_health(self, mock_urlopen):
        # Mock ping response
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"name": "corbel-node-1", "version": "1.0.0"}).encode("utf-8")
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        client = CorbelClient(base_url="http://testnode:9200")
        res = client.ping()
        self.assertEqual(res["name"], "corbel-node-1")

    @patch("urllib.request.urlopen")
    def test_suggest_and_spellcheck(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"suggestions": ["corbel", "corbell"]}).encode("utf-8")
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        client = CorbelClient()
        res = client.suggest("my_index", "title", "corb", size=5)
        self.assertEqual(res["suggestions"], ["corbel", "corbell"])

        mock_resp.read.return_value = json.dumps({"correction": "neural network"}).encode("utf-8")
        spell_res = client.spellcheck("my_index", "neral netwrk")
        self.assertEqual(spell_res["correction"], "neural network")

if __name__ == "__main__":
    unittest.main()
