/**
 * Official earthquake catalogs that are not Wolfx feeds. These are report-kind
 * sources: they can produce Apple notifications, but they are not EEW warnings.
 */
export const CATALOG_SOURCE_IDS = [
  "usgs_eqlist",
  "emsc_eqlist",
  "geonet_eqlist",
] as const;

export type CatalogSourceId = (typeof CATALOG_SOURCE_IDS)[number];

export function isCatalogSourceId(value: unknown): value is CatalogSourceId {
  return typeof value === "string" &&
    (CATALOG_SOURCE_IDS as readonly string[]).includes(value);
}

export const CATALOG_HTTP_URLS: Record<CatalogSourceId, string> = {
  usgs_eqlist:
    "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson",
  emsc_eqlist:
    "https://www.seismicportal.eu/fdsnws/event/1/query?format=json&limit=50&minmag=4.5&orderby=time",
  geonet_eqlist: "https://api.geonet.org.nz/quake?MMI=4",
};

export interface CatalogGeoJSONPoint {
  type?: unknown;
  coordinates?: unknown;
}

export interface CatalogGeoJSONFeature {
  type?: unknown;
  id?: unknown;
  properties?: unknown;
  geometry?: CatalogGeoJSONPoint | null;
}

export interface CatalogGeoJSONCollection {
  type?: unknown;
  features?: unknown;
}
