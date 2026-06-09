"use client";

import { useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { LiveLocation } from "../types";
import { REAL_USER_LOCATIONS } from '../data/velloreRealData';

const normalizeLocation = (row: any): LiveLocation => ({
  user_id: row.user_id ?? row.id ?? "unknown",
  latitude: Number(row.latitude ?? row.lat ?? 0),
  longitude: Number(row.longitude ?? row.lng ?? 0),
  heading: row.heading ?? row.bearing ?? null,
  speed: row.speed ?? null,
  updated_at: row.updated_at ?? row.timestamp ?? new Date().toISOString(),
  source_type: row.source_type ?? 'online',
  mesh_hop_count: row.mesh_hop_count ?? 0
});

export const useRealtimeLocations = (supabase: SupabaseClient | null, pollingInterval?: number) => {
  // Use real fake user locations
  const realLocations: LiveLocation[] = REAL_USER_LOCATIONS.map(loc => ({
    user_id: loc.user_id,
    latitude: loc.latitude,
    longitude: loc.longitude,
    speed: loc.speed,
    heading: loc.heading,
    accuracy: loc.accuracy,
    updated_at: loc.updated_at,
    source_type: 'online',
    mesh_hop_count: 0
  }));

  // Start empty when Supabase is connected; fake data only when offline
  const [locations, setLocations] = useState<LiveLocation[]>(supabase ? [] : realLocations);

  useEffect(() => {
    if (!supabase) {
      setLocations(realLocations);
      return;
    }

    const fetchLocations = async () => {
      const { data, error } = await supabase
        .from("live_locations")
        .select("user_id,latitude,longitude,heading,speed,updated_at,source_type,mesh_hop_count");

      if (error) {
        console.warn("live_locations fetch error", error.message);
        return;
      }
      if (data) setLocations(data.map(normalizeLocation));
    };

    // Initial fetch
    fetchLocations();

    let intervalId: NodeJS.Timeout | null = null;
    let channel: any = null;

    if (pollingInterval && pollingInterval > 0) {
      // POLLING MODE
      intervalId = setInterval(fetchLocations, pollingInterval);
    } else {
      // REALTIME SUBSCRIPTION MODE
      channel = supabase
        .channel("live-locations-stream")
        .on(
          "postgres_changes",
          { event: "*", schema: "public", table: "live_locations" },
          (payload) => {
            setLocations((prev) => {
              if (payload.eventType === "DELETE") {
                const removedId = payload.old?.user_id ?? payload.old?.id;
                return prev.filter((l) => l.user_id !== removedId);
              }
              const updated = normalizeLocation(payload.new);
              const existing = prev.find((l) => l.user_id === updated.user_id);
              if (existing) {
                return prev.map((l) => (l.user_id === updated.user_id ? updated : l));
              }
              return [updated, ...prev];
            });
          }
        )
        .subscribe();
    }

    return () => {
      if (intervalId) clearInterval(intervalId);
      if (channel) supabase.removeChannel(channel);
    };
  }, [supabase, pollingInterval]);

  return { locations };
};
