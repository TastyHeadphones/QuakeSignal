/** True if `utcOffsetMinutes`-local time right now falls in [22:00, 07:00). */
export function isQuietHours(utcOffsetMinutes: number, now: Date = new Date()): boolean {
  const localMs = now.getTime() + utcOffsetMinutes * 60_000;
  const localHour = new Date(localMs).getUTCHours();
  return localHour >= 22 || localHour < 7;
}
