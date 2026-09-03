pub const CHINA_DOMESTIC_SOURCES: [&str; 5] =
    ["cenc_eew", "cenc_eqlist", "sc_eew", "fj_eew", "cq_eew"];

const EARTH_RADIUS_KM: f64 = 6371.0;
const GCJ_A: f64 = 6_378_245.0;
const GCJ_EE: f64 = 0.00669342162296594323;

pub fn haversine_distance_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let to_rad = |deg: f64| deg * std::f64::consts::PI / 180.0;
    let d_lat = to_rad(lat2 - lat1);
    let d_lon = to_rad(lon2 - lon1);
    let a = (d_lat / 2.0).sin().powi(2)
        + to_rad(lat1).cos() * to_rad(lat2).cos() * (d_lon / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    EARTH_RADIUS_KM * c
}

pub fn is_inside_china(latitude: f64, longitude: f64) -> bool {
    (72.004..=137.8347).contains(&longitude) && (0.8293..=55.8271).contains(&latitude)
}

pub fn is_china_domestic_source(source_id: &str) -> bool {
    CHINA_DOMESTIC_SOURCES.contains(&source_id)
}

fn transform_lat(longitude: f64, latitude: f64) -> f64 {
    let x = longitude - 105.0;
    let y = latitude - 35.0;
    -100.0
        + 2.0 * x
        + 3.0 * y
        + 0.2 * y * y
        + 0.1 * x * y
        + 0.2 * x.abs().sqrt()
        + (20.0 * (6.0 * x * std::f64::consts::PI).sin() + 20.0 * (2.0 * x * std::f64::consts::PI).sin())
            * 2.0
            / 3.0
        + (20.0 * (y * std::f64::consts::PI).sin() + 40.0 * (y / 3.0 * std::f64::consts::PI).sin()) * 2.0
            / 3.0
        + (160.0 * (y / 12.0 * std::f64::consts::PI).sin()
            + 320.0 * (y * std::f64::consts::PI / 30.0).sin())
            * 2.0
            / 3.0
}

fn transform_lon(longitude: f64, latitude: f64) -> f64 {
    let x = longitude - 105.0;
    let y = latitude - 35.0;
    300.0
        + x
        + 2.0 * y
        + 0.1 * x * x
        + 0.1 * x * y
        + 0.1 * x.abs().sqrt()
        + (20.0 * (6.0 * x * std::f64::consts::PI).sin() + 20.0 * (2.0 * x * std::f64::consts::PI).sin())
            * 2.0
            / 3.0
        + (20.0 * (x * std::f64::consts::PI).sin() + 40.0 * (x / 3.0 * std::f64::consts::PI).sin()) * 2.0
            / 3.0
        + (150.0 * (x / 12.0 * std::f64::consts::PI).sin()
            + 300.0 * (x / 30.0 * std::f64::consts::PI).sin())
            * 2.0
            / 3.0
}

pub fn wgs84_to_gcj02(latitude: f64, longitude: f64) -> (f64, f64) {
    if !is_inside_china(latitude, longitude) {
        return (latitude, longitude);
    }
    let d_lat = transform_lat(longitude, latitude);
    let d_lon = transform_lon(longitude, latitude);
    let rad_lat = latitude / 180.0 * std::f64::consts::PI;
    let magic = rad_lat.sin();
    let magic_factor = 1.0 - GCJ_EE * magic * magic;
    let sqrt_magic = magic_factor.sqrt();
    (
        latitude + (d_lat * 180.0) / ((GCJ_A * (1.0 - GCJ_EE)) / (magic_factor * sqrt_magic) * std::f64::consts::PI),
        longitude + (d_lon * 180.0) / (GCJ_A / sqrt_magic * rad_lat.cos() * std::f64::consts::PI),
    )
}

pub fn gcj02_to_wgs84(latitude: f64, longitude: f64) -> (f64, f64) {
    if !is_inside_china(latitude, longitude) {
        return (latitude, longitude);
    }
    let (g_lat, g_lon) = wgs84_to_gcj02(latitude, longitude);
    (latitude * 2.0 - g_lat, longitude * 2.0 - g_lon)
}

pub fn event_to_wgs84(latitude: f64, longitude: f64, source_id: &str) -> (f64, f64) {
    if is_china_domestic_source(source_id) {
        gcj02_to_wgs84(latitude, longitude)
    } else {
        (latitude, longitude)
    }
}

pub fn event_matches_device_location(
    user_lat: f64,
    user_lon: f64,
    event_lat: f64,
    event_lon: f64,
    event_source_id: &str,
    radius_km: f64,
) -> bool {
    let (event_lat, event_lon) = event_to_wgs84(event_lat, event_lon, event_source_id);
    haversine_distance_km(user_lat, user_lon, event_lat, event_lon) <= radius_km
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokyo_is_not_shifted() {
        let (lat, lon) = gcj02_to_wgs84(35.681, 139.767);
        assert!((lat - 35.681).abs() < 1e-12);
        assert!((lon - 139.767).abs() < 1e-12);
    }

    #[test]
    fn beijing_gcj_offset_is_hundreds_of_metres() {
        let wgs_lat = 39.9042;
        let wgs_lon = 116.4074;
        let (gcj_lat, gcj_lon) = wgs84_to_gcj02(wgs_lat, wgs_lon);
        let offset = haversine_distance_km(wgs_lat, wgs_lon, gcj_lat, gcj_lon);
        assert!(offset > 0.2, "expected a real GCJ-02 offset, got {offset} km");
        assert!(offset < 1.5, "GCJ-02 offset should stay under 1.5 km, got {offset}");
    }

    #[test]
    fn china_cenc_event_matches_wgs84_city_after_transfer() {
        let user_lat = 39.9042;
        let user_lon = 116.4074;
        let (event_lat, event_lon) = wgs84_to_gcj02(user_lat, user_lon);
        assert!(event_matches_device_location(
            user_lat, user_lon, event_lat, event_lon, "cenc_eew", 0.2,
        ));
        assert!(!event_matches_device_location(
            user_lat, user_lon, event_lat, event_lon, "usgs_eqlist", 0.2,
        ));
    }

    #[test]
    fn jma_event_does_not_apply_china_transfer() {
        let user_lat = 35.681;
        let user_lon = 139.767;
        assert!(event_matches_device_location(
            user_lat, user_lon, user_lat, user_lon, "jma_eew", 0.01,
        ));
    }
}
