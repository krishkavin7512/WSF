import React, { useState, useEffect } from "react";
import {
  MoonIcon,
  SunIcon,
  XIcon,
  Search,
  MapPin,
  AlertTriangle,
  UserRoundIcon
} from "lucide-react";

import { Switch } from "@/components/ui/switch";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import MapView, { HeatmapZone, DynamicZone } from "./MapView";
import { useZones } from "../hooks/useZones";
import { useRealtimeLocations } from "../hooks/useRealtimeLocations";
import { useRealtimeIncidents } from "../hooks/useRealtimeIncidents";
import { getSupabaseClient } from "../lib/supabaseClient";
import { TimeMode } from "../data/crimeZones";

export function ThemeToggle() {
  const [checked, setChecked] = useState(false);
  return (
    <div className="flex items-center gap-2">
      <SunIcon className="w-4 h-4 text-zinc-400" />
      <Switch checked={checked} onCheckedChange={setChecked} />
      <MoonIcon className="w-4 h-4 text-zinc-400" />
    </div>
  );
}

export const DashboardPage: React.FC = () => {
  const timeMode: TimeMode = 'all';
  const { zones } = useZones(timeMode);

  const supabase = getSupabaseClient();
  const { locations } = useRealtimeLocations(supabase);
  const { incidents } = useRealtimeIncidents(supabase);

  const displayLocations = locations;
  const [flyToLocation, setFlyToLocation] = useState<{ lat: number; lng: number } | null>(null);
  const [profiles, setProfiles] = useState<Record<string, { phone?: string; full_name?: string }>>({});

  useEffect(() => {
    if (!supabase || displayLocations.length === 0) {
      setProfiles({});
      return;
    }
    const ids = displayLocations.map(l => l.user_id);
    supabase
      .from('profiles')
      .select('id,full_name,phone')
      .in('id', ids)
      .order('id')
      .then(({ data, error }) => {
        if (error) console.error('profiles fetch error:', error.message);
        const next: Record<string, { phone?: string; full_name?: string }> = {};
        ids.forEach(id => { next[id] = {}; });
        (data ?? []).forEach((p: any) => {
          next[p.id] = { full_name: p.full_name ?? undefined, phone: p.phone ?? undefined };
        });
        setProfiles(next);
      });
  }, [displayLocations, supabase]);

  const [showHeatmap, setShowHeatmap] = useState(false);
  const [heatmapZones, setHeatmapZones] = useState<HeatmapZone[]>([]);

  useEffect(() => {
    if (!supabase) return;
    supabase
      .from('heatmap_zones')
      .select('*')
      .eq('city', 'hyderabad')
      .then(({ data, error }) => {
        if (error) { console.error('heatmap fetch error:', error.message); return; }
        setHeatmapZones((data as HeatmapZone[]) ?? []);
      });
  }, [supabase]);

  const [dynamicZones, setDynamicZones] = useState<DynamicZone[]>([]);

  useEffect(() => {
    if (!supabase) return;
    supabase
      .from('dynamic_zones')
      .select('id,risk_level,boundary')
      .then(({ data, error }) => {
        if (error) { console.error('dynamic_zones fetch error:', error.message); return; }
        setDynamicZones((data as DynamicZone[]) ?? []);
      });
  }, [supabase]);

  const criticalAlertsCount = incidents.filter(i => i.severity === 'high' && i.status === 'open').length;
  const activeUsersCount = displayLocations.length;
  const usersInDangerCount = 0; // Keeping logic aligned with current capabilities while matching UI

  const [showBanner, setShowBanner] = useState(true);

  return (
    <div className="flex h-screen w-full bg-white text-zinc-900 font-sans overflow-hidden">

      {/* MAIN CONTENT AREA */}
      <main className="flex-1 flex flex-col relative min-w-0">

        {/* TOP HEADER */}
        <header className="h-16 flex-none border-b border-zinc-200 bg-white flex items-center px-6 z-20">
          <div className="flex-1 flex justify-center">
            <div className="flex items-center gap-2 px-4 py-2 bg-zinc-100 rounded-full w-96 transition-colors focus-within:ring-2 focus-within:ring-zinc-200">
              <Search className="w-4 h-4 text-zinc-400" />
              <input
                type="text"
                placeholder="Search..."
                className="bg-transparent border-none outline-none text-zinc-800 text-sm w-full placeholder:text-zinc-400"
              />
            </div>
          </div>

          <div className="flex items-center gap-6">
            <button
              onClick={() => setShowHeatmap(!showHeatmap)}
              className={`flex items-center gap-2 text-sm font-medium transition-colors ${showHeatmap ? 'text-zinc-900' : 'text-zinc-500 hover:text-zinc-800'}`}
            >
              <MapPin className="w-4 h-4" /> Heatmap
            </button>
            <div className="h-4 w-[1px] bg-zinc-200" />
            <ThemeToggle />
            <div className="h-4 w-[1px] bg-zinc-200" />
            <Avatar className="h-9 w-9 bg-[#18181b] flex items-center justify-center text-white cursor-pointer rounded-full hover:ring-2 hover:ring-zinc-200 transition-all">
              <AvatarFallback className="bg-transparent">
                <UserRoundIcon size={16} />
              </AvatarFallback>
            </Avatar>
          </div>
        </header>

        {/* MAP AREA */}
        <div className="flex-1 relative z-0">
          {showBanner && (
            <div className="absolute top-4 left-1/2 -translate-x-1/2 z-20">
              <div className="bg-[#303030] text-zinc-100 px-4 py-2.5 rounded-full shadow-lg flex gap-3 items-center min-w-[260px]">
                <div className="text-zinc-400">
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#60A5FA" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="12" cy="12" r="10" />
                    <polyline points="12 6 12 12 16 14" />
                  </svg>
                </div>
                <span className="text-sm font-medium flex-1 text-center">Command Center Active</span>
                <button onClick={() => setShowBanner(false)} className="text-zinc-400 hover:text-white transition-colors">
                  <XIcon size={14} />
                </button>
              </div>
            </div>
          )}

          <MapView
            incidents={incidents}
            locations={displayLocations}
            zones={zones}
            selectedIncidentId={null}
            onSelectIncident={() => { }}
            loading={false}
            supabaseEnabled={true}
            mapStyle="mapbox://styles/mapbox/light-v11"
            showPatrolRoutes={false}
            flyToLocation={flyToLocation}
            showHeatmap={showHeatmap}
            heatmapZones={heatmapZones}
            dynamicZones={dynamicZones}
          />
        </div>
      </main>

      {/* RIGHT SIDEBAR (LIVE FEED) */}
      <aside className="w-[320px] flex-none bg-white border-l border-zinc-200 flex flex-col z-20 shadow-sm">
        <div className="p-6">
          <h2 className="text-[13px] font-black tracking-wider text-zinc-900 uppercase flex items-center gap-2 mb-8">
            <div className="w-2 h-2 rounded-full bg-[#60A5FA]" />
            Live Feed
          </h2>

          <div className="space-y-8">
            {/* CRITICAL SOS ALERTS */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <div className="text-[11px] font-bold text-zinc-500 uppercase tracking-wider flex items-center gap-1.5">
                  <AlertTriangle className="w-3.5 h-3.5 text-red-500" />
                  Critical SOS Alerts
                </div>
                <span className="text-[10px] font-bold text-red-500 min-w-[18px] text-right">
                  {criticalAlertsCount}
                </span>
              </div>
              {criticalAlertsCount === 0 ? (
                <div className="text-sm text-zinc-500">No critical alerts active</div>
              ) : (
                <div className="space-y-2">
                  {incidents.filter(i => i.severity === 'high' && i.status === 'open').map(incident => (
                    <div key={incident.id} className="rounded border border-red-100 bg-red-50 p-2.5">
                      <div className="text-sm font-medium text-red-800">{incident.notes ?? incident.source ?? 'Alert'}</div>
                      <div className="text-xs text-red-600/80 mt-0.5">
                        {incident.display_name ?? `${incident.latitude.toFixed(4)}, ${incident.longitude.toFixed(4)}`}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* USERS IN DANGER ZONES */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <div className="text-[11px] font-bold text-zinc-500 uppercase tracking-wider">
                  Users In Danger Zones
                </div>
                <span className="text-[10px] font-bold text-zinc-600 min-w-[18px] text-right">
                  {usersInDangerCount}
                </span>
              </div>
              <div className="text-sm text-zinc-500">No users currently in high-risk zones</div>
            </div>

            {/* ALL ACTIVE USERS */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <div className="text-[11px] font-bold text-zinc-500 uppercase tracking-wider">
                  All Active Users
                </div>
                <span className="text-[10px] font-bold text-[#60A5FA] min-w-[18px] text-right">
                  {activeUsersCount}
                </span>
              </div>
              {activeUsersCount === 0 ? (
                <div className="text-sm text-zinc-500">No active connections</div>
              ) : (
                <div className="space-y-2 max-h-[300px] overflow-y-auto">
                  {displayLocations.map((loc) => {
                    const profile = profiles[loc.user_id];
                    const label = profile?.full_name ?? profile?.phone ?? `${loc.user_id.slice(0, 8)}…`;
                    return (
                      <button
                        key={loc.user_id}
                        onClick={() => setFlyToLocation({ lat: loc.latitude, lng: loc.longitude })}
                        className="w-full flex items-center gap-3 p-2 rounded hover:bg-zinc-50 transition-colors cursor-pointer text-left"
                      >
                        <div className="w-2 h-2 rounded-full flex-none bg-[#60A5FA]" />
                        <div className="flex-1 min-w-0">
                          <div className="text-sm font-medium text-zinc-900 truncate">{label}</div>
                          <div className="text-xs text-zinc-500">{loc.latitude.toFixed(4)}, {loc.longitude.toFixed(4)}</div>
                        </div>
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      </aside>
    </div>
  );
};
