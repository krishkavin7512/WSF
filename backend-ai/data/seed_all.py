"""
Seeds the Supabase database with synthetic crime incidents and generates
dynamic risk zones via DBSCAN clustering.

COMMAND TO SEED DATABASE AND GENERATE ZONES:
    cd backend-ai && python data/seed_all.py
"""
import os
import sys
import pandas as pd
from dotenv import load_dotenv

# Load .env from backend-ai/
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))

from supabase import create_client, Client

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

if not SUPABASE_URL or not SUPABASE_KEY:
    print("ERROR: Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env")
    sys.exit(1)

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

DATA_DIR = os.path.dirname(__file__)
crimes_path = os.path.join(DATA_DIR, "hyderabad_crimes.csv")

# --- Step 1: Insert incidents ---
print("Clearing existing synthetic incidents ...")
supabase.table("incidents").delete().eq("source", "synthetic").execute()
print("Existing synthetic incidents deleted.")

print("Reading hyderabad_crimes.csv ...")
df = pd.read_csv(crimes_path)

records = []
for _, row in df.iterrows():
    records.append({
        "latitude": float(row["latitude"]),
        "longitude": float(row["longitude"]),
        "severity": int(row["severity"]),
        "source": "synthetic",
        "notes": f"{row['crime_type']} | {row.get('area_name', '')} | hour:{int(row['hour'])}",
    })

print(f"Inserting {len(records)} incidents into Supabase ...")
BATCH = 100
inserted = 0
errors = 0
for i in range(0, len(records), BATCH):
    batch = records[i:i + BATCH]
    try:
        supabase.table("incidents").insert(batch).execute()
        inserted += len(batch)
        print(f"  {inserted}/{len(records)} inserted...")
    except Exception as e:
        print(f"  ERROR on batch {i//BATCH + 1}: {e}")
        errors += 1

print(f"Done. {inserted} rows inserted, {errors} batch errors.")

# --- Step 2: Run zone generator ---
print("\nRunning DBSCAN zone generator ...")
try:
    # zone_generator.py is in tasks/ subfolder
    tasks_dir = os.path.join(os.path.dirname(__file__), '..', 'tasks')
    sys.path.insert(0, tasks_dir)
    from zone_generator import generate_dynamic_zones
    generate_dynamic_zones()
    print("Zone generation complete.")
except Exception as e:
    print(f"Zone generator error: {e}")

# --- Summary ---
print("\n--- SEED SUMMARY ---")
try:
    count = supabase.table("incidents").select("id", count="exact").execute()
    print(f"Total incidents in DB: {count.count}")
except Exception:
    pass
try:
    zones = supabase.table("dynamic_zones").select("id", count="exact").execute()
    print(f"Total dynamic zones in DB: {zones.count}")
except Exception:
    pass
print("Seed complete.")
