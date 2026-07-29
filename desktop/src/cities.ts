// Ported from ios/QuakeSignal/Models/City.swift — same 45 cities, same ids,
// so a device migrating between the iOS and desktop apps sees the same
// names/coordinates. Keep the two lists in sync if either changes.

export interface City {
  id: string;
  nameZh: string;
  nameJa: string;
  nameEn: string;
  latitude: number;
  longitude: number;
}

export const CITIES: City[] = [
  // China (CENC nationwide + Sichuan/Fujian/Chongqing bureau coverage)
  { id: "beijing", nameZh: "北京市", nameJa: "北京", nameEn: "Beijing", latitude: 39.9042, longitude: 116.4074 },
  { id: "shanghai", nameZh: "上海市", nameJa: "上海", nameEn: "Shanghai", latitude: 31.2304, longitude: 121.4737 },
  { id: "tianjin", nameZh: "天津市", nameJa: "天津", nameEn: "Tianjin", latitude: 39.3434, longitude: 117.3616 },
  { id: "chongqing", nameZh: "重庆市", nameJa: "重慶", nameEn: "Chongqing", latitude: 29.5630, longitude: 106.5516 },
  { id: "chengdu", nameZh: "成都市", nameJa: "成都", nameEn: "Chengdu", latitude: 30.5728, longitude: 104.0668 },
  { id: "guangzhou", nameZh: "广州市", nameJa: "広州", nameEn: "Guangzhou", latitude: 23.1291, longitude: 113.2644 },
  { id: "shenzhen", nameZh: "深圳市", nameJa: "深圳", nameEn: "Shenzhen", latitude: 22.5431, longitude: 114.0579 },
  { id: "hangzhou", nameZh: "杭州市", nameJa: "杭州", nameEn: "Hangzhou", latitude: 30.2741, longitude: 120.1551 },
  { id: "nanjing", nameZh: "南京市", nameJa: "南京", nameEn: "Nanjing", latitude: 32.0603, longitude: 118.7969 },
  { id: "wuhan", nameZh: "武汉市", nameJa: "武漢", nameEn: "Wuhan", latitude: 30.5928, longitude: 114.3055 },
  { id: "xian", nameZh: "西安市", nameJa: "西安", nameEn: "Xi'an", latitude: 34.3416, longitude: 108.9398 },
  { id: "chengdu_mianyang", nameZh: "绵阳市", nameJa: "綿陽", nameEn: "Mianyang", latitude: 31.4675, longitude: 104.6790 },
  { id: "fuzhou", nameZh: "福州市", nameJa: "福州", nameEn: "Fuzhou", latitude: 26.0745, longitude: 119.2965 },
  { id: "xiamen", nameZh: "厦门市", nameJa: "アモイ", nameEn: "Xiamen", latitude: 24.4798, longitude: 118.0894 },
  { id: "quanzhou", nameZh: "泉州市", nameJa: "泉州", nameEn: "Quanzhou", latitude: 24.8741, longitude: 118.6757 },
  { id: "shenyang", nameZh: "沈阳市", nameJa: "瀋陽", nameEn: "Shenyang", latitude: 41.8057, longitude: 123.4315 },
  { id: "changchun", nameZh: "长春市", nameJa: "長春", nameEn: "Changchun", latitude: 43.8171, longitude: 125.3235 },
  { id: "harbin", nameZh: "哈尔滨市", nameJa: "ハルビン", nameEn: "Harbin", latitude: 45.8038, longitude: 126.5350 },
  { id: "jinan", nameZh: "济南市", nameJa: "済南", nameEn: "Jinan", latitude: 36.6512, longitude: 117.1201 },
  { id: "qingdao", nameZh: "青岛市", nameJa: "青島", nameEn: "Qingdao", latitude: 36.0671, longitude: 120.3826 },
  { id: "zhengzhou", nameZh: "郑州市", nameJa: "鄭州", nameEn: "Zhengzhou", latitude: 34.7466, longitude: 113.6254 },
  { id: "changsha", nameZh: "长沙市", nameJa: "長沙", nameEn: "Changsha", latitude: 28.2282, longitude: 112.9388 },
  { id: "nanchang", nameZh: "南昌市", nameJa: "南昌", nameEn: "Nanchang", latitude: 28.6820, longitude: 115.8579 },
  { id: "hefei", nameZh: "合肥市", nameJa: "合肥", nameEn: "Hefei", latitude: 31.8206, longitude: 117.2272 },
  { id: "taiyuan", nameZh: "太原市", nameJa: "太原", nameEn: "Taiyuan", latitude: 37.8706, longitude: 112.5489 },
  { id: "shijiazhuang", nameZh: "石家庄市", nameJa: "石家荘", nameEn: "Shijiazhuang", latitude: 38.0428, longitude: 114.5149 },
  { id: "lanzhou", nameZh: "兰州市", nameJa: "蘭州", nameEn: "Lanzhou", latitude: 36.0611, longitude: 103.8343 },
  { id: "xining", nameZh: "西宁市", nameJa: "西寧", nameEn: "Xining", latitude: 36.6171, longitude: 101.7782 },
  { id: "yinchuan", nameZh: "银川市", nameJa: "銀川", nameEn: "Yinchuan", latitude: 38.4872, longitude: 106.2309 },
  { id: "urumqi", nameZh: "乌鲁木齐市", nameJa: "ウルムチ", nameEn: "Urumqi", latitude: 43.8256, longitude: 87.6168 },
  { id: "lhasa", nameZh: "拉萨市", nameJa: "ラサ", nameEn: "Lhasa", latitude: 29.6520, longitude: 91.1721 },
  { id: "kunming", nameZh: "昆明市", nameJa: "昆明", nameEn: "Kunming", latitude: 25.0389, longitude: 102.7183 },
  { id: "guiyang", nameZh: "贵阳市", nameJa: "貴陽", nameEn: "Guiyang", latitude: 26.6470, longitude: 106.6302 },
  { id: "nanning", nameZh: "南宁市", nameJa: "南寧", nameEn: "Nanning", latitude: 22.8170, longitude: 108.3665 },
  { id: "haikou", nameZh: "海口市", nameJa: "海口", nameEn: "Haikou", latitude: 20.0444, longitude: 110.1999 },

  // Japan (JMA coverage)
  { id: "tokyo", nameZh: "东京", nameJa: "東京", nameEn: "Tokyo", latitude: 35.6762, longitude: 139.6503 },
  { id: "osaka", nameZh: "大阪", nameJa: "大阪", nameEn: "Osaka", latitude: 34.6937, longitude: 135.5023 },
  { id: "nagoya", nameZh: "名古屋", nameJa: "名古屋", nameEn: "Nagoya", latitude: 35.1815, longitude: 136.9066 },
  { id: "sapporo", nameZh: "札幌", nameJa: "札幌", nameEn: "Sapporo", latitude: 43.0618, longitude: 141.3545 },
  { id: "sendai", nameZh: "仙台", nameJa: "仙台", nameEn: "Sendai", latitude: 38.2682, longitude: 140.8694 },
  { id: "fukuoka", nameZh: "福冈", nameJa: "福岡", nameEn: "Fukuoka", latitude: 33.5904, longitude: 130.4017 },
  { id: "hiroshima", nameZh: "广岛", nameJa: "広島", nameEn: "Hiroshima", latitude: 34.3853, longitude: 132.4553 },
  { id: "kyoto", nameZh: "京都", nameJa: "京都", nameEn: "Kyoto", latitude: 35.0116, longitude: 135.7681 },
  { id: "yokohama", nameZh: "横滨", nameJa: "横浜", nameEn: "Yokohama", latitude: 35.4437, longitude: 139.6380 },
  { id: "naha", nameZh: "那霸", nameJa: "那覇", nameEn: "Naha", latitude: 26.2124, longitude: 127.6809 },
];

export function findCity(id: string): City | undefined {
  return CITIES.find((c) => c.id === id);
}

export function cityLocalizedName(city: City, lang: string): string {
  if (lang.startsWith("ja")) return city.nameJa;
  if (lang.startsWith("zh")) return city.nameZh;
  return city.nameEn;
}
