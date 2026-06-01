"""``/api/v1/profile`` endpoints.

Two resources live under this router:

* ``/profile/me`` — read and partially update the authenticated user's
  profile (``github_url``, ``linkedin_url``, ``goal``).
* ``/profile/settings`` — read and write the user's AI provider settings.
  The write contract takes the plaintext key once; the read contract
  returns metadata only.

Routes are thin: they delegate to :mod:`app.services.profile_service` and
:mod:`app.services.settings_service` and translate domain exceptions into
the HTTP responses the frontend expects. The JWT dependency runs on every
route, so unauthenticated traffic is rejected with HTTP 401 by middleware
before any service code runs (Requirements 1.3, 1.5).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status

from app.core.security import CurrentUser
from app.core.supabase_client import get_supabase
from app.middleware.jwt_auth import get_current_user
from app.schemas.profile import ProfileOut, ProfilePatch
from app.schemas.settings import SettingsIn, SettingsOut
from app.services import profile_service, settings_service

router = APIRouter(prefix="/profile", tags=["profile"])


# ---------------------------------------------------------------------------
# /profile/me
# ---------------------------------------------------------------------------


@router.get("/me", response_model=ProfileOut)
def read_me(user: CurrentUser = Depends(get_current_user)) -> ProfileOut:
    """Return the authenticated user's profile row.

    The DB ``handle_new_user`` trigger guarantees a ``users`` row exists for
    every Supabase auth user, so ``ProfileNotFound`` is treated as a
    defensive 404 rather than the normal flow.
    """
    try:
        return profile_service.get_profile(user.id)
    except profile_service.ProfileNotFound as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="profile_not_found",
        ) from exc


@router.patch("/me", response_model=ProfileOut)
def patch_me(
    patch: ProfilePatch,
    user: CurrentUser = Depends(get_current_user),
) -> ProfileOut:
    """Partial update for ``github_url``, ``linkedin_url``, and ``goal``.

    The Pydantic schema enforces HTTPS-only URLs and goal length 1..500;
    invalid bodies surface as FastAPI's default 422 with field-level
    errors before the route handler runs (Requirements 2.4, 3.4).
    """
    try:
        return profile_service.patch_profile(user.id, patch)
    except profile_service.ProfileNotFound as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="profile_not_found",
        ) from exc


# ---------------------------------------------------------------------------
# /profile/settings
# ---------------------------------------------------------------------------


@router.get("/settings", response_model=SettingsOut)
def read_settings(user: CurrentUser = Depends(get_current_user)) -> SettingsOut:
    """Return ``{has_ai_key, ai_provider_base_url}`` only.

    The decrypted AI key is never derived on this path - the service
    inspects only the presence of the ciphertext and returns the boolean
    flag (Requirements 6.5, 6.6 / Property 18).
    """
    return settings_service.get_settings(user.id)


@router.put("/settings", response_model=SettingsOut)
def put_settings(
    payload: SettingsIn,
    user: CurrentUser = Depends(get_current_user),
) -> SettingsOut:
    """Encrypt and persist the user's AI key + provider base URL.

    The schema validates the base URL is HTTPS (Requirement 6.7) and the
    AI key has a sane minimum length before this handler runs. The
    response shape is :class:`SettingsOut` so the encrypted key never
    rides on the wire (Requirement 6.5).
    """
    return settings_service.put_settings(user.id, payload)


# ---------------------------------------------------------------------------
# /profile/linkedin-pdf
# ---------------------------------------------------------------------------


@router.post("/linkedin-pdf")
async def upload_linkedin_pdf(
    file: UploadFile = File(...),
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """Upload a LinkedIn PDF export and extract text from it.

    Accepts multipart/form-data with a file field named ``file``.
    Extracts text using PyPDF2, stores it in the ``users.linkedin_pdf_text``
    column, and returns a preview of the extracted text.
    """
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only PDF files are accepted.",
        )

    # Read the file content
    content = await file.read()
    if not content:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Empty file.",
        )

    # Extract text from PDF
    try:
        import io
        from PyPDF2 import PdfReader

        reader = PdfReader(io.BytesIO(content))
        text_parts: list[str] = []
        for page in reader.pages:
            page_text = page.extract_text()
            if page_text:
                text_parts.append(page_text)
        extracted_text = "\n".join(text_parts).strip()
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Could not extract text from PDF: {exc}",
        ) from exc

    if not extracted_text:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="No text could be extracted from the PDF.",
        )

    # Store extracted text in users table
    try:
        sb = get_supabase()
        sb.table("users").update(
            {"linkedin_pdf_text": extracted_text}
        ).eq("id", str(user.id)).execute()
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to store extracted text.",
        ) from exc

    return {
        "status": "uploaded",
        "text_length": len(extracted_text),
        "preview": extracted_text[:200],
    }
