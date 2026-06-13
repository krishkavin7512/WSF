import os
from pathlib import Path
from datetime import datetime
from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from supabase import Client, create_client

env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path, override=True)

from routes.safenav import find_safest_route

app = FastAPI(title="Sentra AI Backend", version="1.0")

# --- 1. CONFIGURATION & CORS ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- 2. SUPABASE CLIENT ---
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
    raise RuntimeError(
        "Missing SUPABASE_URL and/or SUPABASE_SERVICE_ROLE_KEY in environment."
    )

supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

# --- 3. HELPER FUNCTIONS ---
def _fetch_dynamic_zones() -> List[Dict[str, Any]]:
    response = (
        supabase.table("dynamic_zones")
        .select("id,risk_level,boundary")
        .execute()
    )
    zones = response.data or []
    if not isinstance(zones, list):
        raise HTTPException(status_code=500, detail="Invalid zone payload from Supabase.")
    return zones

# --- 4. DATA MODELS ---
class RouteRequest(BaseModel):
    start_lat: float
    start_lng: float
    end_lat: float
    end_lng: float
    user_id: Optional[str] = "guest"

# --- 5. API ENDPOINTS ---

@app.get("/")
def health_check():
    return {"status": "online", "system": "Sentra AI Backend"}

@app.get("/zones")
def get_danger_zones(simulated_hour: Optional[int] = None):
    """
    Returns High-Risk Zones filtered by TIME.
    Usage: GET /zones?simulated_hour=22 (To test 'Night Mode')
    """
    current_hour = simulated_hour if simulated_hour is not None else datetime.now().hour
    try:
        zones = _fetch_dynamic_zones()
        return {"server_time": f"{current_hour}:00", "count": len(zones), "zones": zones}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to fetch zones: {exc}")

@app.get("/heatmap")
def get_heatmap(
    city: Optional[str] = None,
    hour: Optional[int] = None,
    show_all: bool = False,
):
    """
    Returns heatmap zones from Supabase filtered by city and active hours.
    active_hours='all' → always; 'night' → hour>=20 or hour<7; 'day' → 7<=hour<20
    show_all=true overrides time filtering (demo mode).
    """
    current_hour = hour if hour is not None else datetime.now().hour
    try:
        query = supabase.table("heatmap_zones").select("*")
        if city:
            query = query.eq("city", city)
        result = query.execute()
        zones = result.data or []

        def is_active(zone: Dict[str, Any]) -> bool:
            if show_all:
                return True
            h = zone.get("active_hours", "all")
            if h == "all":
                return True
            if h == "night":
                return current_hour >= 20 or current_hour < 7
            if h == "day":
                return 7 <= current_hour < 20
            return True

        active_zones = [z for z in zones if is_active(z)]
        return {"zones": active_zones, "count": len(active_zones), "hour": current_hour, "city": city or "all"}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to fetch heatmap: {exc}")


@app.post("/get-safe-route")
def calculate_safe_route(request: RouteRequest):
    """
    Phase 2 Logic: Real AI Routing
    """
    print(f"[SafeRoute] Request: {request.start_lat},{request.start_lng} -> {request.end_lat},{request.end_lng}")

    # Zone fetch is best-effort — if it fails, route without safety scoring.
    try:
        dynamic_zones = _fetch_dynamic_zones()
        print(f"[SafeRoute] Loaded {len(dynamic_zones)} zones")
    except Exception as exc:
        print(f"[SafeRoute] Zone fetch failed (non-fatal): {exc}")
        dynamic_zones = []

    result = find_safest_route(
        request.start_lat,
        request.start_lng,
        request.end_lat,
        request.end_lng,
        dynamic_zones,
    )

    # Always return 200 so Flutter can read the status/message field.
    # Raising 500 causes Flutter to receive null and show a generic error.
    print(f"[SafeRoute] Result status: {result.get('status')}")
    return result