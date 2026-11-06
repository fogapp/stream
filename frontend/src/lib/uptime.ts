/**
 * "3d 4h" since a boot time — the coarse "up for" reading next to "Server
 * started". Days dominate once there are any; below a minute it is
 * "moments", because a server that just came up has no uptime worth a unit.
 */
export function formatUptime(since: Date, now: Date = new Date()): string {
  const seconds = Math.max(0, (now.getTime() - since.getTime()) / 1000);
  if (seconds < 60) return "moments";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}
