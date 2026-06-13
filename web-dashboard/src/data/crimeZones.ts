/**
 * VELLORE CRIME DATA WITH DAY/NIGHT MODES
 * Source: crimes.json from criminological safety audit
 */

export interface CrimeZone {
    id: number;
    location: string;
    lat: number;
    lng: number;
    severity: 'HIGH' | 'MODERATE' | 'LOW';
    type: string;
    active_hours?: string;
    description: string;
    radius?: number;
}

export type TimeMode = 'day' | 'night' | 'all';

// Raw crime data from crimes.json
export const CRIME_ZONES: CrimeZone[] = [
    {
        id: 101,
        location: "Sathuvachari (Burial Ground Area)",
        lat: 12.9490,
        lng: 79.1650,
        severity: "HIGH",
        type: "Violence/Abduction",
        active_hours: "18-06",
        description: "Critical Red Zone along NH 48. High risk of share autos diverting to secluded areas after dark.",
        radius: 250
    },
    {
        id: 102,
        location: "Green Circle Junction",
        lat: 12.9716,
        lng: 79.1594,
        severity: "HIGH",
        type: "Harassment/Abduction",
        active_hours: "21-05",
        description: "High transit friction zone. Funnel for drunkards moving between TASMAC outlets late at night.",
        radius: 200
    },
    {
        id: 103,
        location: "Katpadi Railway Station",
        lat: 12.9796,
        lng: 79.1374,
        severity: "HIGH",
        type: "Assault/Robbery",
        description: "Epicenter of transit crime. Risk of assault on moving trains near station approaches.",
        radius: 300
    },
    {
        id: 104,
        location: "VIT Road (UGD Works)",
        lat: 12.9750,
        lng: 79.1500,
        severity: "HIGH",
        type: "Chain Snatching",
        description: "Construction-induced traffic slowdowns create a 'natural trap' for women on two-wheelers.",
        radius: 180
    },
    {
        id: 105,
        location: "Chittoor Bus Stand (Katpadi)",
        lat: 12.9760,
        lng: 79.1350,
        severity: "HIGH",
        type: "Vehicle Theft/Harassment",
        description: "Hotspot for juvenile crime rings targeting two-wheelers. General atmosphere of lawlessness.",
        radius: 220
    },
    {
        id: 106,
        location: "Kagithapattarai (Palar River Bank)",
        lat: 12.9550,
        lng: 79.1450,
        severity: "HIGH",
        type: "Public Nuisance/Harassment",
        active_hours: "19-05",
        description: "Extreme density of liquor outlets. Streets colonized by intoxicated men after 7 PM.",
        radius: 280
    },
    {
        id: 107,
        location: "Vellore Fort Park (Moat Area)",
        lat: 12.9204,
        lng: 79.1325,
        severity: "HIGH",
        type: "Sexual Assault",
        active_hours: "18-06",
        description: "Predatory zone after dark. Secluded corners near the moat obscure visibility.",
        radius: 260
    },
    {
        id: 108,
        location: "Vellore New Bus Stand",
        lat: 12.9350,
        lng: 79.1450,
        severity: "HIGH",
        type: "Trafficking/Theft",
        description: "Dark corners and lack of police patrolling inside the terminus. High density of transient offenders.",
        radius: 240
    },
    {
        id: 109,
        location: "Viruthampet (Student Housing)",
        lat: 12.9600,
        lng: 79.1400,
        severity: "MODERATE",
        type: "Stalking/Snatching",
        description: "Narrow residential lanes. High density of students attracts stalkers.",
        radius: 150
    },
    {
        id: 110,
        location: "Gandhi Nagar (Residential)",
        lat: 12.9500,
        lng: 79.1350,
        severity: "MODERATE",
        type: "Chain Snatching",
        active_hours: "13-17",
        description: "Wide, tree-lined streets are desolate in afternoons. Ideal hunting ground for snatchers.",
        radius: 160
    },
    {
        id: 111,
        location: "Bagayam (Southern Fringe)",
        lat: 12.8900,
        lng: 79.1200,
        severity: "MODERATE",
        type: "Rowdyism",
        description: "Stronghold of gangs. Inter-gang violence creates a volatile environment.",
        radius: 200
    },
    {
        id: 112,
        location: "Ariyur",
        lat: 12.8800,
        lng: 79.1000,
        severity: "MODERATE",
        type: "Domestic Violence",
        description: "Semi-rural settlement. High incidence of domestic violence.",
        radius: 180
    }
];

/**
 * Filter zones based on time mode
 * @param mode - 'day' (6AM-6PM), 'night' (6PM-6AM), or 'all'
 */
export function getZonesByTimeMode(mode: TimeMode): CrimeZone[] {
    if (mode === 'all') {
        return CRIME_ZONES;
    }

    return CRIME_ZONES.filter(zone => {
        // If no active_hours specified, zone is active all the time
        if (!zone.active_hours) {
            return true;
        }

        const [start, end] = zone.active_hours.split('-').map(Number);

        if (mode === 'night') {
            // Night mode: show zones active between 18:00-06:00
            // active_hours like "18-06" or "21-05" should be shown
            return start >= 18 || end <= 6;
        } else {
            // Day mode: show zones active between 06:00-18:00
            // active_hours like "13-17" should be shown
            return start >= 6 && start < 18 && end >= 6 && end <= 18;
        }
    });
}

/**
 * Get zone statistics by time mode
 */
export function getZoneStats(mode: TimeMode) {
    const zones = getZonesByTimeMode(mode);
    return {
        total: zones.length,
        high: zones.filter(z => z.severity === 'HIGH').length,
        moderate: zones.filter(z => z.severity === 'MODERATE').length,
        low: zones.filter(z => z.severity === 'LOW').length
    };
}
