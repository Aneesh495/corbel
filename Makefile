.PHONY: all test analyze format clean run bench native python-test help

DART ?= dart
PYTHON ?= python3

all: analyze test

help:
	@echo "Corbel: High-Throughput Search, FST & Vector-Relational Engine"
	@echo "Targets:"
	@echo "  make analyze      Run Dart static analysis"
	@echo "  make test         Execute full test suite across all sub-engines"
	@echo "  make bench        Run micro-benchmarks for indexing and search"
	@echo "  make format       Format Dart source tree"
	@echo "  make native       Build native C SIMD vector acceleration library"
	@echo "  make python-test  Run Python client test suite"
	@echo "  make clean        Clean build artifacts and temporary files"

analyze:
	$(DART) analyze --fatal-infos

test:
	$(DART) test --concurrency=4

format:
	$(DART) format .

bench:
	$(DART) run bench/indexing_benchmark.dart
	$(DART) run bench/search_benchmark.dart
	$(DART) run bench/vector_benchmark.dart
	$(DART) run bench/roaring_bitmap_benchmark.dart
	$(DART) run bench/fst_benchmark.dart

native:
	@if [ -d native ]; then \
		mkdir -p build/native && \
		cd build/native && \
		cmake ../../native && \
		make; \
	fi

python-test:
	@if [ -d clients/python ]; then \
		pytest clients/python/tests; \
	fi

clean:
	rm -rf build/
	rm -rf .dart_tool/
	rm -rf data/
	rm -rf tmp/
