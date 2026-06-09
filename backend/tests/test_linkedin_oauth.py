import pytest
from fastapi.testclient import TestClient
from uuid import uuid4
import respx
import httpx
from unittest.mock import MagicMock, patch

from app.main import create_app
from app.core.config import get_settings
from app.core.supabase_client import get_supabase
from backend.tests.property.test_profile_endpoints import _mint_token

@pytest.fixture
def client(monkeypatch):
    # Setup environments
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "test-secret-jwt-key")
    monkeypatch.setenv("FERNET_KEYS", "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM=")
    monkeypatch.setenv("LINKEDIN_CLIENT_ID", "linkedin-id")
    monkeypatch.setenv("LINKEDIN_CLIENT_SECRET", "linkedin-secret")
    monkeypatch.setenv("LINKEDIN_REDIRECT_URI", "http://localhost:8000/api/v1/auth/linkedin/callback")

    get_settings.cache_clear()
    
    # Mock supabase client
    mock_sb = MagicMock()
    monkeypatch.setattr("app.api.v1.linkedin_oauth.get_supabase", lambda: mock_sb)
    
    app = create_app()
    return TestClient(app), mock_sb

def test_linkedin_connect_requires_auth(client):
    test_client, _ = client
    response = test_client.get("/api/v1/auth/linkedin/connect")
    assert response.status_code == 401

def test_linkedin_connect_returns_url(client):
    test_client, _ = client
    user_id = str(uuid4())
    token = _mint_token(user_id)
    
    with patch("app.middleware.jwt_auth.jwt.decode") as mock_decode:
        mock_decode.return_value = {
            "sub": user_id,
            "aud": "authenticated",
            "email": "test@example.com"
        }
        
        response = test_client.get(
            "/api/v1/auth/linkedin/connect",
            headers={"Authorization": f"Bearer {token}"}
        )
        
        assert response.status_code == 200
        data = response.json()
        assert "authorize_url" in data
        assert "linkedin-id" in data["authorize_url"]
        assert "openid" in data["authorize_url"]
        assert user_id in data["authorize_url"]

@respx.mock
def test_linkedin_callback_success(client):
    test_client, mock_sb = client
    user_id = str(uuid4())
    
    # Mock database update call
    mock_update = MagicMock()
    mock_sb.table.return_value.update.return_value.eq.return_value.execute = mock_update
    
    # Mock token exchange
    token_route = respx.post("https://www.linkedin.com/oauth/v2/accessToken").respond(
        status_code=200,
        json={"access_token": "fake-access-token"}
    )
    
    # Mock user info retrieval
    userinfo_route = respx.get("https://api.linkedin.com/v2/userinfo").respond(
        status_code=200,
        json={
            "sub": "linkedin-sub-1234",
            "name": "Jane Doe",
            "given_name": "Jane",
            "family_name": "Doe",
            "email": "jane.doe@example.com"
        }
    )
    
    response = test_client.get(
        f"/api/v1/auth/linkedin/callback?code=somecode&state={user_id}",
        follow_redirects=False
    )
    
    assert response.status_code == 307  # Redirect
    assert "linkedin=success" in response.headers["location"]
    assert token_route.called
    assert userinfo_route.called
    
    # Verify DB update was triggered with formatted summary
    mock_sb.table.assert_called_with("users")
    mock_sb.table.return_value.update.assert_called_once()
    args = mock_sb.table.return_value.update.call_args[0][0]
    assert "Jane Doe" in args["linkedin_pdf_text"]
    assert "jane.doe@example.com" in args["linkedin_pdf_text"]
    assert "linkedin-sub-1234" in args["linkedin_pdf_text"]
    assert args["linkedin_url"] == "https://linkedin.com/in/connected"

@respx.mock
def test_linkedin_callback_invalid_state(client):
    test_client, _ = client
    
    response = test_client.get(
        "/api/v1/auth/linkedin/callback?code=somecode&state=not-a-uuid",
        follow_redirects=False
    )
    
    assert response.status_code == 307
    assert "linkedin=error" in response.headers["location"]
