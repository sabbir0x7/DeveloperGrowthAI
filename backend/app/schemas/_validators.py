"""Shared field-level validators for boundary schemas.

Pydantic's :class:`HttpUrl` accepts both ``http://`` and ``https://`` schemes.
Our requirements forbid plaintext ``http://`` for any URL we persist or send
upstream (profile links, AI provider base URL), so we layer an
``https``-only check on top of the built-in URL parsing.

Centralizing the validator here keeps the rule (and its error message) in
exactly one place across ``profile``, ``settings``, and ``analysis`` schemas.
"""

from __future__ import annotations

from typing import Any


def require_https(value: Any) -> Any:
    """Reject any URL whose scheme is not ``https``.

    Used as an ``@field_validator(..., mode="after")`` callback. The value
    arrives as a parsed Pydantic v2 ``Url`` object (because Pydantic has
    already accepted it as a syntactically valid URL) or ``None`` for
    optional fields. We let ``None`` pass through unchanged so this validator
    is safe to attach to optional URL fields.

    We read ``.scheme`` when present (the Pydantic v2 ``Url`` type exposes
    it) and otherwise fall back to parsing the string form. ``HttpUrl``
    itself is an ``Annotated`` alias in Pydantic v2 and is not safe to use in
    ``isinstance`` checks, which is why we duck-type instead.

    Raising :class:`ValueError` is what Pydantic v2 expects: it converts the
    raised message into a 422 response with a field-level error pointing to
    the offending field.
    """
    if value is None:
        return value
    scheme = getattr(value, "scheme", None)
    if scheme is None:
        # Defensive fallback for unexpected types (e.g. raw strings if a
        # caller invokes this validator outside of a Pydantic pipeline).
        scheme = str(value).split("://", 1)[0].lower()
    if scheme != "https":
        raise ValueError("URL must use the https scheme")
    return value
