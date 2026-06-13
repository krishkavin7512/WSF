"""
Generates all three synthetic datasets for the Hyderabad risk engine.
Run once: python data/generate_datasets.py
Outputs: hyderabad_crimes.csv, hyderabad_lighting.csv, hyderabad_population.csv
"""
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
import os

rng = np.random.default_rng(42)
OUT = os.path.dirname(__file__)


# ---------------------------------------------------------------------------
# 1. hyderabad_crimes.csv
# ---------------------------------------------------------------------------

AREAS = [
    # (name, lat, lng, count, risk_label)
    ("Old City/Charminar",    17.3616, 78.4747, 120, "high"),
    ("Dilsukhnagar",          17.3688, 78.5247,  80, "high"),
    ("Mehdipatnam",           17.3933, 78.4344,  70, "high"),
    ("Secunderabad Station",  17.4399, 78.4983,  60, "medium"),
    ("Koti",                  17.3850, 78.4867,  50, "medium"),
    ("LB Nagar",              17.3494, 78.5521,  40, "medium"),
    ("Ameerpet",              17.4374, 78.4487,  40, "medium"),
    ("Jubilee Hills",         17.4290, 78.4072,  50, "medium"),
    ("Himayat Sagar/Lords",   17.3422, 78.3663,  10, "low"),
    ("Gachibowli",            17.4401, 78.3489,  10, "low"),
    # New areas added for demo coverage
    ("Falaknuma",             17.3318, 78.4812,  55, "high"),
    ("Chandrayangutta",       17.3389, 78.5001,  45, "high"),
    ("Santoshnagar",          17.3567, 78.5123,  30, "medium"),
    ("Rajendra Nagar",        17.3234, 78.4456,  25, "medium"),
    ("Himayat Sagar Fringe",  17.3350, 78.3750,  15, "medium"),
]

CRIME_TYPES = ["eve_teasing", "assault", "robbery", "harassment", "theft", "stalking"]
SEVERITY_MAP = {"low": 1, "medium": 2, "high": 3}

# Weight crime types toward moderate severity
AREA_SEVERITY = {
    "high": ["high", "high", "medium", "medium", "medium", "low"],
    "medium": ["medium", "medium", "medium", "low", "low", "high"],
    "low_medium": ["medium", "low", "low", "low", "medium", "low"],
    "low": ["low", "low", "low", "medium", "low", "low"],
}

# Night hours (20-04) weighted 3x more likely
ALL_HOURS = list(range(24))
HOUR_WEIGHTS = [3 if (h >= 20 or h < 5) else 1 for h in ALL_HOURS]
HOUR_WEIGHTS_NORM = np.array(HOUR_WEIGHTS) / sum(HOUR_WEIGHTS)

BASE_DATE = datetime(2023, 1, 1)
DATE_RANGE_DAYS = 730  # 2 years

rows = []
for area_name, center_lat, center_lng, count, risk_label in AREAS:
    for _ in range(count):
        # Gaussian scatter ~300m radius (0.003 degrees ≈ 333m)
        lat = rng.normal(center_lat, 0.003)
        lng = rng.normal(center_lng, 0.003)
        crime_type = rng.choice(CRIME_TYPES)
        severity_word = rng.choice(AREA_SEVERITY[risk_label])
        severity = SEVERITY_MAP[severity_word]
        hour = int(rng.choice(ALL_HOURS, p=HOUR_WEIGHTS_NORM))
        days_offset = int(rng.integers(0, DATE_RANGE_DAYS))
        date = (BASE_DATE + timedelta(days=days_offset)).strftime("%Y-%m-%d")
        rows.append({
            "latitude": round(lat, 6),
            "longitude": round(lng, 6),
            "crime_type": crime_type,
            "severity": severity,
            "hour": hour,
            "date": date,
            "area_name": area_name,
        })

crimes_df = pd.DataFrame(rows)
crimes_df.to_csv(os.path.join(OUT, "hyderabad_crimes.csv"), index=False)
print(f"OK hyderabad_crimes.csv - {len(crimes_df)} rows")


# ---------------------------------------------------------------------------
# 2. hyderabad_lighting.csv
# ---------------------------------------------------------------------------

# Grid bounds covering Hyderabad
LAT_MIN, LAT_MAX = 17.20, 17.55
LNG_MIN, LNG_MAX = 78.25, 78.65
GRID_STEPS = 15  # 15x15 = 225 points

# Reference lighting scores per named area
LIGHTING_REFS = [
    # (lat, lng, score, name)
    (17.4290, 78.4072, 1.0, "Jubilee Hills"),
    (17.4315, 78.4316, 1.0, "Banjara Hills"),
    (17.4401, 78.3489, 0.95, "Gachibowli"),
    (17.4500, 78.3800, 0.95, "Madhapur/HITEC City"),
    (17.4374, 78.4487, 0.70, "Ameerpet"),
    (17.4399, 78.4983, 0.70, "Secunderabad"),
    (17.3850, 78.4867, 0.50, "Koti"),
    (17.3616, 78.4747, 0.40, "Old City/Charminar"),
    (17.3933, 78.4344, 0.40, "Mehdipatnam"),
    (17.3688, 78.5247, 0.45, "Dilsukhnagar"),
    (17.3494, 78.5521, 0.45, "LB Nagar"),
    (17.3422, 78.3663, 0.20, "Himayat Sagar/Lords"),
    (17.2800, 78.3200, 0.10, "ORR South Fringe"),
    (17.5300, 78.5500, 0.15, "ORR North Fringe"),
]

# Build reference arrays for interpolation
ref_lats = np.array([r[0] for r in LIGHTING_REFS])
ref_lngs = np.array([r[1] for r in LIGHTING_REFS])
ref_scores = np.array([r[2] for r in LIGHTING_REFS])
ref_names = [r[3] for r in LIGHTING_REFS]

lat_grid = np.linspace(LAT_MIN, LAT_MAX, GRID_STEPS)
lng_grid = np.linspace(LNG_MIN, LNG_MAX, GRID_STEPS)

lighting_rows = []
for lat in lat_grid:
    for lng in lng_grid:
        # Inverse-distance weighted interpolation from reference points
        dists = np.sqrt((ref_lats - lat)**2 + (ref_lngs - lng)**2)
        dists = np.maximum(dists, 1e-6)
        weights = 1.0 / dists**2
        score = float(np.sum(weights * ref_scores) / np.sum(weights))
        score = round(np.clip(score + rng.normal(0, 0.03), 0.05, 1.0), 3)
        # Find nearest named area
        nearest_idx = int(np.argmin(dists))
        lighting_rows.append({
            "latitude": round(lat, 6),
            "longitude": round(lng, 6),
            "lighting_score": score,
            "area_name": ref_names[nearest_idx],
        })

lighting_df = pd.DataFrame(lighting_rows)
lighting_df.to_csv(os.path.join(OUT, "hyderabad_lighting.csv"), index=False)
print(f"OK hyderabad_lighting.csv - {len(lighting_df)} rows")


# ---------------------------------------------------------------------------
# 3. hyderabad_population.csv
# ---------------------------------------------------------------------------

POPULATION_REFS = [
    # (lat, lng, density_score, name)
    (17.3616, 78.4747, 1.0, "Old City/Charminar"),
    (17.3850, 78.4867, 1.0, "Koti"),
    (17.4399, 78.4983, 0.95, "Secunderabad"),
    (17.3688, 78.5247, 0.85, "Dilsukhnagar"),
    (17.4374, 78.4487, 0.80, "Ameerpet"),
    (17.3494, 78.5521, 0.80, "LB Nagar"),
    (17.3933, 78.4344, 0.75, "Mehdipatnam"),
    (17.4290, 78.4072, 0.60, "Jubilee Hills"),
    (17.4315, 78.4316, 0.55, "Banjara Hills"),
    (17.4401, 78.3489, 0.40, "Gachibowli"),
    (17.4500, 78.3800, 0.35, "Madhapur/HITEC City"),
    (17.3422, 78.3663, 0.20, "Himayat Sagar/Lords"),
    (17.2800, 78.3200, 0.10, "ORR South Fringe"),
    (17.5300, 78.5500, 0.12, "ORR North Fringe"),
]

pop_ref_lats = np.array([r[0] for r in POPULATION_REFS])
pop_ref_lngs = np.array([r[1] for r in POPULATION_REFS])
pop_ref_scores = np.array([r[2] for r in POPULATION_REFS])
pop_ref_names = [r[3] for r in POPULATION_REFS]

population_rows = []
for lat in lat_grid:
    for lng in lng_grid:
        dists = np.sqrt((pop_ref_lats - lat)**2 + (pop_ref_lngs - lng)**2)
        dists = np.maximum(dists, 1e-6)
        weights = 1.0 / dists**2
        score = float(np.sum(weights * pop_ref_scores) / np.sum(weights))
        score = round(np.clip(score + rng.normal(0, 0.03), 0.05, 1.0), 3)
        nearest_idx = int(np.argmin(dists))
        population_rows.append({
            "latitude": round(lat, 6),
            "longitude": round(lng, 6),
            "density_score": score,
            "area_name": pop_ref_names[nearest_idx],
        })

population_df = pd.DataFrame(population_rows)
population_df.to_csv(os.path.join(OUT, "hyderabad_population.csv"), index=False)
print(f"OK hyderabad_population.csv - {len(population_df)} rows")

print("All datasets generated successfully.")
