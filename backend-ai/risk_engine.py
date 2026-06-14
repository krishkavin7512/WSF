"""
Multi-factor risk scoring engine for Hyderabad SafeNav.
Loads synthetic datasets once and provides fast KD-tree spatial lookups.
"""
import math
import os
from datetime import datetime
from typing import List, Optional

import numpy as np
import pandas as pd
from scipy.spatial import KDTree

_DATA_DIR = os.path.join(os.path.dirname(__file__), "data")

# Weighted factors
_W_CRIME   = 0.40
_W_TIME    = 0.25
_W_LIGHT   = 0.20
_W_POP     = 0.15

# Radius for crime incident lookup (degrees; ~0.003 deg ≈ 333m)
_CRIME_RADIUS_DEG = 0.003

# Recency decay: incidents older than this many days count as half
_RECENCY_HALF_LIFE_DAYS = 180


def _time_score(hour: int) -> float:
    """Returns 0-100 risk score based on hour of day."""
    if 0 <= hour < 5:
        return 90.0
    if 5 <= hour < 7:
        return 40.0
    if 7 <= hour < 20:
        return 10.0
    if 20 <= hour < 22:
        return 60.0
    return 80.0  # 22-24


def _population_score(density: float, hour: int) -> float:
    """
    High density during day = safer (low score).
    Low density at night = more dangerous (high score).
    """
    is_night = hour >= 20 or hour < 6
    if is_night:
        # Low density at night → high risk
        return round((1.0 - density) * 80.0 + 10.0, 1)
    else:
        # High density during day → low risk
        return round((1.0 - density) * 40.0, 1)


def _level_and_color(score: float):
    if score >= 70:
        return "high", "#FF3B30"
    if score >= 40:
        return "medium", "#FF9500"
    return "low", "#34C759"


# 8 compass bearings (clockwise from north) used to fan out candidate "safe
# spots" around the user. Human labels go straight into the LLM context.
_COMPASS_8 = [
    (0,   "north"),
    (45,  "north-east"),
    (90,  "east"),
    (135, "south-east"),
    (180, "south"),
    (225, "south-west"),
    (270, "west"),
    (315, "north-west"),
]

# ~111.32 km per degree of latitude (longitude shrinks by cos(lat)).
_M_PER_DEG = 111320.0


def _offset_latlng(lat: float, lng: float, north_m: float, east_m: float):
    """Shift a point by (north_m, east_m) metres and return the new lat/lng."""
    d_lat = north_m / _M_PER_DEG
    d_lng = east_m / (_M_PER_DEG * math.cos(math.radians(lat)))
    return lat + d_lat, lng + d_lng


def _spot_strengths(factors: dict) -> List[str]:
    """
    Translate a spot's risk factors (0-100, higher = worse) into plain-language
    *safety* strengths the LLM can quote. Time-of-day is excluded because it is
    identical for every nearby spot and so can't differentiate them.
    """
    strengths = []
    if factors.get("lighting_score", 100) <= 40:
        strengths.append("well-lit")
    if factors.get("population_score", 100) <= 40:
        strengths.append("usually busy")
    if factors.get("crime_score", 100) <= 20:
        strengths.append("low recent crime")
    return strengths


class HyderabadRiskEngine:
    def __init__(self):
        crimes_path = os.path.join(_DATA_DIR, "hyderabad_crimes.csv")
        lighting_path = os.path.join(_DATA_DIR, "hyderabad_lighting.csv")
        population_path = os.path.join(_DATA_DIR, "hyderabad_population.csv")

        self._crimes = pd.read_csv(crimes_path, parse_dates=["date"])
        self._lighting = pd.read_csv(lighting_path)
        self._population = pd.read_csv(population_path)

        # KD-trees for fast lookups
        self._crime_tree = KDTree(
            self._crimes[["latitude", "longitude"]].values
        )
        self._light_tree = KDTree(
            self._lighting[["latitude", "longitude"]].values
        )
        self._pop_tree = KDTree(
            self._population[["latitude", "longitude"]].values
        )

        self._today = datetime.now()
        print("[RiskEngine] Loaded datasets: "
              f"{len(self._crimes)} crimes, "
              f"{len(self._lighting)} lighting points, "
              f"{len(self._population)} population points")

    # ------------------------------------------------------------------
    def _crime_score(self, lat: float, lng: float) -> float:
        # Find all incidents within radius
        indices = self._crime_tree.query_ball_point(
            [lat, lng], r=_CRIME_RADIUS_DEG
        )
        if not indices:
            return 0.0

        total_weight = 0.0
        for i in indices:
            row = self._crimes.iloc[i]
            severity = float(row["severity"])  # 1-3
            age_days = (self._today - row["date"]).days
            recency = 2 ** (-age_days / _RECENCY_HALF_LIFE_DAYS)
            total_weight += severity * recency

        # Normalize: ~10 high-severity recent incidents → 100
        return float(min(total_weight / 10.0 * 100.0, 100.0))

    def _lighting_score(self, lat: float, lng: float) -> float:
        _, idx = self._light_tree.query([lat, lng])
        raw = float(self._lighting.iloc[idx]["lighting_score"])
        # Dark = high risk
        return round((1.0 - raw) * 100.0, 1)

    def _pop_score(self, lat: float, lng: float, hour: int) -> float:
        _, idx = self._pop_tree.query([lat, lng])
        density = float(self._population.iloc[idx]["density_score"])
        return _population_score(density, hour)

    # ------------------------------------------------------------------
    def get_risk_score(
        self,
        lat: float,
        lng: float,
        hour: Optional[int] = None,
    ) -> dict:
        if hour is None:
            hour = datetime.now().hour

        cs = self._crime_score(lat, lng)
        ts = _time_score(hour)
        ls = self._lighting_score(lat, lng)
        ps = self._pop_score(lat, lng, hour)

        final = (
            _W_CRIME * cs
            + _W_TIME  * ts
            + _W_LIGHT * ls
            + _W_POP   * ps
        )
        final = round(min(final, 100.0), 1)
        level, color = _level_and_color(final)

        # Build human-readable explanation
        factors_sorted = sorted(
            [("crime", cs), ("lighting", ls), ("time", ts), ("population", ps)],
            key=lambda x: -x[1],
        )
        top = [f"{n} ({v:.0f}%)" for n, v in factors_sorted if v >= 40]
        if top:
            explanation = f"{level.capitalize()} risk: {', '.join(top[:2])}"
        else:
            explanation = "Low risk area at this time"

        return {
            "risk_score": final,
            "risk_level": level,
            "risk_color": color,
            "factors": {
                "crime_score":      round(cs, 1),
                "time_score":       round(ts, 1),
                "lighting_score":   round(ls, 1),
                "population_score": round(ps, 1),
            },
            "explanation": explanation,
        }

    # ------------------------------------------------------------------
    def find_safe_spots(
        self,
        lat: float,
        lng: float,
        hour: Optional[int] = None,
        max_results: int = 3,
        radii_m: tuple = (300, 600),
    ) -> dict:
        """
        Scan a ring of points around the user and surface the safest reachable
        spots, so the assistant can answer "what's the safest spot near me?"
        with a concrete direction + distance instead of a vague platitude.

        Returns {"here": <full risk dict for the user's point>,
                 "safe_spots": [ {direction, distance_m, risk_level,
                                  risk_score, strengths, lat, lng}, ... ]}.
        Spots are ranked safest-first and, when possible, restricted to those
        meaningfully safer than the user's current location.
        """
        if hour is None:
            hour = datetime.now().hour

        here = self.get_risk_score(lat, lng, hour)

        candidates = []
        for dist in radii_m:
            for bearing, label in _COMPASS_8:
                north = dist * math.cos(math.radians(bearing))
                east = dist * math.sin(math.radians(bearing))
                clat, clng = _offset_latlng(lat, lng, north, east)
                res = self.get_risk_score(clat, clng, hour)
                candidates.append({
                    "lat": round(clat, 6),
                    "lng": round(clng, 6),
                    "direction": label,
                    "distance_m": int(dist),
                    "risk_score": res["risk_score"],
                    "risk_level": res["risk_level"],
                    "strengths": _spot_strengths(res["factors"]),
                })

        # Safest first; break ties by proximity so we point to the *closest*
        # equally-safe spot.
        candidates.sort(key=lambda c: (c["risk_score"], c["distance_m"]))

        # Prefer spots clearly safer than where the user stands (≥5 pts lower).
        # If nothing qualifies (already in a low-risk area), still return the
        # calmest nearby points so the assistant has something concrete.
        safer = [c for c in candidates if c["risk_score"] + 5 < here["risk_score"]]
        chosen = (safer or candidates)[:max_results]

        return {"here": here, "safe_spots": chosen}

    # ------------------------------------------------------------------
    def get_route_risk(self, coordinates: List[List[float]]) -> dict:
        """
        coordinates: list of [lng, lat] pairs (Mapbox geometry order).
        Samples every ~100m (≈0.001 deg) and returns aggregated risk.
        """
        if not coordinates:
            return {"risk_score": 0, "risk_level": "low", "risk_color": "#34C759",
                    "high_risk_segments": [], "explanation": "No route data"}

        hour = datetime.now().hour
        scores = []
        high_risk_segments = []

        # Sample along route
        sampled = []
        STEP = 0.001  # ~111m per degree; 0.001 ≈ 111m
        for i in range(len(coordinates) - 1):
            p1 = coordinates[i]
            p2 = coordinates[i + 1]
            lng1, lat1 = p1[0], p1[1]
            lng2, lat2 = p2[0], p2[1]
            seg_len = ((lng2 - lng1)**2 + (lat2 - lat1)**2) ** 0.5
            n_samples = max(1, int(seg_len / STEP))
            for j in range(n_samples):
                t = j / n_samples
                sampled.append([lng1 + t * (lng2 - lng1), lat1 + t * (lat2 - lat1)])

        # Always include final point
        sampled.append(coordinates[-1])

        for point in sampled:
            lng, lat = point[0], point[1]
            result = self.get_risk_score(lat, lng, hour)
            scores.append(result["risk_score"])
            if result["risk_score"] >= 70:
                high_risk_segments.append({"lng": round(lng, 6), "lat": round(lat, 6),
                                           "score": result["risk_score"]})

        avg_risk = round(float(np.mean(scores)), 1)
        max_risk = round(float(np.max(scores)), 1)
        level, color = _level_and_color(avg_risk)

        is_safe = max_risk <= 70 and avg_risk <= 50

        explanation = (
            f"Avg risk {avg_risk}% | max {max_risk}% | "
            f"{len(high_risk_segments)} high-risk segment(s)"
        )

        return {
            "is_route_safe": is_safe,
            "route_risk_score": avg_risk,
            "max_risk_score": max_risk,
            "risk_level": level,
            "risk_color": color,
            "high_risk_segments": high_risk_segments[:20],  # cap response size
            "explanation": explanation,
            "sampled_points": len(sampled),
        }


# Module-level singleton — initialized once when safenav.py imports it
_engine: Optional[HyderabadRiskEngine] = None


def get_engine() -> HyderabadRiskEngine:
    global _engine
    if _engine is None:
        _engine = HyderabadRiskEngine()
    return _engine
