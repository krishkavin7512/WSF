import React, { useEffect, useRef } from 'react';
import mapboxgl from 'mapbox-gl';
import 'mapbox-gl/dist/mapbox-gl.css';

// 0. AUTHENTICATION
mapboxgl.accessToken = process.env.NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN || '';

// 1. DATA: The Zones (Hardcoded for Stability, move to API later)
const BEACONS = [
  { id: 'red-1', lat: 12.9716, lng: 79.1594, color: '#FF4D4D', radius: 300 }, // TASMAC
  { id: 'yellow-1', lat: 12.9796, lng: 79.1374, color: '#FFD700', radius: 250 } // Katpadi
];

export default function MapView() {
  const mapContainer = useRef<HTMLDivElement>(null);
  const map = useRef<mapboxgl.Map | null>(null);

  useEffect(() => {
    if (map.current || !mapContainer.current) return;

    // INIT MAP
    map.current = new mapboxgl.Map({
      container: mapContainer.current,
      style: 'mapbox://styles/mapbox/dark-v11', // Professional Night Mode
      center: [78.3663, 17.3422], // Lords Institute of Engineering & Technology, Hyderabad
      zoom: 15,
      pitch: 45, // 3D Tilt for Command Center feel
      attributionControl: false
    });

    map.current.on('load', () => {

      // LOGIC: Render Beacons (Circles)
      BEACONS.forEach(beacon => {
        // 1. The Glow Field (Large, Faint)
        map.current?.addLayer({
          id: `${beacon.id}-glow`,
          type: 'circle',
          source: {
            type: 'geojson',
            data: { type: 'Feature', geometry: { type: 'Point', coordinates: [beacon.lng, beacon.lat] }, properties: {} }
          },
          paint: {
            'circle-radius': 80, // Large radius
            'circle-color': beacon.color,
            'circle-opacity': 0.15,
            'circle-blur': 0.8 // Maximum Blur for "Light" effect
          }
        });

        // 2. The Core Emitter (Small, Solid)
        map.current?.addLayer({
          id: `${beacon.id}-core`,
          type: 'circle',
          source: {
            type: 'geojson',
            data: { type: 'Feature', geometry: { type: 'Point', coordinates: [beacon.lng, beacon.lat] }, properties: {} }
          },
          paint: {
            'circle-radius': 6,
            'circle-color': '#FFFFFF',
            'circle-stroke-color': beacon.color,
            'circle-stroke-width': 3
          }
        });
      });

      // LOGIC: Render Users (The Spotlight System)
      // Mock Data - Replace with API
      const users = [
        { id: 1, lat: 12.9716, lng: 79.1594, status: 'danger' }, // In Red Zone
        { id: 2, lat: 12.9600, lng: 79.1500, status: 'safe' }    // Safe Zone
      ];

      users.forEach(user => {
        const el = document.createElement('div');

        // DYNAMIC CLASS ASSIGNMENT
        // If Danger -> Big, Pulsing Red Marker
        // If Safe   -> Small, Dim Blue Marker
        el.className = user.status === 'danger' ? 'marker-danger' : 'marker-safe';

        if (map.current) {
          new mapboxgl.Marker(el)
            .setLngLat([user.lng, user.lat])
            .addTo(map.current);
        }
      });

    });

    return () => {
      map.current?.remove();
      map.current = null;
    }
  }, []);

  return <div ref={mapContainer} style={{ width: '100%', height: '100%' }} />;
}
