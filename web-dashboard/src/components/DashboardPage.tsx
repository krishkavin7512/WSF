import React, { useState, useId, useEffect } from "react";
import {
  MoonIcon,
  SunIcon,
  Eclipse,
  XIcon,
  CircleAlertIcon,
  CircleCheckIcon,
  UserRoundIcon,
  Activity,
  Menu,
  LayoutDashboard,
  ShieldAlert,
  Radio,
  Search,
  BarChart3,
  Users,
  MapPin,
  Settings,
  Trash2
} from "lucide-react";

import { Switch } from "@/components/ui/switch";
import { Button } from "@/components/ui/button";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import MapView, { HeatmapZone } from "./MapView";
import { ZoneManagement } from "./ZoneManagement";
import { AnalyticsView } from "./AnalyticsView";
import { IncidentsView } from "./IncidentsView";
import { UsersView } from "./UsersView";
import { RespondersView } from "./RespondersView";
import { PatrolView } from "./PatrolView";
import { Incident, LiveLocation } from "../types";
import { useZones } from "../hooks/useZones";
import { useRealtimeLocations } from "../hooks/useRealtimeLocations";
import { useRealtimeIncidents } from "../hooks/useRealtimeIncidents";
import { TimeMode } from "../data/crimeZones";
import { getSupabaseClient } from "../lib/supabaseClient";

/* --- COMPONENT 1: THEME SWITCH --- */
export function ThemeToggle() {
  const id = useId();
  const [checked, setChecked] = useState(true);
  return (
    <div className="group inline-flex items-center gap-2" data-state={checked ? "checked" : "unchecked"}>
      <span className="cursor-pointer text-right text-zinc-500 group-data-[state=checked]:text-zinc-600 transition-colors">
        <SunIcon size={16} />
      </span>
      <Switch checked={checked} onCheckedChange={setChecked} />
      <span className="cursor-pointer text-left text-zinc-500 group-data-[state=unchecked]:text-zinc-600 transition-colors">
        <MoonIcon size={16} />
      </span>
    </div>
  );
}

/* --- COMPONENT 2: DAY/NIGHT ZONE MODE TOGGLE --- */
export function DayNightToggle({ mode, onModeChange }: { mode: TimeMode; onModeChange: (mode: TimeMode) => void }) {
  return (
    <div className="inline-flex items-center gap-2 bg-[#18181b] border border-white/10 rounded-lg p-1">
      <button
        onClick={() => onModeChange('day')}
        className={`px-3 py-1.5 rounded-md text-xs font-medium uppercase tracking-wide transition-all ${mode === 'day'
          ? 'bg-amber-500/20 text-amber-400 border border-amber-500/30'
          : 'text-zinc-500 hover:text-zinc-300'
          }`}
      >
        <SunIcon className="w-3 h-3 inline mr-1" />
        Day
      </button>
      <button
        onClick={() => onModeChange('night')}
        className={`px-3 py-1.5 rounded-md text-xs font-medium uppercase tracking-wide transition-all ${mode === 'night'
          ? 'bg-indigo-500/20 text-indigo-400 border border-indigo-500/30'
          : 'text-zinc-500 hover:text-zinc-300'
          }`}
      >
        <MoonIcon className="w-3 h-3 inline mr-1" />
        Night
      </button>
      <button
        onClick={() => onModeChange('all')}
        className={`px-3 py-1.5 rounded-md text-xs font-medium uppercase tracking-wide transition-all ${mode === 'all'
          ? 'bg-cyan-500/20 text-cyan-400 border border-cyan-500/30'
          : 'text-zinc-500 hover:text-zinc-300'
          }`}
      >
        All
      </button>
    </div>
  );
}

/* --- COMPONENT 2: SYSTEM BANNER --- */
export function SystemBanner() {
  const [isVisible, setIsVisible] = useState(true);
  if (!isVisible) return null;
  return (
    <div className="absolute top-4 left-1/2 -translate-x-1/2 z-20 animate-in fade-in slide-in-from-top-4 duration-500">
      <div className="dark bg-[#18181b]/80 border border-white/10 px-4 py-2 text-zinc-100 backdrop-blur-md rounded-full shadow-2xl flex gap-2 items-center min-w-[340px]">
        <Eclipse className="shrink-0 opacity-60 text-cyan-400" size={16} />
        <p className="text-xs font-medium">System Online: High Performance Mode Active</p>
        <Button variant="ghost" size="icon" className="h-6 w-6 ml-auto hover:bg-white/10 text-zinc-400 hover:text-white" onClick={() => setIsVisible(false)}>
          <XIcon size={14} />
        </Button>
      </div>
    </div>
  );
}

/* --- COMPONENT 3: ALERT CARD (DANGER) --- */
export function DangerAlert({ title, location }: { title: string, location: string }) {
  return (
    <div className="rounded-lg border border-red-500/30 bg-red-500/10 px-4 py-3 mb-3 hover:bg-red-500/15 transition-colors">
      <div className="flex gap-3">
        <CircleAlertIcon className="mt-0.5 shrink-0 text-red-500 animate-pulse" size={16} />
        <div className="grow space-y-1">
          <p className="font-medium text-sm text-red-400 uppercase tracking-wide">{title}</p>
          <p className="text-xs text-red-300/70">{location}</p>
        </div>
      </div>
    </div>
  );
}

/* --- COMPONENT 4: SUCCESS CARD (SAFE) --- */
export function SuccessAlert({ message }: { message: string }) {
  return (
    <div className="rounded-lg border border-emerald-500/20 bg-emerald-500/5 px-4 py-3 mb-3 hover:bg-emerald-500/10 transition-colors">
      <p className="text-sm flex items-center text-emerald-400 font-medium">
        <CircleCheckIcon className="me-3 text-emerald-500" size={16} />
        {message}
      </p>
    </div>
  );
}

/* --- COMPONENT 5: AVATAR --- */
export function UserProfile() {
  return (
    <Avatar className="h-9 w-9 border border-white/10 transition-colors hover:border-cyan-500/50 cursor-pointer">
      <AvatarFallback className="bg-zinc-800 text-zinc-400">
        <UserRoundIcon size={16} />
      </AvatarFallback>
    </Avatar>
  );
}

// --- NAVIGATION ITEMS ---
const NAV_ITEMS = [
  { id: 'dashboard', icon: LayoutDashboard, label: 'Dashboard' },
  { id: 'zones', icon: MapPin, label: 'Zones' },
  { id: 'patrol', icon: Radio, label: 'Patrol' }
];

// --- MAIN PAGE LAYOUT ---

export const DashboardPage: React.FC = () => {
  // Time mode state for day/night zone filtering
  const [timeMode, setTimeMode] = useState<TimeMode>('all');

  // Real-time data hooks
  const { zones, addZone, deleteZone } = useZones(timeMode);

  // Connect to Supabase for real-time locations and incidents
  const supabase = getSupabaseClient();
  const { locations } = useRealtimeLocations(supabase);
  const { incidents, openIncidents, loading: incidentsLoading, acknowledgeIncident, resolveIncident } = useRealtimeIncidents(supabase);

  // Fallback to empty array if no data, or keep empty to wait for stream
  const displayLocations = locations;

  // Active view state
  const [activeView, setActiveView] = useState<'dashboard' | 'zones' | 'patrol' | 'analytics' | 'incidents' | 'users' | 'responders' | 'settings'>('dashboard');

  // Fly-to state: set when user clicks a beacon in the Active Users list
  const [flyToLocation, setFlyToLocation] = useState<{ lat: number; lng: number } | null>(null);

  // Profile map: user_id → { phone, full_name } fetched from profiles table
  const [profiles, setProfiles] = useState<Record<string, { phone?: string; full_name?: string }>>({});

  useEffect(() => {
    if (!supabase || displayLocations.length === 0) {
      setProfiles({});
      return;
    }
    // Rebuild profiles map fresh on every locations change so re-logins with
    // a new name (same UUID) always show current data rather than cached data.
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

  // Heatmap
  const [showHeatmap, setShowHeatmap] = useState(false);
  const [heatmapZones, setHeatmapZones] = useState<HeatmapZone[]>([]);

  useEffect(() => {
    if (!supabase) return;
    supabase
      .from('heatmap_zones')
      .select('*')
      .then(({ data, error }) => {
        if (error) console.error('heatmap fetch error:', error.message);
        setHeatmapZones((data as HeatmapZone[]) ?? []);
      });
  }, [supabase]);

  return (
    <div className="flex h-screen w-full bg-[#09090b] text-zinc-100 font-sans overflow-hidden dark">

      {/* 1. SIDEBAR (Left, Fixed, w-16) - Minimal Rail */}
      <aside className="w-16 flex-none bg-[#09090b] border-r border-white/10 flex flex-col items-center py-6 gap-6 z-30">
        <div className="w-10 h-10 rounded-xl bg-cyan-500/10 flex items-center justify-center border border-cyan-500/20 text-cyan-400 shadow-[0_0_15px_rgba(34,211,238,0.1)]">
          <Activity className="w-6 h-6" />
        </div>

        <nav className="flex-1 flex flex-col gap-4 mt-4">
          {NAV_ITEMS.map((item) => {
            const Icon = item.icon;
            const isActive = activeView === item.id;

            return (
              <button
                key={item.id}
                onClick={() => setActiveView(item.id as typeof activeView)}
                className={`p-3 rounded-lg transition-all duration-200 group relative ${isActive
                  ? "text-cyan-400"
                  : "text-zinc-500 hover:text-zinc-300 hover:bg-white/5"
                  }`}
                title={item.label}
              >
                <Icon className="w-5 h-5" />
                {isActive && (
                  <span className="absolute left-0 top-1/2 -translate-y-1/2 w-1 h-6 bg-cyan-400 rounded-r-full" />
                )}
              </button>
            );
          })}
        </nav>

        <button className="p-3 text-zinc-500 hover:text-white transition-colors">
          <Menu className="w-5 h-5" />
        </button>
      </aside>

      {/* 2. CENTER CANVAS (Flex-1) */}
      <main className="flex-1 flex flex-col relative min-w-0">

        {/* HEADER (Top, h-14) - Floating/Docked */}
        <header className="h-14 flex-none border-b border-white/10 bg-[#09090b]/90 backdrop-blur-md flex items-center justify-between px-6 z-20">
          <div className="flex items-center gap-4 text-sm text-zinc-400">
            <div className="flex items-center gap-2 px-3 py-1.5 bg-[#18181b] rounded-full border border-white/5 w-64 focus-within:border-cyan-500/30 transition-colors">
              <Search className="w-4 h-4 text-zinc-500" />
              <input
                type="text"
                placeholder="Search zones, IDs..."
                className="bg-transparent border-none outline-none text-zinc-300 text-xs w-full placeholder:text-zinc-600"
              />
            </div>
          </div>

          <div className="flex items-center gap-4">
            <div className="text-xs text-zinc-500 font-mono">
              View: <span className="text-cyan-400 font-semibold">{NAV_ITEMS.find(i => i.id === activeView)?.label}</span>
            </div>
            <DayNightToggle mode={timeMode} onModeChange={setTimeMode} />
            <div className="h-4 w-[1px] bg-white/10" />
            <button
              onClick={() => setShowHeatmap(h => !h)}
              title="Toggle Heatmap"
              className={`flex items-center gap-1.5 px-3 py-1 rounded-md text-xs font-medium transition-colors ${showHeatmap ? 'bg-red-500/20 text-red-400 border border-red-500/30' : 'bg-white/5 text-zinc-400 border border-white/10 hover:border-white/20'}`}
            >
              <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
              Heatmap
            </button>
            <div className="h-4 w-[1px] bg-white/10" />
            <ThemeToggle />
            <div className="h-4 w-[1px] bg-white/10" />
            <UserProfile />
          </div>
        </header>

        {/* CONTENT AREA - Conditional Rendering Based on Active View */}
        <div className="flex-1 relative z-0">
          {activeView === 'dashboard' && (
            <>
              <SystemBanner />
              <MapView
                incidents={incidents}
                locations={displayLocations}
                zones={zones}
                selectedIncidentId={null}
                onSelectIncident={() => { }}
                loading={false}
                supabaseEnabled={false}
                mapStyle="mapbox://styles/mapbox/dark-v11"
                showPatrolRoutes={false}
                flyToLocation={flyToLocation}
                showHeatmap={showHeatmap}
                heatmapZones={heatmapZones}
              />
            </>
          )}

          {activeView === 'analytics' && (
            <AnalyticsView zones={zones} />
          )}

          {activeView === 'incidents' && (
            <IncidentsView />
          )}

          {activeView === 'users' && (
            <UsersView locations={displayLocations} />
          )}

          {activeView === 'zones' && (
            <ZoneManagement
              zones={zones}
              onAddZone={() => {
                console.log('Add zone clicked');
              }}
              onEditZone={(zoneId) => {
                console.log('Edit zone:', zoneId);
              }}
              onDeleteZone={(zoneId) => {
                console.log('Delete zone:', zoneId);
              }}
              onSaveZone={addZone}
              onDeleteZoneById={deleteZone}
            />
          )}

          {activeView === 'responders' && (
            <RespondersView />
          )}

          {activeView === 'patrol' && (
            <PatrolView />
          )}

          {activeView === 'settings' && (
            <div className="h-full flex items-center justify-center">
              <div className="text-center">
                <Settings className="w-16 h-16 text-zinc-400 mx-auto mb-4" />
                <h2 className="text-2xl font-bold mb-2">System Settings</h2>
                <p className="text-zinc-500">Configure alerts, notifications, and integrations</p>
                <div className="mt-6 text-xs text-zinc-600">Coming soon...</div>
              </div>
            </div>
          )}
        </div>
      </main>

      {/* 3. CONTROL PANEL (Right, w-80) - Glass Drawer */}
      <aside className="w-80 flex-none bg-[#18181b]/95 border-l border-white/10 backdrop-blur-xl z-20 flex flex-col overflow-hidden shadow-2xl">

        <div className="p-5 border-b border-white/5 flex items-center justify-between">
          <h2 className="text-sm font-semibold tracking-wider text-zinc-100 uppercase flex items-center gap-2">
            <div className="w-2 h-2 rounded-full bg-cyan-500 animate-pulse" />
            Live Feed
          </h2>
          <Button variant="ghost" size="icon" className="h-8 w-8 text-zinc-500 hover:text-white">
            <Menu className="w-4 h-4" />
          </Button>
        </div>

        <div className="flex-1 overflow-y-auto p-4">

          {/* Only show these sections when NOT on Zones view */}
          {activeView !== 'zones' && (
            <>
              {/* ACTIVE USERS — live beacons from Supabase */}
              <div className="mb-6">
                <div className="text-[10px] uppercase font-bold text-zinc-500 mb-3 tracking-widest px-1 flex items-center justify-between">
                  <span>Active Users</span>
                  <span className="text-cyan-500 font-mono">{displayLocations.length}</span>
                </div>
                {displayLocations.length === 0 ? (
                  <div className="text-xs text-zinc-600 px-1 py-2">No active users online</div>
                ) : (
                  <div className="space-y-1 max-h-48 overflow-y-auto">
                    {displayLocations.map((loc) => {
                      const minsAgo = Math.round(
                        (Date.now() - new Date(loc.updated_at).getTime()) / 60000
                      );
                      const isRecent = minsAgo < 2;
                      const profile = profiles[loc.user_id];
                      const label = profile?.full_name ?? profile?.phone ?? `${loc.user_id.slice(0, 8)}…`;
                      return (
                        <button
                          key={loc.user_id}
                          onClick={() => setFlyToLocation({ lat: loc.latitude, lng: loc.longitude })}
                          className="w-full flex items-center gap-3 p-2.5 rounded-lg hover:bg-white/5 transition-colors cursor-pointer text-left group"
                        >
                          <div className={`w-2 h-2 rounded-full flex-none ${isRecent ? 'bg-cyan-500 animate-pulse' : 'bg-zinc-600'}`} />
                          <div className="flex-1 min-w-0">
                            <div className="text-xs text-zinc-300 font-mono truncate">
                              {label}
                            </div>
                            <div className="text-[10px] text-zinc-600">
                              {loc.latitude.toFixed(4)}, {loc.longitude.toFixed(4)}
                            </div>
                          </div>
                          <span className={`text-[10px] font-bold px-1.5 py-0.5 rounded flex-none ${isRecent ? 'bg-cyan-500/20 text-cyan-400' : 'bg-zinc-700 text-zinc-400'}`}>
                            {minsAgo === 0 ? 'now' : `${minsAgo}m`}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>

              <div className="mb-6">
                <div className="text-[10px] uppercase font-bold text-zinc-500 mb-3 tracking-widest px-1 flex items-center justify-between">
                  <span>Critical Alerts</span>
                  <span className="text-red-400 font-mono">{incidents.filter(i => i.severity === 'high' && i.status === 'open').length}</span>
                </div>
                {incidentsLoading ? (
                  <div className="text-xs text-zinc-600 px-1 py-2 animate-pulse">Loading alerts...</div>
                ) : incidents.filter(i => i.severity === 'high' && i.status === 'open').length === 0 ? (
                  <div className="text-xs text-zinc-600 px-1 py-2">No critical alerts</div>
                ) : (
                  incidents
                    .filter(i => i.severity === 'high' && i.status === 'open')
                    .slice(0, 3)
                    .map(incident => (
                      <DangerAlert
                        key={incident.id}
                        title={incident.notes ?? incident.source ?? 'Alert'}
                        location={incident.display_name ?? `${incident.latitude.toFixed(4)}, ${incident.longitude.toFixed(4)}`}
                      />
                    ))
                )}
              </div>

              <div className="mb-6">
                <div className="text-[10px] uppercase font-bold text-zinc-500 mb-3 tracking-widest px-1">System Status</div>
                <SuccessAlert message="System Optimal" />
              </div>

              <div>
                <div className="text-[10px] uppercase font-bold text-zinc-500 mb-3 tracking-widest px-1">Audit Log</div>
                <div className="space-y-1">
                  {incidents.length === 0 && !incidentsLoading ? (
                    <div className="text-xs text-zinc-600 px-1 py-2">No incidents reported</div>
                  ) : (
                    incidents.slice(0, 3).map((incident, i) => (
                      <div key={incident.id ?? i} className="flex items-center gap-3 p-3 rounded-lg hover:bg-white/5 transition-colors cursor-pointer group">
                        <div className="w-1 h-8 bg-zinc-700 rounded-full group-hover:bg-cyan-500 transition-colors" />
                        <div className="flex-1">
                          <div className="text-xs text-zinc-300">{incident.display_name ?? incident.source ?? 'Incident reported'}</div>
                          <div className="text-[10px] text-zinc-600" suppressHydrationWarning>{new Date(incident.created_at).toLocaleTimeString()}</div>
                        </div>
                      </div>
                    ))
                  )}
                </div>
              </div>
            </>
          )}

          {/* Active Zones Section - Only shown when Zones view is active */}
          {activeView === 'zones' && (
            <div>
              <div className="mb-3 px-1">
                <div className="text-[10px] uppercase font-bold text-zinc-500 tracking-widest">Active Zones</div>
              </div>

              <div className="space-y-2 max-h-64 overflow-y-auto custom-scrollbar">
                {/* Red Zones */}
                {zones.filter(z => z.severity === 'HIGH').map((zone, i) => (
                  <div key={`red-${zone.id || i}`} className="bg-red-500/10 border border-red-500/20 rounded-lg p-3 hover:bg-red-500/15 transition-colors group">
                    <div className="flex items-center gap-2">
                      <div className="w-2 h-2 rounded-full bg-red-500 animate-pulse" />
                      <span className="text-xs font-medium text-red-400 truncate flex-1">{zone.location}</span>
                      <button
                        type="button"
                        onClick={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          console.log('Delete clicked for:', zone.location, 'isDefault:', zone.isDefault);
                          if (zone.isDefault) {
                            window.alert("Cannot delete predefined zones. These are system-defined safety zones.");
                          } else {
                            console.log('Directly deleting zone:', zone.id);
                            deleteZone(zone.id);
                          }
                        }}
                        className="p-2 text-zinc-400 hover:text-red-400 hover:bg-red-500/20 rounded transition-colors cursor-pointer"
                        title="Delete zone"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                    <div className="text-[10px] text-zinc-500 mt-1 pl-4">{zone.type}</div>
                  </div>
                ))}

                {/* Yellow Zones */}
                {zones.filter(z => z.severity === 'MODERATE').map((zone, i) => (
                  <div key={`yellow-${zone.id || i}`} className="bg-yellow-500/10 border border-yellow-500/20 rounded-lg p-3 hover:bg-yellow-500/15 transition-colors group">
                    <div className="flex items-center gap-2">
                      <div className="w-2 h-2 rounded-full bg-yellow-500" />
                      <span className="text-xs font-medium text-yellow-400 truncate flex-1">{zone.location}</span>
                      <button
                        type="button"
                        onClick={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          console.log('Delete clicked for:', zone.location, 'isDefault:', zone.isDefault);
                          if (zone.isDefault) {
                            window.alert("Cannot delete predefined zones. These are system-defined safety zones.");
                          } else {
                            console.log('Directly deleting zone:', zone.id);
                            deleteZone(zone.id);
                          }
                        }}
                        className="p-2 text-zinc-400 hover:text-yellow-400 hover:bg-yellow-500/20 rounded transition-colors cursor-pointer"
                        title="Delete zone"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                    <div className="text-[10px] text-zinc-500 mt-1 pl-4">{zone.type}</div>
                  </div>
                ))}
              </div>

              {/* Zone Stats */}
              <div className="grid grid-cols-2 gap-2 mt-3">
                <div className="bg-red-500/5 border border-red-500/10 rounded-lg p-2 text-center">
                  <div className="text-lg font-bold text-red-400">{zones.filter(z => z.severity === 'HIGH').length}</div>
                  <div className="text-[9px] text-zinc-500 uppercase">Red Zones</div>
                </div>
                <div className="bg-yellow-500/5 border border-yellow-500/10 rounded-lg p-2 text-center">
                  <div className="text-lg font-bold text-yellow-400">{zones.filter(z => z.severity === 'MODERATE').length}</div>
                  <div className="text-[9px] text-zinc-500 uppercase">Yellow Zones</div>
                </div>
              </div>
            </div>
          )}

        </div>

        <div className="p-4 border-t border-white/5 bg-[#18181b]">
          <Button className="w-full bg-cyan-500/10 hover:bg-cyan-500/20 text-cyan-400 border border-cyan-500/20 uppercase tracking-widest text-xs font-bold py-6">
            Initiate Protocol
          </Button>
        </div>
      </aside>
    </div>
  );
};
