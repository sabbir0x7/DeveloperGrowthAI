# DeveloperGrowthAI

**DeveloperGrowthAI** is an AI-powered career growth and analysis platform built for software developers. By analyzing a developer's GitHub activity, LinkedIn experience, and specific career goals, the platform generates personalized skill gap analyses, actionable feedback, and week-by-week learning roadmaps to help developers reach their dream roles.

---

## 🚀 Features

- **AI-Powered Career Coaching**: Get tailored feedback by comparing your current GitHub and LinkedIn profiles against your specific career goal.
- **Detailed Skill Gap Analysis**: Identifies exact areas where you need to improve (Low, Medium, High gaps) and provides the rationale behind them.
- **Actionable Roadmaps**: Generates step-by-step, week-by-week suggestions to achieve your goals.
- **Dynamic Goal Setting**: Change your career goal anytime from the Settings drawer, and the dashboard will automatically fetch fresh AI insights based on the new target.
- **Bring Your Own Key (BYOK)**: Securely configure your own OpenAI-compatible API key (OpenAI, OpenRouter, Groq, etc.). Keys are encrypted (using Fernet) and safely stored in the backend.
- **Modern Cinematic UI**: Beautiful Dark Mode frontend built with Flutter, featuring glassmorphism, neon accents, and smooth animations.
- **Seamless Authentication**: Powered by Supabase Auth (Passwordless OTP / OAuth).

---

## 🛠️ Tech Stack

### Frontend (Mobile & Web)
- **Framework**: Flutter
- **State Management**: Riverpod (`flutter_riverpod`)
- **Navigation**: GoRouter
- **Networking**: Dio
- **Auth**: `supabase_flutter`
- **UI Design**: Custom Glassmorphism & Neon themes

### Backend
- **Framework**: FastAPI (Python 3.11+)
- **Database**: PostgreSQL (via Supabase)
- **Authentication**: Supabase Auth (JWT Validation)
- **AI Integration**: OpenAI-compatible `/chat/completions` API via `httpx`
- **Security**: Fernet symmetric encryption for user API keys

---

## 📂 Project Structure

```text
DeveloperGrowthAI/
├── backend/                # FastAPI Python Backend
│   ├── app/
│   │   ├── api/v1/         # Route handlers (auth, profile, analysis)
│   │   ├── core/           # Configs, Security, Supabase client
│   │   ├── schemas/        # Pydantic validation models
│   │   └── services/       # AI, GitHub scraping, and profile services
│   └── tests/              # Backend test suite (pytest)
│
├── frontend/               # Flutter Frontend
│   ├── lib/
│   │   ├── core/           # Routing, Theme, Supabase client, Dio interceptors
│   │   ├── features/       # Feature modules (auth, dashboard, onboarding)
│   │   └── shared/         # Reusable widgets (GlassCard, NeonButton, etc.)
│   └── web/                # Web entry point
```

---

## 🚦 Getting Started

### 1. Backend Setup

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Configure environment variables (Supabase URL, Service Role Key, Fernet Key, etc.)
cp .env.example .env

# Run the backend dev server
uvicorn app.main:app --reload --port 8000
```

### 2. Frontend Setup

Ensure you have [Flutter installed](https://docs.flutter.dev/get-started/install).

```bash
cd frontend
flutter pub get

# Run on Chrome (Web)
flutter run -d chrome --web-port 3000

# Or run on an Android/iOS emulator
flutter run
```

---

## 🔒 Security Notes
- The backend communicates with Supabase utilizing a **Service Role Key** to bypass RLS, ensuring strictly scoped queries per user ID.
- User-provided AI keys are never returned to the frontend or logged; they are kept heavily encrypted at rest.
- JWT tokens from Supabase are automatically attached to all outbound Dio HTTP requests by the frontend interceptor.

---

*Designed and developed to empower developers worldwide.*
