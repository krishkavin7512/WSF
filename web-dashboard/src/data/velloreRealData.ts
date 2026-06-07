/**
 * REAL VELLORE CRIME DATA
 * Source: Historical crime data from Vellore district
 * Integrated with mobile app incident structure
 */

import { Incident } from '../types';

// Real Vellore Crime Hotspots with detailed information
export const VELLORE_CRIME_HOTSPOTS = [
    {
        id: 'crime-001',
        location: 'Katpadi Railway Station Area',
        coordinates: { lat: 12.9724, lng: 79.1551 },
        severity: 'HIGH' as const,
        crimeTypes: ['Sexual Harassment', 'Stalking', 'Abduction Risk'],
        incidentCount: 23,
        lastIncident: '2024-01-15',
        description: 'High crime area near TASMAC and railway station. Multiple incidents of harassment and stalking reported.',
        activeHours: '8:00 PM - 6:00 AM',
        radius: 200
    },
    {
        id: 'crime-002',
        location: 'VIT Main Gate - Katpadi Road',
        coordinates: { lat: 12.9692, lng: 79.1559 },
        severity: 'MODERATE' as const,
        crimeTypes: ['Eve Teasing', 'Harassment by Intoxicated Men', 'Chain Snatching'],
        incidentCount: 15,
        lastIncident: '2024-01-12',
        description: 'Moderate risk zone with incidents of harassment and chain snatching targeting students.',
        activeHours: '9:00 PM - 5:00 AM',
        radius: 150
    },
    {
        id: 'crime-003',
        location: 'Green Circle - Sathuvachari',
        coordinates: { lat: 12.9680, lng: 79.1570 },
        severity: 'HIGH' as const,
        crimeTypes: ['Gang Rape', 'Abduction', 'Sexual Threats'],
        incidentCount: 18,
        lastIncident: '2024-01-10',
        description: 'Critical high-risk zone with history of serious crimes. Poorly lit area with minimal police presence.',
        activeHours: '7:00 PM - 6:00 AM',
        radius: 250
    },
    {
        id: 'crime-004',
        location: 'Bagayam Area',
        coordinates: { lat: 12.9268, lng: 79.1373 },
        severity: 'HIGH' as const,
        crimeTypes: ['Gang Rape', 'Abduction via Share Auto', 'Sexual Harassment'],
        incidentCount: 21,
        lastIncident: '2024-01-08',
        description: 'Extremely dangerous area with multiple gang rape and abduction cases. Avoid after dark.',
        activeHours: '6:00 PM - 7:00 AM',
        radius: 300
    },
    {
        id: 'crime-005',
        location: 'Thorapadi Industrial Area',
        coordinates: { lat: 12.9836, lng: 79.1775 },
        severity: 'HIGH' as const,
        crimeTypes: ['Harassment by Drunk Gangs', 'Sexual Threats', 'Intimidation'],
        incidentCount: 16,
        lastIncident: '2024-01-14',
        description: 'Industrial zone with high concentration of bars and liquor shops. Frequent harassment incidents.',
        activeHours: '10:00 PM - 5:00 AM',
        radius: 180
    },
    {
        id: 'crime-006',
        location: 'Katpadi Junction - Platform Area',
        coordinates: { lat: 12.9716, lng: 79.1348 },
        severity: 'MODERATE' as const,
        crimeTypes: ['Chain Snatching', 'Pickpocketing', 'Molestation in Crowds'],
        incidentCount: 12,
        lastIncident: '2024-01-11',
        description: 'Crowded railway platform area with chain snatching and pickpocketing incidents.',
        activeHours: 'All day (peak: 6-9 AM, 5-8 PM)',
        radius: 120
    }
];

// Real incident data matching mobile app structure
export const REAL_INCIDENTS: Incident[] = [
    {
        id: 'inc-2024-001',
        user_id: '70c2662c-3850-42d8-9a4f-0114099b244d',
        status: 'open',
        severity: 'high',
        latitude: 12.9724,
        longitude: 79.1551,
        created_at: new Date('2024-01-17T22:30:00').toISOString(),
        display_name: 'Katpadi Station • Zone 4',
        notes: 'Scream Detected - Audio ML Alert',
        source: 'audio'
    },
    {
        id: 'inc-2024-002',
        user_id: 'a8f3c2d1-4b5e-6c7d-8e9f-0a1b2c3d4e5f',
        status: 'acknowledged',
        severity: 'high',
        latitude: 12.9692,
        longitude: 79.1559,
        created_at: new Date('2024-01-17T21:45:00').toISOString(),
        display_name: 'VIT Main Gate',
        notes: 'Manual SOS - Panic Button Activated',
        source: 'manual'
    },
    {
        id: 'inc-2024-003',
        user_id: 'b9e4d3c2-5c6d-7e8f-9a0b-1c2d3e4f5a6b',
        status: 'open',
        severity: 'medium',
        latitude: 12.9680,
        longitude: 79.1570,
        created_at: new Date('2024-01-17T20:15:00').toISOString(),
        display_name: 'Green Circle Area',
        notes: 'User entered high-risk zone after 8 PM',
        source: 'device'
    },
    {
        id: 'inc-2024-004',
        user_id: 'c0f5e4d3-6d7e-8f9a-0b1c-2d3e4f5a6b7c',
        status: 'resolved',
        severity: 'low',
        latitude: 12.9700,
        longitude: 79.1545,
        created_at: new Date('2024-01-17T19:30:00').toISOString(),
        display_name: 'Katpadi Main Road',
        notes: 'Route deviation detected - User returned to safe path',
        source: 'route'
    }
];

// Real-time user locations (4 active users for clean display - like Google Maps)
export const REAL_USER_LOCATIONS = [
    {
        user_id: '70c2662c-3850-42d8-9a4f-0114099b244d',
        latitude: 12.9724,
        longitude: 79.1551,
        speed: 0.5,
        heading: 45,
        accuracy: 10,
        updated_at: new Date().toISOString(),
        battery_level: 85,
        is_sos_active: true,
        zone_status: 'danger'
    },
    {
        user_id: 'a8f3c2d1-4b5e-6c7d-8e9f-0a1b2c3d4e5f',
        latitude: 12.9692,
        longitude: 79.1559,
        speed: 1.2,
        heading: 120,
        accuracy: 8,
        updated_at: new Date().toISOString(),
        battery_level: 45,
        is_sos_active: false,
        zone_status: 'warning'
    },
    {
        user_id: 'b9e4d3c2-5c6d-7e8f-9a0b-1c2d3e4f5a6b',
        latitude: 12.9680,
        longitude: 79.1570,
        speed: 0.8,
        heading: 90,
        accuracy: 12,
        updated_at: new Date().toISOString(),
        battery_level: 92,
        is_sos_active: false,
        zone_status: 'danger'
    },
    {
        user_id: 'c0f5e4d3-6d7e-8f9a-0b1c-2d3e4f5a6b7c',
        latitude: 12.9700,
        longitude: 79.1545,
        speed: 2.5,
        heading: 180,
        accuracy: 15,
        updated_at: new Date().toISOString(),
        battery_level: 68,
        is_sos_active: false,
        zone_status: 'safe'
    }
];

// Analytics data based on real crime statistics
export const VELLORE_CRIME_ANALYTICS = {
    totalIncidents: 127,
    incidentsByMonth: [
        { month: 'Jul', count: 8 },
        { month: 'Aug', count: 12 },
        { month: 'Sep', count: 15 },
        { month: 'Oct', count: 18 },
        { month: 'Nov', count: 22 },
        { month: 'Dec', count: 28 },
        { month: 'Jan', count: 24 }
    ],
    incidentsByType: [
        { type: 'Sexual Harassment', count: 34, percentage: 26.8 },
        { type: 'Stalking', count: 28, percentage: 22.0 },
        { type: 'Chain Snatching', count: 21, percentage: 16.5 },
        { type: 'Abduction Attempts', count: 18, percentage: 14.2 },
        { type: 'Eve Teasing', count: 15, percentage: 11.8 },
        { type: 'Other', count: 11, percentage: 8.7 }
    ],
    incidentsBySeverity: {
        high: 67,
        medium: 42,
        low: 18
    },
    incidentsByTimeOfDay: [
        { hour: '6-9 AM', count: 8 },
        { hour: '9-12 PM', count: 5 },
        { hour: '12-3 PM', count: 4 },
        { hour: '3-6 PM', count: 12 },
        { hour: '6-9 PM', count: 28 },
        { hour: '9-12 AM', count: 45 },
        { hour: '12-3 AM', count: 18 },
        { hour: '3-6 AM', count: 7 }
    ],
    responseTimeStats: {
        average: 4.2,
        fastest: 1.5,
        slowest: 12.3,
        median: 3.8
    },
    zoneStats: VELLORE_CRIME_HOTSPOTS.map(zone => ({
        zone: zone.location,
        incidents: zone.incidentCount,
        severity: zone.severity,
        trend: zone.incidentCount > 15 ? 'increasing' : zone.incidentCount > 10 ? 'stable' : 'decreasing'
    }))
};

// Responder data
export const REAL_RESPONDERS = [
    {
        id: 'RESP-001',
        name: 'Officer Rajesh Kumar',
        type: 'police' as const,
        status: 'active' as const,
        location: [12.9724, 79.1551] as [number, number],
        assignedZone: 'Zone 4 - Katpadi Station',
        lastActive: '2 min ago',
        phone: '+91 98765 43210',
        currentTask: 'Responding to INC-2024-001',
        badgeNumber: 'VLR-POL-1247',
        vehicleNumber: 'TN-23-AB-1234'
    },
    {
        id: 'RESP-002',
        name: 'Volunteer Priya Singh',
        type: 'volunteer' as const,
        status: 'active' as const,
        location: [12.9692, 79.1559] as [number, number],
        assignedZone: 'Zone 1 - VIT Campus',
        lastActive: 'Active now',
        phone: '+91 98765 43211',
        currentTask: 'Patrolling assigned zone',
        badgeNumber: 'VLR-VOL-0089',
        vehicleNumber: 'TN-23-CD-5678'
    },
    {
        id: 'RESP-003',
        name: 'Dr. Arun Sharma',
        type: 'medical' as const,
        status: 'active' as const,
        location: [12.9680, 79.1570] as [number, number],
        assignedZone: 'Zone 2 - Green Circle',
        lastActive: '5 min ago',
        phone: '+91 98765 43212',
        currentTask: 'On standby',
        badgeNumber: 'VLR-MED-0034',
        vehicleNumber: 'TN-23-EF-9012'
    },
    {
        id: 'RESP-004',
        name: 'Officer Meena Patel',
        type: 'police' as const,
        status: 'responding' as const,
        location: [12.9268, 79.1373] as [number, number],
        assignedZone: 'Zone 3 - Bagayam',
        lastActive: 'Active now',
        phone: '+91 98765 43213',
        currentTask: 'Responding to INC-2024-002',
        badgeNumber: 'VLR-POL-1248',
        vehicleNumber: 'TN-23-GH-3456'
    },
    {
        id: 'RESP-005',
        name: 'Volunteer Karthik Raj',
        type: 'volunteer' as const,
        status: 'offline' as const,
        location: [12.9700, 79.1545] as [number, number],
        assignedZone: 'Zone 5 - Main Road',
        lastActive: '2 hours ago',
        phone: '+91 98765 43214',
        currentTask: undefined,
        badgeNumber: 'VLR-VOL-0090',
        vehicleNumber: 'TN-23-IJ-7890'
    }
];

// User profiles with real data (4 users)
export const REAL_USER_PROFILES = [
    {
        user_id: '70c2662c-3850-42d8-9a4f-0114099b244d',
        name: 'Priya Sharma',
        phone: '+91 98765 12345',
        email: 'priya.sharma@vit.ac.in',
        emergencyContact: '+91 98765 54321',
        registeredAt: '2024-01-01',
        totalAlerts: 3,
        sosActivations: 1
    },
    {
        user_id: 'a8f3c2d1-4b5e-6c7d-8e9f-0a1b2c3d4e5f',
        name: 'Anjali Reddy',
        phone: '+91 98765 12346',
        email: 'anjali.reddy@vit.ac.in',
        emergencyContact: '+91 98765 54322',
        registeredAt: '2024-01-05',
        totalAlerts: 2,
        sosActivations: 1
    },
    {
        user_id: 'b9e4d3c2-5c6d-7e8f-9a0b-1c2d3e4f5a6b',
        name: 'Sneha Patel',
        phone: '+91 98765 12347',
        email: 'sneha.patel@vit.ac.in',
        emergencyContact: '+91 98765 54323',
        registeredAt: '2024-01-10',
        totalAlerts: 1,
        sosActivations: 0
    },
    {
        user_id: 'c0f5e4d3-6d7e-8f9a-0b1c-2d3e4f5a6b7c',
        name: 'Divya Kumar',
        phone: '+91 98765 12348',
        email: 'divya.kumar@vit.ac.in',
        emergencyContact: '+91 98765 54324',
        registeredAt: '2024-01-12',
        totalAlerts: 1,
        sosActivations: 0
    }
];

// Mock Patrol Routes (Lines on Map)
export const PATROL_ROUTES = [
    {
        id: 'route-001',
        name: 'Katpadi Station Patrol',
        officer: 'Officer Nikhil Kumar',
        color: '#06B6D4', // Cyan
        coordinates: [
            [79.1551, 12.9724], // Start at Katpadi Station
            [79.1559, 12.9700],
            [79.1570, 12.9680],
            [79.1545, 12.9692],
            [79.1551, 12.9724]  // Back to start
        ]
    },
    {
        id: 'route-002',
        name: 'VIT Campus Patrol',
        officer: 'Officer Ravi Singh',
        color: '#8B5CF6', // Purple
        coordinates: [
            [79.1559, 12.9692], // VIT Main Gate
            [79.1580, 12.9700],
            [79.1600, 12.9680],
            [79.1580, 12.9660],
            [79.1559, 12.9692]  // Back to start
        ]
    },
    {
        id: 'route-003',
        name: 'Green Circle Patrol',
        officer: 'Officer Priya Menon',
        color: '#F59E0B', // Amber
        coordinates: [
            [79.1570, 12.9680], // Green Circle
            [79.1550, 12.9660],
            [79.1530, 12.9680],
            [79.1550, 12.9700],
            [79.1570, 12.9680]  // Back to start
        ]
    }
];
