"""Per-user sliding-window rate limiting for ``/api/v1/analysis/*``.

This module wires up ``slowapi`` so authenticated calls to analysis routes
are capped at a fixed budget inside a 60-second moving window, keyed by the
authenticated user id that the JWT dependency attaches to
``request.state.user``.

Design choices that are easy to misread, so spelling them out:

* **Strategy**: ``moving-window`` (sliding window). Requirement 7.1 mandates a
  sliding 60-second window, not a fixed-window or token-bucket counter.
* **Scope**: applied only to routes under ``/api/v1/analysis`` via the
  :func:`analysis_rate_limit` decorator. The limiter is **not** registered as
  a global default so unrelated routes (auth, profile, settings) never
  consume any quota.
* **401 wins over 429** (Requirement 7.3): we do not implement the
  unauthenticated bypass *inside* the limiter, because slowapi 0.1.9 invokes
  ``exempt_when`` with no arguments and cannot inspect the request from there.
  Instead, the analysis router is expected to declare the JWT dependency
  (``Depends(get_current_user)``) on every limited route. FastAPI runs
  dependencies before the slowapi-wrapped handler body, so an unauthenticated
  request raises 401 from the dependency and never reaches the limiter.
  :func:`_user_id_key` enforces this contract: if it is reached without a
  verified user it raises, which surfaces as a 500 and signals a wiring bug
  in the route - not a runtime user-facing problem.
* **Body shape**: the 429 body matches design.md's error contract
  (``{"code": "rate_limited", "detail": ...}``); the ``Retry-After`` header
  carries the integer seconds remaining in the user's window so the Flutter
  client can show a countdown snackbar (Requirement 7.2).

Public surface
--------------
* :data:`limiter` — the singleton :class:`slowapi.Limiter`. ``main.py``
  attaches it to ``app.state.limiter`` and registers
  :func:`rate_limit_exceeded_handler` for :class:`RateLimitExceeded`.
* :data:`ANALYSIS_RATE_LIMIT` — the canonical ratelimit-string for analysis
  routes. Lives in one place so tests and routes never disagree.
* :func:`analysis_rate_limit` — the decorator analysis routes use to opt in
  to the limit. Hides the ``Limiter.limit`` plumbing from feature code.
* :func:`rate_limit_exceeded_handler` — the FastAPI exception handler that
  shapes the 429 response.
"""

from __future__ import annotations

import time
from typing import Any, Callable, TypeVar

from fastapi import Request
from fastapi.responses import JSONResponse
from slowapi import Limiter
from slowapi.errors import RateLimitExceeded

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Requirement 7.1 / Property 20: 10 admitted requests per 60-second window.
# Kept as a module-level constant so tests can assert on the exact string and
# routes never drift from this value.
ANALYSIS_RATE_LIMIT = "10/minute"

# slowapi accepts a few strategy names; "moving-window" is its sliding-window
# counter implementation, which is what Requirement 7.1 calls for.
_RATE_LIMIT_STRATEGY = "moving-window"


# ---------------------------------------------------------------------------
# Key function
# ---------------------------------------------------------------------------


def _user_id_key(request: Request) -> str:
    """Return the per-user limiter bucket key from the verified JWT.

    The JWT dependency sets ``request.state.user`` to a ``CurrentUser`` whose
    ``id`` is a UUID. We stringify it because slowapi's storage backends key
    on strings.

    If the request reaches this function without an authenticated user we
    raise :class:`RuntimeError`. A shared anonymous bucket would (a) let one
    caller exhaust the quota for every other anonymous caller, and (b) risk
    serving 429 before 401, violating Requirement 7.3. The expected wiring is
    that the analysis router declares the JWT dependency on every limited
    route so FastAPI rejects unauthenticated traffic before slowapi runs.
    """
    user = getattr(request.state, "user", None)
    user_id = getattr(user, "id", None) if user is not None else None
    if user_id is None:
        raise RuntimeError(
            "rate_limit._user_id_key was called without an authenticated user "
            "on request.state. Ensure the analysis router declares the JWT "
            "dependency (Depends(get_current_user)) so unauthenticated "
            "traffic is rejected with 401 before the limiter runs."
        )
    return str(user_id)


# ---------------------------------------------------------------------------
# Limiter singleton
# ---------------------------------------------------------------------------

# Constructed at import time so ``app.state.limiter = limiter`` in main.py
# can wire it without any factory plumbing. Default in-process storage is
# fine for a single-replica dev/test deployment; production swaps in Redis
# via ``storage_uri`` without touching this module's call sites.
limiter: Limiter = Limiter(
    key_func=_user_id_key,
    default_limits=[],            # opt-in per route, never global
    strategy=_RATE_LIMIT_STRATEGY,
    headers_enabled=True,         # X-RateLimit-* and Retry-After on 429
    auto_check=True,              # check on every limited route call
)


# ---------------------------------------------------------------------------
# Public decorator for analysis routes
# ---------------------------------------------------------------------------

F = TypeVar("F", bound=Callable[..., Any])


def analysis_rate_limit(func: F) -> F:
    """Apply the analysis-routes rate limit to a FastAPI endpoint.

    Used like::

        @router.post("/run", dependencies=[Depends(get_current_user)])
        @analysis_rate_limit
        async def run_analysis(request: Request, response: Response, ...):
            ...

    The decorated handler must accept ``request: Request`` (slowapi reads it
    to resolve the key) and ``response: Response`` (slowapi writes the
    ``X-RateLimit-*`` and ``Retry-After`` headers onto it on the success
    path). Both are slowapi requirements, not constraints we add. The
    decorator centralises the limit string so individual routes never have
    to repeat ``ANALYSIS_RATE_LIMIT``.
    """
    return limiter.limit(ANALYSIS_RATE_LIMIT)(func)  # type: ignore[return-value]


# ---------------------------------------------------------------------------
# 429 handler
# ---------------------------------------------------------------------------


def rate_limit_exceeded_handler(
    request: Request, exc: RateLimitExceeded
) -> JSONResponse:
    """Render :class:`RateLimitExceeded` as a 429 with ``Retry-After``.

    Body shape comes from design.md's error contract; the ``Retry-After``
    header is the integer seconds until the user's sliding window has room
    again, computed from slowapi's window stats. We never let
    ``Retry-After`` go negative — clamping at zero matches RFC 9110's
    requirement that the value be a non-negative integer.

    The X-RateLimit-* headers slowapi attaches on top of ours come from its
    private ``_inject_headers`` helper. Reaching for a private method is
    awkward but it is the documented escape hatch: slowapi's own
    ``_rate_limit_exceeded_handler`` does the same thing.
    """
    retry_after_seconds = _retry_after_seconds(request)
    response = JSONResponse(
        status_code=429,
        content={
            "code": "rate_limited",
            "detail": "Too Many Requests",
        },
        headers={"Retry-After": str(retry_after_seconds)},
    )

    view_rate_limit = getattr(request.state, "view_rate_limit", None)
    app_limiter = getattr(request.app.state, "limiter", None)
    if view_rate_limit is not None and app_limiter is not None:
        # slowapi merges its X-RateLimit-* headers and may overwrite our
        # Retry-After with the same seconds value, which is fine.
        response = app_limiter._inject_headers(response, view_rate_limit)
    return response


def _retry_after_seconds(request: Request) -> int:
    """Compute the integer seconds until the request's window resets.

    Returns ``0`` when no rate-limit context is attached (e.g. an exception
    raised before slowapi recorded ``view_rate_limit``); zero is a safe
    "retry now" value that won't mislead clients.
    """
    view_rate_limit = getattr(request.state, "view_rate_limit", None)
    app_limiter = getattr(request.app.state, "limiter", None)
    if view_rate_limit is None or app_limiter is None:
        return 0

    rate_limit_item, args = view_rate_limit
    try:
        # slowapi exposes the underlying ``limits`` strategy as ``.limiter``;
        # ``get_window_stats`` returns ``(reset_epoch, remaining)``.
        reset_epoch, _remaining = app_limiter.limiter.get_window_stats(
            rate_limit_item, *args
        )
    except Exception:
        # Storage hiccup: fall back to "retry now" rather than 500-ing on the
        # 429 path. The user will be re-evaluated against the live counter
        # on their next request.
        return 0

    return max(0, int(reset_epoch - time.time()))
