"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Incident } from "../types";

const mockIncidents: Incident[] = [
  {
    id: "mock-1",
    user_id: "user-101",
    status: "open",
    severity: "high",
    latitude: 12.9696,
    longitude: 79.1589,
    created_at: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
    notes: "Audio model detected scream near Katpadi road",
    source: "audio",
    display_name: "Student A",
  },
  {
    id: "mock-2",
    user_id: "user-102",
    status: "acknowledged",
    severity: "medium",
    latitude: 12.9724,
    longitude: 79.1551,
    created_at: new Date(Date.now() - 25 * 60 * 1000).toISOString(),
    notes: "Manual SOS",
    assigned_to: "officer-3",
    source: "device",
    display_name: "Student B",
  },
  {
    id: "mock-3",
    user_id: "user-103",
    status: "resolved",
    severity: "low",
    latitude: 12.9669,
    longitude: 79.1602,
    created_at: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(),
    resolved_at: new Date(Date.now() - 90 * 60 * 1000).toISOString(),
    notes: "Zone patrol cleared",
    source: "manual",
    display_name: "Student C",
  },
];

// DB stores severity as integer (1=low, 2=medium, 3=high).
// TypeScript/dashboard expects the string form. Convert either way.
const normalizeSeverity = (val: any): 'low' | 'medium' | 'high' => {
  if (val === 'high' || val === 'medium' || val === 'low') return val;
  if (val === 3 || val === '3') return 'high';
  if (val === 2 || val === '2') return 'medium';
  if (val === 1 || val === '1') return 'low';
  return 'medium';
};

const normalizeIncident = (row: any): Incident => ({
  id: row.id?.toString() ?? crypto.randomUUID(),
  user_id: row.user_id ?? undefined,
  status: row.status ?? "open",
  severity: normalizeSeverity(row.severity),
  latitude: Number(row.latitude ?? row.lat ?? 0),
  longitude: Number(row.longitude ?? row.lng ?? 0),
  created_at: row.created_at ?? new Date().toISOString(),
  updated_at: row.updated_at ?? undefined,
  resolved_at: row.resolved_at ?? undefined,
  zone_id: row.zone_id ?? undefined,
  notes: row.notes ?? undefined,
  assigned_to: row.assigned_to ?? null,
  source: row.source ?? row.trigger_source ?? undefined,
  display_name: row.display_name ?? row.user_name ?? undefined,
});

export const useRealtimeIncidents = (supabase: SupabaseClient | null) => {
  const [incidents, setIncidents] = useState<Incident[]>(mockIncidents);
  const [loading, setLoading] = useState<boolean>(!!supabase);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }

    let active = true;
    setLoading(true);

    supabase
      .from("incidents")
      .select(
        "id,user_id,status,severity,latitude,longitude,created_at,updated_at,resolved_at,zone_id,notes,assigned_to,source,display_name"
      )
      .order("created_at", { ascending: false })
      .then(({ data, error: fetchError }) => {
        if (!active) return;
        if (fetchError) {
          setError(fetchError.message);
          setLoading(false);
          return;
        }
        if (data) {
          setIncidents(data.map(normalizeIncident));
        }
        setLoading(false);
      });

    const channel = supabase
      .channel("incidents-stream")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "incidents" },
        (payload) => {
          setIncidents((prev) => {
            if (payload.eventType === "INSERT") {
              const incoming = normalizeIncident(payload.new);
              return [incoming, ...prev.filter((i) => i.id !== incoming.id)];
            }
            if (payload.eventType === "UPDATE") {
              const incoming = normalizeIncident(payload.new);
              return prev.map((i) => (i.id === incoming.id ? incoming : i));
            }
            if (payload.eventType === "DELETE") {
              const removedId = payload.old?.id?.toString();
              return prev.filter((i) => i.id !== removedId);
            }
            return prev;
          });
        }
      )
      .subscribe();

    return () => {
      active = false;
      supabase.removeChannel(channel);
    };
  }, [supabase]);

  const acknowledgeIncident = useCallback(
    async (incidentId: string) => {
      if (!incidentId) return { error: "Missing incident id" };
      if (!supabase) {
        setIncidents((prev) => prev.map((i) => (i.id === incidentId ? { ...i, status: "acknowledged" } : i)));
        return { error: null };
      }
      const { error: updateError } = await supabase
        .from("incidents")
        .update({ status: "acknowledged", updated_at: new Date().toISOString() })
        .eq("id", incidentId);
      if (updateError) setError(updateError.message);
      return { error: updateError?.message ?? null };
    },
    [supabase]
  );

  const resolveIncident = useCallback(
    async (incidentId: string) => {
      if (!incidentId) return { error: "Missing incident id" };
      if (!supabase) {
        setIncidents((prev) => prev.map((i) => (i.id === incidentId ? { ...i, status: "resolved", resolved_at: new Date().toISOString() } : i)));
        return { error: null };
      }
      const now = new Date().toISOString();
      const { error: updateError } = await supabase
        .from("incidents")
        .update({ status: "resolved", resolved_at: now, updated_at: now })
        .eq("id", incidentId);
      if (updateError) setError(updateError.message);
      return { error: updateError?.message ?? null };
    },
    [supabase]
  );

  const openIncidents = useMemo(() => incidents.filter((i) => i.status !== "resolved"), [incidents]);

  return { incidents, openIncidents, loading, error, acknowledgeIncident, resolveIncident };
};
