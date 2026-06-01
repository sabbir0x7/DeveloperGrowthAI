"""Fernet symmetric encryption with key rotation support.

The backend stores per-user AI provider keys at rest in `user_settings`. Those
secrets are encrypted with Fernet (AES-128-CBC + HMAC-SHA256) before insert
and decrypted only in-memory for the lifetime of a single analysis request.

`MultiFernet` lets us rotate the server-side key without a downtime migration:
new ciphertext is always produced under the newest key (the first entry in the
list), while decryption walks the configured keys until one succeeds. A future
rotation job can re-encrypt existing rows via :meth:`EncryptionService.rotate`.
"""

from __future__ import annotations

from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken as FernetInvalidToken, MultiFernet

from app.core.config import get_settings


class DecryptionError(Exception):
    """Raised when no configured key can decrypt a given Fernet token.

    Callers (services, route handlers) catch this domain exception instead of
    importing the underlying cryptography library, keeping the dependency
    contained to this module.
    """


class EncryptionService:
    """Fernet wrapper that encrypts under the newest key and decrypts under any.

    Parameters
    ----------
    keys:
        Fernet keys in descending recency order (newest first). Each entry is
        the url-safe base64 32-byte key bytes that `Fernet` accepts directly.
        Must contain at least one key.
    """

    def __init__(self, keys: list[bytes]) -> None:
        if not keys:
            raise ValueError("EncryptionService requires at least one Fernet key")
        # Preserve the newest-first order: MultiFernet encrypts with the first
        # entry and tries each in turn on decrypt.
        self._fernets: list[Fernet] = [Fernet(key) for key in keys]
        self._multi: MultiFernet = MultiFernet(self._fernets)

    def encrypt(self, plaintext: str) -> bytes:
        """Encrypt `plaintext` with the newest configured key.

        Returns the Fernet token as raw bytes (url-safe base64). The caller is
        responsible for storing the bytes in a `bytea` column.
        """
        return self._multi.encrypt(plaintext.encode("utf-8"))

    def decrypt(self, token: bytes) -> str:
        """Decrypt `token` by trying every configured key in order.

        Raises :class:`DecryptionError` if no key can validate the token,
        which means either tampering or that the token was produced under a
        retired key that's no longer in the rotation list.
        """
        try:
            plaintext = self._multi.decrypt(token)
        except FernetInvalidToken as exc:
            raise DecryptionError("decrypt_failed") from exc
        return plaintext.decode("utf-8")

    def rotate(self, token: bytes) -> bytes:
        """Re-encrypt `token` under the newest key.

        Used by a future key-rotation job to upgrade ciphertext after the
        operator prepends a new key to `FERNET_KEYS`. If the token is already
        encrypted under the newest key, `MultiFernet.rotate` returns
        equivalent ciphertext (with a fresh IV).

        Raises :class:`DecryptionError` if no configured key can read it.
        """
        try:
            return self._multi.rotate(token)
        except FernetInvalidToken as exc:
            raise DecryptionError("decrypt_failed") from exc


@lru_cache(maxsize=1)
def get_encryption_service() -> EncryptionService:
    """Return a process-wide cached :class:`EncryptionService`.

    Mirrors the `get_settings()` accessor pattern: settings are resolved lazily
    on the first call so importing this module never forces the env to be
    present. Tests that mutate `FERNET_KEYS` should call
    `get_encryption_service.cache_clear()` between cases.
    """
    settings = get_settings()
    return EncryptionService(settings.fernet_keys_list)
