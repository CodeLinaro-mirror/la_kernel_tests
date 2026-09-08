.PHONY: setup clean format lint typecheck test build

VENV = reporter/venv
PYTHON = $(VENV)/bin/python
PIP = $(VENV)/bin/pip

setup:
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	cd reporter && ../$(PIP) install -e .[dev]

clean:
	rm -rf $(VENV)
	rm -rf reporter/build reporter/dist reporter/src/*.egg-info reporter/*.egg-info
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -type d -name ".mypy_cache" -exec rm -rf {} +
	find . -type d -name ".ruff_cache" -exec rm -rf {} +

format:
	$(PYTHON) -m ruff format reporter/src/ reporter/tests/

lint:
	$(PYTHON) -m ruff check reporter/src/ reporter/tests/

typecheck:
	$(PYTHON) -m mypy reporter/src/ reporter/tests/

test:
	$(PYTHON) -m pytest reporter/tests/

build:
	cd reporter && ../$(PYTHON) -m build
