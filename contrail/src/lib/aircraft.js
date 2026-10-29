'use strict';
// Simplified, illustrative aircraft data. NOT for real flight planning.
// Weights in lb, arms in inches, fuel in US gallons (jet fuel counted at 6.7 lb/gal).
module.exports = {
  C172: { name: 'Cessna 172S Skyhawk', tasKt: 110, burnGph: 8.5, fuelCapGal: 53, fuelLbPerGal: 6, emptyWeight: 1663, emptyArm: 39.3, maxGross: 2550,
    arms: { front: 37, rear: 73, baggage: 95, fuel: 48 }, cgLimits: [35.0, 47.3], takeoffRollFt: 960, landingRollFt: 575, minRunwayFt: 2000, maxCrosswindKt: 15, serviceCeilingFt: 14000 },
  SR22: { name: 'Cirrus SR22', tasKt: 165, burnGph: 17, fuelCapGal: 92, fuelLbPerGal: 6, emptyWeight: 2250, emptyArm: 77.0, maxGross: 3600,
    arms: { front: 64, rear: 101, baggage: 140, fuel: 75 }, cgLimits: [73.0, 81.0], takeoffRollFt: 1180, landingRollFt: 900, minRunwayFt: 2500, maxCrosswindKt: 20, serviceCeilingFt: 17500 },
  PC12: { name: 'Pilatus PC-12 NGX', tasKt: 270, burnGph: 60, fuelCapGal: 402, fuelLbPerGal: 6.7, emptyWeight: 6200, emptyArm: 190, maxGross: 10450,
    arms: { front: 160, rear: 210, baggage: 280, fuel: 200 }, cgLimits: [181.0, 205.0], takeoffRollFt: 2300, landingRollFt: 1800, minRunwayFt: 3500, maxCrosswindKt: 25, serviceCeilingFt: 30000 },
  TBM9: { name: 'Daher TBM 960', tasKt: 300, burnGph: 58, fuelCapGal: 291, fuelLbPerGal: 6.7, emptyWeight: 4850, emptyArm: 190, maxGross: 7394,
    arms: { front: 170, rear: 215, baggage: 260, fuel: 195 }, cgLimits: [183.0, 202.0], takeoffRollFt: 2100, landingRollFt: 1500, minRunwayFt: 3000, maxCrosswindKt: 24, serviceCeilingFt: 31000 },
};
