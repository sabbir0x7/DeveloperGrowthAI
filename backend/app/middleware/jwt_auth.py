"""FastAPI dependency that gates protected routes on a valid Supabase JWT.

This module is the API-layer chokepoint for Requirements 1.3, 1.4, and 1.5.
The actual cryptographic work lives in :mod:`app.core.security`; what we add
here is the HTTP-shaped wrapper:

* Read the ``Authorization`` header from the inbound :class:`Request`.
* Hand it to :func:`app.core.security.parse_bearer` and
  :func:`app.core.security.verify_token`.
* Stash the resulting :class:`~app.core.security.CurrentUser` on
  ``request.state.user`` so downstream dependencies (rate limiter keyed by
  user id) and route handlers can read identity without re-decoding the JWT.
* Translate every :class:`~app.core.security.InvalidToken` into an HTTP 401
  with a stable ``WWW-Authenticate: Bearer`` challenge and a ``detail`` body
  carrying the failure code (``invalid_token``, ``token_expired``,
  ``missing_authorization``, ``malformed_authorization``, ``missing_subject``).

The dependency exposes both a callable (``get_current_user``) for use with
``Depends(...)`` and a typed alias (:data:`CurrentUserDep`) so route signatures
read like ``async def me(user: CurrentUserDep): ...``.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException, Request, status

from app.core.security import CurrentUser, InvalidToken, parse_bearer, verify_token

# Standardized challenge header for any 401 we emit. RFC 6750 requires the
# scheme name; clients (and our Dio interceptor) key off it to know a Bearer
# token is required and a refresh attempt is the right reaction.
_WWW_AUTHENTICATE_BEARER = 'Bearer realm="api", charset="UTF-8"'


def get_current_user(request: Request) -> CurrentUser:
    """Resolve the authenticated user for the current request.

    Reads the raw ``Authorization`` header straight off the request (rather
    than declaring a ``Header(...)`` parameter) for two reasons:

    1. We need to distinguish *missing* headers from *malformed* ones, and
       :func:`parse_bearer` already encodes that distinction. Letting FastAPI
       pre-validate the header would collapse those cases into a generic 422.
    2. Stashing ``request.state.user`` requires the :class:`Request` anyway,
       so taking it as the only parameter keeps the dependency surface tiny.

    Any failure - missing header, wrong scheme, bad signature, expired token,
    missing or non-UUID subject - is normalized through
    :class:`InvalidToken` and re-raised as :class:`HTTPException` with status
    401. The exception's ``detail`` is the stable code from
    :class:`InvalidToken` so the frontend can branch on it (e.g. show "session
    expired" vs "please sign in") without parsing free-form messages.

    Returns:
        The verified caller's identity. The same object is also attached to
        ``request.state.user`` so middleware that runs *after* this dependency
        (such as the per-user rate limiter) can read it without re-injecting
        the dependency.
    """
    try:
        token = parse_bearer(request.headers.get("Authorization"))
        user = verify_token(token)
    except InvalidToken as exc:
        # The 401 carries the stable failure code in ``detail`` and the
        # required Bearer challenge so clients know how to recover.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=exc.detail,
            headers={"WWW-Authenticate": _WWW_AUTHENTICATE_BEARER},
        ) from exc

    # Attach to request state so other dependencies (rate limiter keyed by
    # ``request.state.user.id``) and route handlers can read identity without
    # re-resolving this dependency. ``request.state`` is the canonical place
    # for per-request, cross-dependency context in Starlette/FastAPI.
    request.state.user = user
    return user


# Convenience alias so route handlers can write
#     async def handler(user: CurrentUserDep): ...
# instead of the noisier ``Annotated[CurrentUser, Depends(get_current_user)]``.
CurrentUserDep = Annotated[CurrentUser, Depends(get_current_user)]


__all__ = ["CurrentUserDep", "get_current_user"]
