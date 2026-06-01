"""FastAPI application entrypoint.

Wires together the v1 routers, the slowapi rate limiter, and the domain
exception handlers that translate service-layer errors into the wire
contract documented in design.md.

Concrete responsibilities of this module:

1. Construct a :class:`fastapi.FastAPI` instance.
2. Attach :data:`app.middleware.rate_limit.limiter` to ``app.state.limiter``
   and register the slowapi middleware + 429 handler so per-user rate
   limits work end to end.
3. Register exception handlers for the domain errors raised by services:
   :class:`InvalidToken` → 401, :class:`MissingAIKey` → 412,
   :class:`UpstreamAIError` → 502, :class:`AIEnvelopeError` → 502,
   :class:`ProfileNotFound` → 404. Routes also catch these and translate
   them inline; the handlers are a defensive net for any path that
   forgets to.
4. Mount the three v1 routers under ``/api/v1``.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware

from app.api.v1.analysis import router as analysis_router
from app.api.v1.auth import router as auth_router
from app.api.v1.github_oauth import router as github_oauth_router
from app.api.v1.profile import router as profile_router
from app.core.security import InvalidToken
from app.middleware.rate_limit import limiter, rate_limit_exceeded_handler
from app.services.ai_service import AIEnvelopeError, UpstreamAIError
from app.services.profile_service import ProfileNotFound
from app.services.settings_service import MissingAIKey

# Bearer challenge re-used for any 401 we emit from this layer.
_WWW_AUTHENTICATE_BEARER = 'Bearer realm="api", charset="UTF-8"'


def create_app() -> FastAPI:
    """Build and configure the FastAPI application.

    Factored into a function so tests can boot fresh instances without
    side-effecting a module-level singleton. The production entrypoint
    (e.g., ``uvicorn app.main:app``) reads :data:`app` from this module.
    """
    application = FastAPI(
        title="DevGrowth AI",
        version="0.1.0",
        description="AI-powered career growth platform for software developers.",
    )

    # ------------------------------------------------------------------
    # CORS — allow the Flutter web app (any localhost port) to call the
    # backend. In production, restrict origins to the deployed domain.
    # ------------------------------------------------------------------
    application.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ------------------------------------------------------------------
    # Rate limiter wiring (per-user sliding window on /api/v1/analysis/*).
    # ------------------------------------------------------------------
    application.state.limiter = limiter
    application.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)
    application.add_middleware(SlowAPIMiddleware)

    # ------------------------------------------------------------------
    # Domain exception handlers — defensive translations to the wire
    # contract. Routes also catch and re-raise as HTTPException so the
    # body shape is exactly what the frontend expects, but these
    # handlers ensure a missed catch elsewhere doesn't leak a 500.
    # ------------------------------------------------------------------

    @application.exception_handler(InvalidToken)
    async def _invalid_token_handler(_request: Request, exc: InvalidToken) -> JSONResponse:
        return JSONResponse(
            status_code=401,
            content={"detail": exc.detail},
            headers={"WWW-Authenticate": _WWW_AUTHENTICATE_BEARER},
        )

    @application.exception_handler(ProfileNotFound)
    async def _profile_not_found_handler(_request: Request, _exc: ProfileNotFound) -> JSONResponse:
        return JSONResponse(
            status_code=404,
            content={"detail": "profile_not_found"},
        )

    @application.exception_handler(MissingAIKey)
    async def _missing_ai_key_handler(_request: Request, _exc: MissingAIKey) -> JSONResponse:
        return JSONResponse(
            status_code=412,
            content={
                "code": "ai_key_missing",
                "detail": "Set your AI key in Settings",
            },
        )

    @application.exception_handler(UpstreamAIError)
    async def _upstream_ai_error_handler(_request: Request, exc: UpstreamAIError) -> JSONResponse:
        return JSONResponse(
            status_code=502,
            content={
                "code": "upstream_ai_error",
                "upstream_status": exc.status_code,
                "detail": "Upstream AI provider returned an error.",
            },
        )

    @application.exception_handler(AIEnvelopeError)
    async def _ai_envelope_error_handler(_request: Request, _exc: AIEnvelopeError) -> JSONResponse:
        return JSONResponse(
            status_code=502,
            content={
                "code": "ai_invalid_json",
                "detail": "AI returned invalid JSON",
            },
        )

    # ------------------------------------------------------------------
    # Routers — every protected route declares Depends(get_current_user)
    # itself, so we don't apply a global dependency here.
    # ------------------------------------------------------------------
    application.include_router(auth_router, prefix="/api/v1")
    application.include_router(github_oauth_router, prefix="/api/v1")
    application.include_router(profile_router, prefix="/api/v1")
    application.include_router(analysis_router, prefix="/api/v1")

    return application


# Module-level singleton consumed by ``uvicorn app.main:app``.
app = create_app()
