"""Eager, typed reading of JSON documents.

`json.loads` returns `Any`; this is the only module allowed to touch that.
Callers read fields through `JsonObject`'s typed getters and build dataclasses
straight away, so no dict of unchecked values travels further.
"""

import json
from dataclasses import dataclass
from typing import cast


class JsonError(ValueError):
    """A JSON document does not have the expected shape."""


@dataclass(frozen=True, slots=True)
class JsonObject:
    """A JSON object whose fields are only reachable through typed getters."""

    fields: dict[str, object]

    def _get(self, key: str) -> object:
        return self.fields.get(key)

    def text(self, key: str, default: str = "") -> str:
        """Return a string field, or `default` when it is absent."""
        value = self._get(key)
        if value is None:
            return default
        if not isinstance(value, str):
            msg = f"{key} is not a string"
            raise JsonError(msg)
        return value

    def required_text(self, key: str) -> str:
        """Return a string field that must be present."""
        if key not in self.fields:
            msg = f"{key} is missing"
            raise JsonError(msg)
        return self.text(key)

    def has(self, key: str) -> bool:
        """Report whether the field is present and not null."""
        return self._get(key) is not None

    def flag(self, key: str) -> bool:
        """Return a boolean field, false when absent."""
        value = self._get(key)
        if value is None:
            return False
        if not isinstance(value, bool):
            msg = f"{key} is not a boolean"
            raise JsonError(msg)
        return value

    def integer(self, key: str, default: int = 0) -> int:
        """Return an integer field, or `default` when it is absent."""
        value = self._get(key)
        if value is None:
            return default
        if isinstance(value, bool) or not isinstance(value, int):
            msg = f"{key} is not an integer"
            raise JsonError(msg)
        return value

    def child(self, key: str) -> "JsonObject":
        """Return a nested object that must be present."""
        return as_object(self._get(key), key)

    def children(self, key: str) -> list["JsonObject"]:
        """Return a list of objects, empty when absent."""
        return [as_object(item, key) for item in self._items(key)]

    def strings(self, key: str) -> list[str]:
        """Return a list of strings, empty when absent."""
        items = self._items(key)
        if not all(isinstance(item, str) for item in items):
            msg = f"{key} is not a list of strings"
            raise JsonError(msg)
        return [str(item) for item in items]

    def _items(self, key: str) -> list[object]:
        """Return a list field's raw items, empty when absent."""
        value = self._get(key)
        if value is None:
            return []
        if not isinstance(value, list):
            msg = f"{key} is not a list"
            raise JsonError(msg)
        return list(cast("list[object]", value))


def as_object(value: object, what: str = "document") -> JsonObject:
    """Narrow a decoded JSON value to an object with string keys."""
    if not isinstance(value, dict):
        msg = f"{what} is not an object"
        raise JsonError(msg)
    fields = cast("dict[object, object]", value)
    if not all(isinstance(key, str) for key in fields):
        msg = f"{what} has a non-string key"
        raise JsonError(msg)
    return JsonObject({str(key): item for key, item in fields.items()})


def parse(document: str | bytes) -> JsonObject:
    """Decode a JSON document whose top level must be an object."""
    decoded: object = json.loads(document)  # pyright: ignore[reportAny] -- the one boundary
    return as_object(decoded)
