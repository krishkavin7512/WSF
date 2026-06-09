import React, { useEffect, useRef, useState } from 'react';
import mapboxgl from 'mapbox-gl';
import 'mapbox-gl/dist/mapbox-gl.css';
import { Incident, LiveLocation } from '../types';
import { Zone } from '../hooks/useZones';
import { REAL_USER_PROFILES, PATROL_ROUTES } from '../data/velloreRealData';

mapboxgl.accessToken = process.env.NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN || '';

interface MapViewProps {
  incidents?: Incident[];
  locations?: LiveLocation[];
  zones?: Zone[];
  selectedIncidentId?: string | null;
  onSelectIncident?: (id: string) => void;
  loading?: boolean;
  supabaseEnabled?: boolean;
  showHeatmap?: boolean;
  mapStyle?: string;
  showPatrolRoutes?: boolean;
  flyToLocation?: { lat: number; lng: number } | null;
}

// Helper: Check if point is inside a circle (for zone detection)
function isPointInZone(lat: number, lng: number, zone: Zone): boolean {
  const R = 6371; // Earth radius in km
  const dLat = (zone.lat - lat) * Math.PI / 180;
  const dLon = (zone.lng - lng) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat * Math.PI / 180) * Math.cos(zone.lat * Math.PI / 180) *
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  const distance = R * c * 1000; // Convert to meters

  return distance <= (zone.radius || 200);
}

const MapView: React.FC<MapViewProps> = ({
  incidents = [],
  locations = [],
  zones = [],
  selectedIncidentId,
  onSelectIncident,
  loading = false,
  supabaseEnabled = false,
  showHeatmap = false,
  mapStyle = 'mapbox://styles/mapbox/dark-v11',
  showPatrolRoutes = false,
  flyToLocation = null
}) => {
  const mapContainer = useRef<HTMLDivElement>(null);
  const map = useRef<mapboxgl.Map | null>(null);
  // State for popup
  const [popupInfo, setPopupInfo] = useState<{ x: number, y: number, user: any } | null>(null);
  const [mapLoaded, setMapLoaded] = useState(false);
  const [pulsePhase, setPulsePhase] = useState(0); // For pulsing animation

  // Initialize map
  useEffect(() => {
    if (map.current || !mapContainer.current) return;

    map.current = new mapboxgl.Map({
      container: mapContainer.current,
      style: mapStyle,
      center: [78.3663, 17.3422], // Lords Institute of Engineering & Technology, Hyderabad
      zoom: 15,
      pitch: 0,
      attributionControl: false,
      renderWorldCopies: false // Prevent coordinate confusion
    });

    map.current.on('load', () => {
      setMapLoaded(true);

      // Add patrol routes (lines)
      PATROL_ROUTES.forEach((route, idx) => {
        map.current?.addSource(`patrol-route-${idx}`, {
          type: 'geojson',
          data: {
            type: 'Feature',
            geometry: {
              type: 'LineString',
              coordinates: route.coordinates
            },
            properties: { name: route.name, officer: route.officer }
          }
        });

        map.current?.addLayer({
          id: `patrol-route-line-${idx}`,
          type: 'line',
          source: `patrol-route-${idx}`,
          paint: {
            'line-color': route.color,
            'line-width': 3,
            'line-opacity': 0.7,
            'line-dasharray': [2, 2]
          }
        });
      });

      // Add single source for users
      map.current?.addSource('users-source', {
        type: 'geojson',
        data: { type: 'FeatureCollection', features: [] }
      });

      // User Beacon Circle (Inner Blue)
      map.current?.addLayer({
        id: 'users-layer',
        type: 'circle',
        source: 'users-source',
        paint: {
          'circle-radius': 5, // Smaller beacon
          'circle-color': '#3B82F6',
          'circle-opacity': 1
        }
      });

      // User Beacon Border (White Stroke)
      map.current?.addLayer({
        id: 'users-layer-border',
        type: 'circle',
        source: 'users-source',
        paint: {
          'circle-radius': 5,
          'circle-color': 'transparent',
          'circle-stroke-color': '#FFFFFF',
          'circle-stroke-width': 1.5
        }
      });

      // Danger Zone Pulsing Ring (Red) - Outer
      map.current?.addLayer({
        id: 'users-pulse-red',
        type: 'circle',
        source: 'users-source',
        filter: ['==', ['get', 'inRedZone'], true],
        paint: {
          'circle-radius': 10,
          'circle-color': 'transparent',
          'circle-stroke-color': '#EF4444',
          'circle-stroke-width': 2,
          'circle-stroke-opacity': 0.7
        }
      });

      // Warning Zone Pulsing Ring (Yellow) - Outer
      map.current?.addLayer({
        id: 'users-pulse-yellow',
        type: 'circle',
        source: 'users-source',
        filter: ['all', ['==', ['get', 'inYellowZone'], true], ['!=', ['get', 'inRedZone'], true]],
        paint: {
          'circle-radius': 9,
          'circle-color': 'transparent',
          'circle-stroke-color': '#F59E0B',
          'circle-stroke-width': 1.5,
          'circle-stroke-opacity': 0.6
        }
      });

      // --- INTERACTION ---

      // Change cursor on hover
      map.current?.on('mouseenter', 'users-layer', () => {
        map.current!.getCanvas().style.cursor = 'pointer';
      });
      map.current?.on('mouseleave', 'users-layer', () => {
        map.current!.getCanvas().style.cursor = '';
      });

      // Right Click (Context Menu) - Listen on all user-related layers
      const handleContextMenu = (e: mapboxgl.MapLayerMouseEvent) => {
        const feature = e.features?.[0];
        if (!feature) return;

        // Prevent default map context menu
        e.preventDefault();

        const userId = feature.properties?.userId;
        const userProfile = REAL_USER_PROFILES.find(u => u.user_id === userId) || {
          user_id: userId,
          name: "Unknown User",
          phone: "N/A",
          emergencyContact: "N/A",
          bloodGroup: "N/A"
        };

        setPopupInfo({
          x: e.point.x,
          y: e.point.y,
          user: userProfile
        });
      };

      // Attach to all user layers
      map.current?.on('contextmenu', 'users-layer', handleContextMenu);
      map.current?.on('contextmenu', 'users-layer-border', handleContextMenu);
      map.current?.on('contextmenu', 'users-pulse-red', handleContextMenu);
      map.current?.on('contextmenu', 'users-pulse-yellow', handleContextMenu);

      // Close popup on map click
      map.current?.on('click', () => {
        setPopupInfo(null);
      });
    });

    return () => {
      map.current?.remove();
      map.current = null;
    };
  }, [mapStyle]);

  // Update User Beacons (Single Source Update)
  useEffect(() => {
    if (!map.current || !mapLoaded) return;
    const source = map.current.getSource('users-source') as mapboxgl.GeoJSONSource;
    if (!source) return;

    const features: any[] = locations.map(loc => {
      // Check zones
      let inRedZone = false;
      let inYellowZone = false;
      zones.forEach(zone => {
        if (isPointInZone(loc.latitude, loc.longitude, zone)) {
          if (zone.severity === 'HIGH') inRedZone = true;
          if (zone.severity === 'MODERATE') inYellowZone = true;
        }
      });

      return {
        type: 'Feature',
        geometry: {
          type: 'Point',
          coordinates: [loc.longitude, loc.latitude]
        },
        properties: {
          userId: loc.user_id,
          inRedZone,
          inYellowZone
        }
      };
    });

    source.setData({
      type: 'FeatureCollection',
      features: features
    });

    console.log(`✓ Updated ${locations.length} beacons via single source`);

  }, [locations, mapLoaded, zones]);

  // Pulsing animation timer
  useEffect(() => {
    if (!mapLoaded) return;
    const interval = setInterval(() => {
      setPulsePhase(p => (p + 1) % 60); // 60 frames cycle
    }, 50); // 20 FPS
    return () => clearInterval(interval);
  }, [mapLoaded]);

  // Apply pulse animation to layers
  useEffect(() => {
    if (!map.current || !mapLoaded) return;

    // Calculate pulse values (oscillate radius and opacity)
    const t = pulsePhase / 60;
    const pulseRadius = 8 + Math.sin(t * Math.PI * 2) * 4; // 8-12 range
    const sinVal = (1 + Math.sin(t * Math.PI * 2)) / 2; // 0-1, never negative
    const pulseOpacity = 0.3 + sinVal * 0.4; // 0.3-0.7 range

    // Update red pulse layer
    if (map.current.getLayer('users-pulse-red')) {
      map.current.setPaintProperty('users-pulse-red', 'circle-radius', pulseRadius);
      map.current.setPaintProperty('users-pulse-red', 'circle-stroke-opacity', pulseOpacity);
    }

    // Update yellow pulse layer (slightly smaller)
    if (map.current.getLayer('users-pulse-yellow')) {
      map.current.setPaintProperty('users-pulse-yellow', 'circle-radius', pulseRadius - 2);
      map.current.setPaintProperty('users-pulse-yellow', 'circle-stroke-opacity', pulseOpacity * 0.8);
    }
  }, [pulsePhase, mapLoaded]);

  // Fly to location when sidebar user is clicked
  useEffect(() => {
    if (!map.current || !mapLoaded || !flyToLocation) return;
    map.current.flyTo({
      center: [flyToLocation.lng, flyToLocation.lat],
      zoom: 17,
      duration: 1200
    });
  }, [flyToLocation, mapLoaded]);

  // Toggle patrol routes visibility based on prop
  useEffect(() => {
    if (!map.current || !mapLoaded) return;

    PATROL_ROUTES.forEach((_, idx) => {
      const layerId = `patrol-route-line-${idx}`;
      if (map.current?.getLayer(layerId)) {
        map.current.setLayoutProperty(layerId, 'visibility', showPatrolRoutes ? 'visible' : 'none');
      }
    });
  }, [showPatrolRoutes, mapLoaded]);

  // Render Zones as Circles (Existing logic, keep as is for now or refactor similarly if needed)
  useEffect(() => {
    if (!map.current || !mapLoaded) return;
    // ... (keeping existing zone rendering logic for now to minimize risk, 
    // but ideally should be single source too)

    // Remove existing zone layers
    zones.forEach((_, idx) => {
      const circleId = `zone-circle-${idx}`;
      const borderId = `zone-circle-border-${idx}`;
      if (map.current!.getLayer(circleId)) map.current!.removeLayer(circleId);
      if (map.current!.getLayer(borderId)) map.current!.removeLayer(borderId);
      if (map.current!.getSource(circleId)) map.current!.removeSource(circleId);
    });

    // Add new zone circles
    zones.forEach((zone, idx) => {
      const color = zone.severity === 'HIGH' ? '#FF4D4D' : '#FFD700';
      const radiusInMeters = zone.radius || 200;
      const center = [zone.lng, zone.lat];
      const radiusInKm = radiusInMeters / 1000;
      const points = 64;
      const coords: number[][] = [];

      for (let i = 0; i < points; i++) {
        const angle = (i / points) * 2 * Math.PI;
        const dx = radiusInKm * Math.cos(angle);
        const dy = radiusInKm * Math.sin(angle);
        const deltaLat = dy / 111.32;
        const deltaLng = dx / (111.32 * Math.cos(zone.lat * Math.PI / 180));
        coords.push([center[0] + deltaLng, center[1] + deltaLat]);
      }
      coords.push(coords[0]);

      map.current!.addSource(`zone-circle-${idx}`, {
        type: 'geojson',
        data: {
          type: 'Feature',
          geometry: { type: 'Polygon', coordinates: [coords] },
          properties: {}
        }
      });

      map.current!.addLayer({
        id: `zone-circle-${idx}`,
        type: 'fill',
        source: `zone-circle-${idx}`,
        paint: { 'fill-color': color, 'fill-opacity': 0.15 }
      });

      map.current!.addLayer({
        id: `zone-circle-border-${idx}`,
        type: 'line',
        source: `zone-circle-${idx}`,
        paint: { 'line-color': color, 'line-width': 2, 'line-opacity': 0.6 }
      });
    });

  }, [zones, mapLoaded]);

  return (
    <>
      <div ref={mapContainer} style={{ width: '100%', height: '100%', position: 'relative' }} />

      {/* Custom Popup UI */}
      {popupInfo && (
        <div
          style={{
            position: 'absolute',
            left: Math.min(popupInfo.x, window.innerWidth - 400), // Prevent going off-screen right
            top: popupInfo.y,
            transform: 'translate(10px, 10px)',
            zIndex: 50,
            maxWidth: '260px'
          }}
          className="bg-[#18181b] border border-white/10 p-4 rounded-lg shadow-2xl min-w-[240px] backdrop-blur-md animate-in fade-in zoom-in-95 duration-200"
        >
          <div className="flex items-center gap-3 mb-3 border-b border-white/5 pb-3">
            <div className="w-10 h-10 rounded-full bg-cyan-500/20 flex items-center justify-center text-cyan-400 font-bold border border-cyan-500/30">
              {popupInfo.user.name.charAt(0)}
            </div>
            <div>
              <h3 className="text-sm font-bold text-white">{popupInfo.user.name}</h3>
              <span className="text-xs text-emerald-400 font-mono flex items-center gap-1">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" />
                Active Status
              </span>
            </div>
          </div>

          <div className="space-y-2 text-xs text-zinc-400">
            <div className="flex justify-between">
              <span>📞 Mobile:</span>
              <span className="text-zinc-200 font-mono">{popupInfo.user.phone}</span>
            </div>
            <div className="flex justify-between">
              <span>🆘 SOS Contact:</span>
              <span className="text-red-400 font-mono">{popupInfo.user.emergencyContact}</span>
            </div>
            <div className="flex justify-between">
              <span>🩸 Blood Group:</span>
              <span className="text-zinc-300">{popupInfo.user.bloodGroup || 'O+'}</span>
            </div>
          </div>

          <div className="mt-4 pt-3 border-t border-white/5">
            <button
              onClick={() => {
                console.log('🚨 Dispatch triggered for user:', popupInfo.user.user_id || popupInfo.user.name);
                // TODO: Call dispatch API when implemented
                alert(`Dispatch initiated for ${popupInfo.user.name}`);
                setPopupInfo(null);
              }}
              className="w-full bg-red-500 hover:bg-red-600 text-white text-xs py-2 rounded font-bold uppercase tracking-wide transition-colors flex items-center justify-center gap-2 shadow-[0_0_15px_rgba(239,68,68,0.3)]"
            >
              🚨 Dispatch Patrol
            </button>
          </div>
        </div>
      )}

      <style jsx>{`
        /* ... existing styles */
        @keyframes beacon-blink-red {
          0%, 100% { opacity: 1; transform: translate(-50%, -50%) scale(1); }
          50% { opacity: 0.6; transform: translate(-50%, -50%) scale(1.1); }
        }
        @keyframes beacon-blink-yellow {
          0%, 100% { opacity: 1; transform: translate(-50%, -50%) scale(1); }
          50% { opacity: 0.7; transform: translate(-50%, -50%) scale(1.05); }
        }
        .beacon-blink-red {
          animation: beacon-blink-red 1s infinite;
        }
        .beacon-blink-yellow {
          animation: beacon-blink-yellow 1.5s infinite;
        }
      `}</style>
    </>
  );
};

export default MapView;
