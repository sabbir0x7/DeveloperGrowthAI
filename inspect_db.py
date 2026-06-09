import asyncio
import os
from dotenv import load_dotenv

# Try to load from backend/.env or root .env
load_dotenv("backend/.env")
load_dotenv(".env")

from app.core.supabase_client import get_supabase
from app.core.config import get_settings

try:
    settings = get_settings()
    print("SUPABASE_URL:", settings.SUPABASE_URL)
    sb = get_supabase()
    res = sb.table("user_settings").select("*").limit(1).execute()
    print("user_settings row:", res.data[0] if res.data else "empty table")
    
    res2 = sb.table("users").select("*").limit(1).execute()
    print("users row:", res2.data[0] if res2.data else "empty table")
except Exception as e:
    print("Error:", e)
