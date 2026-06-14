export type IncidentStatus = "open" | "acknowledged" | "monitoring" | "resolved" | "escalated";
export type RiskLevel = "green" | "yellow" | "red";

export interface Incident {
  id: string;
  user_id?: string;
  status: IncidentStatus;
  severity: "low" | "medium" | "high";
  latitude: number;
  longitude: number;
  created_at: string;
  updated_at?: string;
  resolved_at?: string;
  zone_id?: string;
  notes?: string;
  assigned_to?: string | null;
  source?: "audio" | "manual" | "device" | "route";
  display_name?: string;
}

export interface LiveLocation {
  user_id: string;
  latitude: number;
  longitude: number;
  heading?: number | null;
  speed?: number | null;
  updated_at: string;
  source_type?: 'online' | 'offline' | 'mesh'; // Connection/presence state
  mesh_hop_count?: number; // New: 0 for direct, >0 for mesh
}

export interface Zone {
  id: string;
  name: string;
  risk_level: RiskLevel;
  polygon_geojson?: any;
}

export interface AuthorityProfile {
  id: string;
  email?: string;
  display_name?: string;
  role: "authority" | "admin";
}
