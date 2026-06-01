# DevGrowth AI — Backend

FastAPI service that fronts Supabase for auth/data and proxies analysis runs to
an OpenAI-compatible model using each user's BYO key.

## Layout

```
backend/
├── app/
│   ├── api/v1/        # HTTP routers (auth, profile, analysis)
│   ├── core/          # Settings, Supabase client, JWT, Fernet encryption
│   ├── middleware/    # JWT dependency, rate limiting
│   ├── schemas/       # Pydantic request/response models
│   └── services/      # Profile, settings, AI, analysis services
└── tests/
    ├── property/      # Hypothesis property tests
    └── integration/   # FastAPI TestClient end-to-end tests
```

## Quick start

```bash
# 1. Create and activate a virtualenv (Python 3.11+)
python -m venv .venv
source .venv/bin/activate

# 2. Install runtime + dev dependencies
pip install -r requirements.txt

# 3. Configure environment
cp .env.example .env
# …then edit .env with real Supabase / Fernet / AI defaults

# 4. Run the dev server (after task 5.6 wires app/main.py)
uvicorn app.main:app --reload --port 8000

# 5. Run tests
pytest
```

## Environment variables

See [`.env.example`](./.env.example). All variables are required at startup.

| Variable | Purpose |
| --- | --- |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side service-role key (bypasses RLS) |
| `SUPABASE_JWT_SECRET` | HS256 secret used to verify Supabase-issued JWTs |
| `FERNET_KEYS` | Comma-separated Fernet keys, newest first, for AI-key encryption |
| `AI_MODEL_DEFAULT` | Default model identifier when user hasn't overridden it |
| `AI_PROVIDER_BASE_URL_DEFAULT` | Default OpenAI-compatible HTTPS base URL |
