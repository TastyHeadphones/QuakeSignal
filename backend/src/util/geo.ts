const EARTH_RADIUS_KM = 6371;
const GCJ_A = 6378245;
const GCJ_EE = 0.00669342162296594323;

export const CHINA_DOMESTIC_SOURCES = [
  "cenc_eew",
  "cenc_eqlist",
  "sc_eew",
  "fj_eew",
  "cq_eew",
] as const;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

export function haversineDistanceKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_KM * c;
}

/** Official China geodetic bounding box used by the GCJ-02 offset. */
export function isInsideChina(latitude: number, longitude: number): boolean {
  return longitude >= 72.004 && longitude <= 137.8347 && latitude >= 0.8293 && latitude <= 55.8271;
}

export function isChinaDomesticSource(sourceId: string): boolean {
  return (CHINA_DOMESTIC_SOURCES as readonly string[]).includes(sourceId);
}

function transformLat(longitude: number, latitude: number): number {
  const x = longitude - 105;
  const y = latitude - 35;
  return (
    -100 +
    2 * x +
    3 * y +
    0.2 * y * y +
    0.1 * x * y +
    0.2 * Math.sqrt(Math.abs(x)) +
    ((20 * Math.sin(6 * x * Math.PI) + 20 * Math.sin(2 * x * Math.PI)) * 2) / 3 +
    ((20 * Math.sin(y * Math.PI) + 40 * Math.sin((y / 3) * Math.PI)) * 2) / 3 +
    ((160 * Math.sin((y / 12) * Math.PI) + 320 * Math.sin((y * Math.PI) / 30)) * 2) / 3
  );
}

function transformLon(longitude: number, latitude: number): number {
  const x = longitude - 105;
  const y = latitude - 35;
  return (
    300 +
    x +
    2 * y +
    0.1 * x * x +
    0.1 * x * y +
    0.1 * Math.sqrt(Math.abs(x)) +
    ((20 * Math.sin(6 * x * Math.PI) + 20 * Math.sin(2 * x * Math.PI)) * 2) / 3 +
    ((20 * Math.sin(x * Math.PI) + 40 * Math.sin((x / 3) * Math.PI)) * 2) / 3 +
    ((150 * Math.sin((x / 12) * Math.PI) + 300 * Math.sin((x / 30) * Math.PI)) * 2) / 3
  );
}

export function wgs84ToGcj02(latitude: number, longitude: number): { latitude: number; longitude: number } {
  if (!isInsideChina(latitude, longitude)) return { latitude, longitude };
  const dLat = transformLat(longitude, latitude);
  const dLon = transformLon(longitude, latitude);
  const radLat = (latitude / 180) * Math.PI;
  const magic = Math.sin(radLat);
  const magicFactor = 1 - GCJ_EE * magic * magic;
  const sqrtMagic = Math.sqrt(magicFactor);
  return {
    latitude: latitude + (dLat * 180) / (((GCJ_A * (1 - GCJ_EE)) / (magicFactor * sqrtMagic)) * Math.PI),
    longitude: longitude + (dLon * 180) / ((GCJ_A / sqrtMagic) * Math.cos(radLat) * Math.PI),
  };
}

export function gcj02ToWgs84(latitude: number, longitude: number): { latitude: number; longitude: number } {
  if (!isInsideChina(latitude, longitude)) return { latitude, longitude };
  const { latitude: glat, longitude: glon } = wgs84ToGcj02(latitude, longitude);
  return {
    latitude: latitude * 2 - glat,
    longitude: longitude * 2 - glon,
  };
}

/** Core Location in mainland China returns GCJ-02. Convert to WGS-84 for matching. */
export function deviceGpsToWgs84(latitude: number, longitude: number): { latitude: number; longitude: number } {
  return gcj02ToWgs84(latitude, longitude);
}

export function eventToWgs84(
  latitude: number,
  longitude: number,
  sourceId: string,
): { latitude: number; longitude: number } {
  return isChinaDomesticSource(sourceId) ? gcj02ToWgs84(latitude, longitude) : { latitude, longitude };
}

export function eventMatchesDeviceLocation(input: {
  userLatitude: number;
  userLongitude: number;
  eventLatitude: number;
  eventLongitude: number;
  eventSourceId: string;
  radiusKm: number;
}): boolean {
  const event = eventToWgs84(input.eventLatitude, input.eventLongitude, input.eventSourceId);
  return (
    haversineDistanceKm(
      input.userLatitude,
      input.userLongitude,
      event.latitude,
      event.longitude,
    ) <= input.radiusKm
  );
}
