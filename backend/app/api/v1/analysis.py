"""``/api/v1/analysis`` endpoints.

Two routes:

* ``POST /analysis/run`` — runs a fresh AI analysis. Rate-limited per user
  (10/minute, sliding window). Maps every domain exception to its
  designed status code.
* ``GET /analysis/latest`` — returns the user's most recent stored
  analysis or HTTP 204 when none exists (Requirement 5.5).

Wiring notes
------------
* ``Depends(get_current_user)`` runs *before* the rate limiter so an
  unauthenticated request is rejected with 401 and never reaches the
  limiter (Requirement 7.3 / Property 22).
* ``request: Request`` and ``response: Response`` are required parameters
  on the limited route — slowapi reads the request to resolve the user
  bucket and writes ``X-RateLimit-*`` headers onto the response.

Note on ``from __future__ import annotations``
----------------------------------------------
We deliberately do NOT enable ``from __future__ import annotations`` in
this module. FastAPI (via Pydantic ``TypeAdapter``) resolves route
parameter annotations *at registration time* via the function's
``__globals__``. When the route handler is wrapped by
``@analysis_rate_limit`` (slowapi), the wrapper's globals do not contain
``AnalysisRequest`` and the lazy forward reference fails to resolve. By
keeping annotations as concrete classes here, FastAPI sees the real
``AnalysisRequest`` class object directly and registration succeeds.
"""

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from app.core.security import CurrentUser
from app.middleware.jwt_auth import get_current_user
from app.middleware.rate_limit import analysis_rate_limit
from app.schemas.analysis import AnalysisRequest, AnalysisResponse
from app.services import analysis_service
from app.services.ai_service import AIEnvelopeError, UpstreamAIError
from app.services.settings_service import MissingAIKey

router = APIRouter(prefix="/analysis", tags=["analysis"])


@router.post("/run", response_model=AnalysisResponse)
@analysis_rate_limit
async def run_analysis(
    request: Request,
    response: Response,
    payload: AnalysisRequest,
    user: CurrentUser = Depends(get_current_user),
) -> AnalysisResponse:
    """Run a fresh AI analysis and persist the result.

    Translates the orchestrator's exception cases into the wire contract
    documented in design.md:

    * :class:`MissingAIKey` → 412 ``ai_key_missing`` (Requirement 4.7).
    * :class:`UpstreamAIError` → 502 with the upstream status echoed
      (Requirement 4.8).
    * :class:`AIEnvelopeError` → 502 ``ai_invalid_json`` (Requirement 4.6).
    """
    try:
        return await analysis_service.run(user.id, payload)
    except MissingAIKey as exc:
        raise HTTPException(
            status_code=status.HTTP_412_PRECONDITION_FAILED,
            detail={
                "code": "ai_key_missing",
                "detail": "Set your AI key in Settings",
            },
        ) from exc
    except UpstreamAIError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "code": "upstream_ai_error",
                "upstream_status": exc.status_code,
                "detail": "Upstream AI provider returned an error.",
            },
        ) from exc
    except AIEnvelopeError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "code": "ai_invalid_json",
                "detail": "AI returned invalid JSON",
            },
        ) from exc


@router.get(
    "/latest",
    response_model=AnalysisResponse,
    responses={204: {"description": "No analysis has been run yet."}},
)
def get_latest(
    response: Response,
    user: CurrentUser = Depends(get_current_user),
) -> AnalysisResponse | Response:
    """Return the most recent analysis for the user, or 204 if none.

    The frontend uses 204 as the signal to render the empty Dashboard with
    a "Run analysis" CTA (Requirement 5.5).
    """
    latest = analysis_service.get_latest(user.id)
    if latest is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return latest
