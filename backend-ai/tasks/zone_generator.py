import os
import numpy as np
from dotenv import load_dotenv
from supabase import create_client, Client
from sklearn.cluster import DBSCAN
from shapely.geometry import MultiPoint
from shapely import wkt, concave_hull

# Load environment variables from backend-ai/.env
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))


def generate_dynamic_zones():
    """
    Fetches coordinates from the 'incidents' table, clusters them using DBSCAN
    (with Haversine distance), computes concave hulls, buffers them for street
    width, and inserts them into the 'dynamic_zones' table.
    """
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

    if not url or not key:
        print("ERROR: Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env")
        return

    supabase: Client = create_client(url, key)

    print("Fetching incidents from database...")
    res = supabase.table("incidents").select("latitude,longitude").execute()
    data = res.data

    points = []
    for row in data:
        lat = row.get("latitude")
        lng = row.get("longitude")
        if lat is not None and lng is not None:
            try:
                points.append((float(lat), float(lng)))
            except (TypeError, ValueError):
                pass

    if len(points) < 3:
        print("WARNING: Not enough points to cluster (minimum 3 required). Exiting.")
        return

    print(f"FOUND {len(points)} valid incident coordinates. Running DBSCAN clustering...")

    # Haversine distance requires coordinates in radians
    pts_rad = np.radians(points)

    # 50 meters epsilon, converted to radians based on Earth's radius in meters
    eps_rad = 50.0 / 6371000.0

    db = DBSCAN(eps=eps_rad, min_samples=3, metric='haversine')
    labels = db.fit_predict(pts_rad)

    # Group points by cluster label
    clusters = {}
    for i, label in enumerate(labels):
        if label != -1:  # -1 = noise
            lat, lon = points[i]
            clusters.setdefault(label, []).append((lon, lat))

    if not clusters:
        print("INFO: No clusters formed with the current incidents and epsilon.")
        return

    print(f"FORMED {len(clusters)} valid cluster(s). Generating hulls...")

    insert_payload = []

    # ~15 metres in degrees at Hyderabad latitude
    buffer_degrees = 15.0 / 111320.0

    for label, cluster_pts in clusters.items():
        mp = MultiPoint(cluster_pts)
        hull = concave_hull(mp, ratio=0.3)
        buffered_hull = hull.buffer(buffer_degrees)

        if buffered_hull.geom_type in ['Polygon', 'MultiPolygon']:
            import json
            from shapely.geometry import mapping
            geojson = json.dumps(mapping(buffered_hull))
            insert_payload.append({
                "risk_level": "red",
                "boundary": geojson,
            })

    # Clear old generated zones (delete all, then reinsert)
    print("Deleting prior generated risk zones...")
    try:
        supabase.table("dynamic_zones").delete().neq("id", "00000000-0000-0000-0000-000000000000").execute()
    except Exception as e:
        print(f"ERROR deleting old zones: {e}")

    if insert_payload:
        print(f"Inserting {len(insert_payload)} new dynamic zone(s) into database...")
        try:
            supabase.table("dynamic_zones").insert(insert_payload).execute()
            print("SUCCESS! Dynamic Risk Zones updated.")
        except Exception as e:
            print(f"ERROR inserting new zones: {e}")


if __name__ == "__main__":
    generate_dynamic_zones()
