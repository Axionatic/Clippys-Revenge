"""Effect discovery — scan effects/ for available effect plugins."""
from __future__ import annotations

import importlib
import pathlib
import sys
from typing import Any


def discover_effects() -> dict[str, dict[str, Any]]:
    """Scan the effects directory for classes with EFFECT_META.

    Returns a dict mapping effect name to metadata::

        {"fire": {"name": "fire", "module_path": "/abs/path/fire.py", "class_name": "FireEffect"}}

    Never raises — import errors and broken modules are silently skipped.
    """
    effects_dir = pathlib.Path(__file__).parent
    registry: dict[str, dict[str, Any]] = {}

    for py_file in sorted(effects_dir.glob("*.py")):
        if py_file.name == "__init__.py":
            continue

        module_name = f"clippy.effects.{py_file.stem}"
        try:
            module = importlib.import_module(module_name)
        except Exception as e:
            print(f"Warning: failed to load effect module {module_name}: {e}", file=sys.stderr)
            continue

        for attr_name in dir(module):
            obj = getattr(module, attr_name, None)
            if not isinstance(obj, type):
                continue
            meta = getattr(obj, "EFFECT_META", None)
            if not isinstance(meta, dict) or "name" not in meta:
                continue

            name = meta["name"]
            registry[name] = {
                **meta,
                "module_path": str(py_file.resolve()),
                "class_name": attr_name,
            }

    return registry
