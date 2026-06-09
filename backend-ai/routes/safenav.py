import os
import requests
import polyline
from datetime import datetime
from typing import List, Dict
from shapely.geometry import LineString, shape
from shapely.errors import GEOSException

# --- CONFIGURATION ---
MAPBOX_ACCESS_TOKEN = os.environ.get("MAPBOX_ACCESS_TOKEN")
if not MAPBOX_ACCESS_TOKEN:
    raise RuntimeError("Missing MAPBOX_ACCESS_TOKEN in environment.")

# Risk engine — loaded once at module import, reused across all requests
try:
    from risk_engine import get_engine as _get_engine
    _risk_engine = _get_engine()
    _ENGINE_AVAILABLE = True
except Exception as _e:
    print(f"[SafeNav] Risk engine unavailable (falling back to zone-only): {_e}")
    _risk_engine = None
    _ENGINE_AVAILABLE = False


# ---------------------------------------------------------------------------
# Zone-based safety analysis (existing DBSCAN / manual zones from Supabase)
# ---------------------------------------------------------------------------

def _extract_zone_geometry(zone: Dict) -> Dict | None:
    import json as _json
    for key in ("boundary", "geometry"):
        val = zone.get(key)
        if isinstance(val, dict) and val.get("type"):
            return val
        if isinstance(val, str):
            try:
                parsed = _json.loads(val)
                if isinstance(parsed, dict) and parsed.get("type"):
                    return parsed
            except (ValueError, TypeError):
                pass
    return None


def _zone_penalty(zone: Dict) -> int:
    risk_level = str(zone.get("risk_level", "")).lower()
    if risk_level in {"high", "red", "critical"}:
        return 50
    if risk_level in {"moderate", "yellow", "medium"}:
        return 20
    return 30


def _analyze_zone_safety(route_geometry: List[tuple], dynamic_zones: List[Dict]) -> Dict:
    """
    Checks route LineString against Supabase dynamic_zones polygons.
    Returns a 0-100 safety score (100 = safest).
    """
    if not dynamic_zones:
        return {"safety_score": 100, "risk_details": 0, "detected_ids": []}

    route_line = LineString([(lng, lat) for lat, lng in route_geometry])
    risk_score = 0
    detected_zones = []

    PROXIMITY_THRESHOLD_DEG = 0.00045  # ~50m
    PROXIMITY_PENALTY = 50

    for zone in dynamic_zones:
        zone_id = zone.get("id")
        zone_geojson = _extract_zone_geometry(zone)
        if not zone_geojson or zone_id in detected_zones:
            continue
        try:
            zone_geom = shape(zone_geojson)
        except (TypeError, ValueError, GEOSException):
            continue

        if route_line.intersects(zone_geom):
            risk_score += _zone_penalty(zone)
            detected_zones.append(zone_id)
        elif route_line.distance(zone_geom) < PROXIMITY_THRESHOLD_DEG:
            risk_score += PROXIMITY_PENALTY
            detected_zones.append(zone_id)

    return {
        "safety_score": max(10, 100 - risk_score),
        "risk_details": len(detected_zones),
        "detected_ids": detected_zones,
    }


# ---------------------------------------------------------------------------
# Main routing function
# ---------------------------------------------------------------------------

def find_safest_route(start_lat, start_lng, end_lat, end_lng, dynamic_zones):
    """
    Fetches routes from Mapbox Directions API, scores each route using:
      1. Multi-factor risk engine (crime, lighting, time, population density)
      2. DBSCAN zone intersection check (Supabase dynamic_zones)
    Returns the safest route with full risk metadata.
    """
    url = (
        f"https://api.mapbox.com/directions/v5/mapbox/walking/"
        f"{start_lng},{start_lat};{end_lng},{end_lat}"
    )
    params = {
        "alternatives": "true",
        "geometries": "polyline",
        "access_token": MAPBOX_ACCESS_TOKEN,
    }

    try:
        print(f"[SafeNav] Directions URL: {url}")
        response = requests.get(url, params=params)
        print(f"[SafeNav] Directions response: {response.status_code}")
        print(f"[SafeNav] Directions body: {response.text[:500]}")
        data = response.json()

        if "routes" not in data or not data["routes"]:
            return {"status": "error", "message": "No routes found from Mapbox", "raw": data}

        current_hour = datetime.now().hour
        scored_routes = []

        for route in data["routes"]:
            decoded_geometry = polyline.decode(route["geometry"])

            # --- Zone-based check ---
            zone_result = _analyze_zone_safety(decoded_geometry, dynamic_zones)

            # --- Multi-factor risk engine check ---
            engine_result = None
            if _ENGINE_AVAILABLE and _risk_engine is not None:
                try:
                    # Convert decoded (lat,lng) tuples to [lng,lat] for engine
                    coords_lnglat = [[pt[1], pt[0]] for pt in decoded_geometry]
                    engine_result = _risk_engine.get_route_risk(coords_lnglat)
                except Exception as ex:
                    print(f"[SafeNav] Risk engine error: {ex}")

            # --- Combine scores ---
            # Zone safety: 0-100 (100=best), convert to risk %: 100 - safety
            zone_risk_pct = 100 - zone_result["safety_score"]

            if engine_result is not None:
                engine_risk_pct = engine_result["route_risk_score"]
                # Blend: 60% engine (multi-factor), 40% zone check
                combined_risk = round(0.6 * engine_risk_pct + 0.4 * zone_risk_pct, 1)
                # Level/color derived from blended score, not raw engine score
                from risk_engine import _level_and_color
                risk_level, risk_color = _level_and_color(combined_risk)
                is_safe = combined_risk <= 50 and zone_result["safety_score"] >= 50
                high_risk_segments = engine_result.get("high_risk_segments", [])
                n_seg = len(high_risk_segments)
                explanation = (
                    f"Avg risk {combined_risk}% | max {engine_result['max_risk_score']}% | "
                    f"{n_seg} high-risk segment(s)"
                )
            else:
                # Fallback: zone-only
                combined_risk = round(zone_risk_pct, 1)
                is_safe = zone_result["safety_score"] >= 50
                risk_level = "high" if combined_risk >= 70 else ("medium" if combined_risk >= 40 else "low")
                risk_color = "#FF3B30" if risk_level == "high" else ("#FF9500" if risk_level == "medium" else "#34C759")
                high_risk_segments = []
                explanation = f"Zone-based risk score: {combined_risk}%"

            scored_routes.append({
                "route_geometry": route["geometry"],
                "duration": route["duration"],
                "distance": route["distance"],
                # Legacy field (kept for Flutter compatibility)
                "safety_score": zone_result["safety_score"],
                # New multi-factor fields
                "risk_score": combined_risk,
                "risk_level": risk_level,
                "risk_color": risk_color,
                "high_risk_segments": high_risk_segments,
                "explanation": explanation,
                "zone_risk_count": zone_result["risk_details"],
            })

        # Sort: lowest combined risk first, then shortest duration
        scored_routes.sort(key=lambda x: (x["risk_score"], x["duration"]))

        winning = scored_routes[0]
        is_route_safe = winning["risk_score"] <= 50 and winning["safety_score"] >= 50

        return {
            "status": "success",
            "is_route_safe": is_route_safe,
            "recommended_route": winning,
            "alternatives": scored_routes[1:],
            # Top-level risk summary for Flutter to consume directly
            "route_risk_score": winning["risk_score"],
            "risk_level": winning["risk_level"],
            "risk_color": winning["risk_color"],
            "high_risk_segments": winning["high_risk_segments"],
            "explanation": winning["explanation"],
        }

    except Exception as e:
        return {"status": "error", "message": str(e)}
