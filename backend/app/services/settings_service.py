"""Per-user AI provider settings: read metadata, persist encrypted, decrypt.

This service owns the ``user_settings`` table and is the only module that
moves AI-key plaintext between Pydantic boundary schemas, the Fernet
encryption layer, and Supabase Postgres.

Responsibilities, in order of trust boundary:

* :func:`get_settings` — public metadata read for ``GET /profile/settings``.
  Returns :class:`SettingsOut` (``has_ai_key`` boolean and the base URL); the
  ciphertext column is never decrypted on this path so the key plaintext
  cannot leak through a misconfigured handler. Backs Requirements 6.5, 6.6.
* :func:`put_settings` — encrypts the inbound key with the newest Fernet key
  via :class:`~app.core.encryption.EncryptionService` then upserts the row.
  Plaintext is dropped after the call returns. Backs Requirements 6.1, 6.2,
  6.3, 6.4 (write side).
* :func:`get_decrypted_key` — internal accessor consumed by
  :mod:`app.services.analysis_service` during a single request. Raises
  :class:`MissingAIKey` (mapped to HTTP 412 ``ai_key_missing``) when the row
  is absent or the column is null/empty.

Bytea encoding
--------------
PostgREST (the layer behind ``supabase-py``) serializes ``bytea`` columns as
``\\x<hex>`` strings on read and accepts the same ``\\x<hex>`` literal on
write. We round-trip Fernet ciphertext through that encoding instead of
relying on driver-level binary support.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from app.core.config import get_settings as get_app_settings
from app.core.encryption import get_encryption_service
from app.core.supabase_client import get_supabase
from app.schemas.settings import SettingsIn, SettingsOut


class MissingAIKey(Exception):
    """Raised when an analysis run needs an AI key but none is configured.

    The analysis route translates this exception into HTTP 412 with body
    ``{"code": "ai_key_missing"}`` (Requirement 4.7).
    """


# Single source of truth for the table name. Keeping it module-level lets
# tests patch the constant without monkey-patching every callsite.
_TABLE = "user_settings"


def _decode_bytea(value: object) -> bytes | None:
    """Convert a Supabase ``bytea`` field to raw bytes.

    PostgREST returns ``bytea`` as a hex literal string ``\\x<hex>``. ``None``
    is preserved (the column is nullable until a key is saved). Any other
    representation is treated as a programming error.
    """
    if value is None:
        return None
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    if isinstance(value, str):
        if value == "":
            return None
        if value.startswith("\\x"):
            return bytes.fromhex(value[2:])
        # Fall back to a bare hex string (e.g. when a future PostgREST
        # config emits bytea without the prefix). ``bytes.fromhex`` raises
        # ``ValueError`` on anything that isn't valid hex, which surfaces
        # as a 500 — exactly the right behavior for unexpected formats.
        return bytes.fromhex(value)
    raise TypeError(f"unsupported bytea representation: {type(value)!r}")


def _encode_bytea(data: bytes) -> str:
    """Encode raw bytes into PostgREST's ``\\x<hex>`` literal form."""
    return "\\x" + data.hex()


def _select_row(user_id: UUID | str) -> dict | None:
    """Return the user's settings row or ``None`` if it doesn't exist yet.

    Selecting only the two columns we care about keeps the wire payload
    small and ensures we never accidentally exfiltrate other fields.
    """
    supabase = get_supabase()
    response = (
        supabase.table(_TABLE)
        .select("encrypted_ai_key, ai_provider_base_url")
        .eq("user_id", str(user_id))
        .limit(1)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def get_settings(user_id: UUID | str) -> SettingsOut:
    """Return public-facing settings metadata for ``user_id``.

    The shape is fixed by :class:`SettingsOut`: ``has_ai_key`` (bool) and
    ``ai_provider_base_url``. The decrypted key never appears here, even
    transiently, because we don't decrypt on this path at all.

    When no settings row exists yet (the user hasn't saved a key), the
    response carries ``has_ai_key=False`` and the configured default base URL
    so the client can render the empty Settings drawer without a special
    case for "no row".
    """
    row = _select_row(user_id)
    default_url = str(get_app_settings().AI_PROVIDER_BASE_URL_DEFAULT)

    if row is None:
        return SettingsOut(has_ai_key=False, ai_provider_base_url=default_url)  # type: ignore[arg-type]

    encrypted = _decode_bytea(row.get("encrypted_ai_key"))
    base_url = row.get("ai_provider_base_url") or default_url

    return SettingsOut(
        has_ai_key=bool(encrypted),
        ai_provider_base_url=base_url,  # type: ignore[arg-type]
    )


def put_settings(user_id: UUID | str, payload: SettingsIn) -> SettingsOut:
    """Encrypt ``payload.ai_key`` and upsert the user's settings row.

    The plaintext key lives only in this stack frame; once
    :meth:`EncryptionService.encrypt` returns, only the Fernet ciphertext
    is held. The returned :class:`SettingsOut` deliberately mirrors the
    metadata shape so the route handler cannot accidentally serialize the
    key on a successful write.

    ``updated_at`` is set explicitly because PostgREST's upsert path doesn't
    re-evaluate the column default on conflict.
    """
    encryption = get_encryption_service()
    ciphertext = encryption.encrypt(payload.ai_key)

    supabase = get_supabase()
    supabase.table(_TABLE).upsert(
        {
            "user_id": str(user_id),
            "encrypted_ai_key": _encode_bytea(ciphertext),
            "ai_provider_base_url": str(payload.ai_provider_base_url),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        },
        on_conflict="user_id",
    ).execute()

    return SettingsOut(
        has_ai_key=True,
        ai_provider_base_url=payload.ai_provider_base_url,
    )


def get_decrypted_key(user_id: UUID | str) -> str:
    """Return the user's plaintext AI key for a single analysis call.

    This is the only entry point that exposes plaintext, and it is intended
    to be consumed by :mod:`app.services.analysis_service` inside the scope
    of one HTTP request. Callers must NOT cache, log, or surface the
    returned string.

    Raises
    ------
    MissingAIKey
        When no ``user_settings`` row exists or the ``encrypted_ai_key``
        column is null/empty. Both conditions map to HTTP 412
        ``ai_key_missing`` per Requirement 4.7.
    """
    row = _select_row(user_id)
    default_key = get_app_settings().AI_API_KEY_DEFAULT

    if row is None:
        if default_key:
            return default_key
        raise MissingAIKey("ai_key_missing")

    encrypted = _decode_bytea(row.get("encrypted_ai_key"))
    if not encrypted:
        if default_key:
            return default_key
        raise MissingAIKey("ai_key_missing")

    return get_encryption_service().decrypt(encrypted)
