"""Property-based tests for the Fernet AI-key encryption service.

Property 16: AI key encryption round-trips and never stores plaintext
Validates: Requirement 6.2

For any non-empty AI key string ``k`` (constrained to the realistic AI-key
domain enforced by ``SettingsIn.ai_key`` — ``min_length=8``):

* ``decrypt(encrypt(k)) == k`` (round-trip preservation).
* The ciphertext bytes are not equal to ``k.encode("utf-8")``.
* The ciphertext bytes do not contain ``k.encode("utf-8")`` as a substring.

The service is exercised through :class:`EncryptionService` directly, with
two freshly generated ``Fernet.generate_key()`` values so the multi-key
``MultiFernet`` rotation path runs alongside the basic round-trip.

Note on input bounds: Fernet emits url-safe base64 ciphertext (~100 bytes).
A 1-3 character plaintext drawn from that alphabet would appear as a chance
substring of the ciphertext often enough to make the third assertion flaky,
so we mirror the ``SettingsIn.ai_key`` validator's ``min_length=8`` bound.
"""

from __future__ import annotations

from cryptography.fernet import Fernet
from hypothesis import given, strategies as st

from app.core.encryption import EncryptionService


# Two freshly generated Fernet keys means the underlying ``MultiFernet`` will
# encrypt with key #0 and try keys #0 then #1 on decrypt. Generating once at
# module load keeps the property test deterministic across the >=100 examples.
_KEYS: list[bytes] = [Fernet.generate_key(), Fernet.generate_key()]


# AI keys land in the database via ``SettingsIn(ai_key: str, min_length=8)``.
# Bounding the strategy at 8 reflects that real-world domain; the upper bound
# is generous enough to cover provider-issued keys (OpenAI ~51 chars, project
# keys can run longer) while keeping individual examples cheap.
ai_key_strategy = st.text(min_size=8, max_size=256).filter(lambda s: len(s) > 0)


@given(k=ai_key_strategy)
def test_encrypt_decrypt_round_trip(k: str) -> None:
    """``decrypt(encrypt(k)) == k`` for every realistic AI key ``k``."""
    service = EncryptionService(_KEYS)

    ciphertext = service.encrypt(k)

    assert service.decrypt(ciphertext) == k


@given(k=ai_key_strategy)
def test_ciphertext_is_not_plaintext_bytes(k: str) -> None:
    """Encrypted output is never equal to the raw UTF-8 bytes of ``k``."""
    service = EncryptionService(_KEYS)

    ciphertext = service.encrypt(k)

    assert ciphertext != k.encode("utf-8")


@given(k=ai_key_strategy)
def test_ciphertext_does_not_contain_plaintext(k: str) -> None:
    """The plaintext UTF-8 bytes never appear as a substring of the ciphertext."""
    service = EncryptionService(_KEYS)

    ciphertext = service.encrypt(k)

    assert k.encode("utf-8") not in ciphertext
