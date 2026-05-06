import { Request, Response, NextFunction } from 'express';

/**
 * Middleware to enforce Tor-only access for sensitive endpoints.
 * Allows requests from loopback (127.0.0.1, ::1) or private ranges (RFC1918).
 * Rejects public IPs unless SEALED_ALLOW_NON_TOR=true.
 */
export function requireTorOrigin(req: Request, res: Response, next: NextFunction) {
  if (process.env.SEALED_ALLOW_NON_TOR === 'true') {
    return next();
  }

  const rawAddress = req.socket.remoteAddress || req.ip;

  if (!rawAddress) {
    return res.status(403).json({ error: 'Forbidden: Unable to determine origin' });
  }

  // Node's HTTP server listens dual-stack by default, so an IPv4 peer arrives
  // as the IPv4-mapped form `::ffff:172.18.0.4`. Strip the prefix before any
  // numeric check, otherwise every Docker-bridge request looks "public".
  const remoteAddress = rawAddress.startsWith('::ffff:')
    ? rawAddress.slice(7)
    : rawAddress;

  // Allow loopback addresses (both raw and stripped forms cover IPv4 + IPv6).
  if (remoteAddress === '127.0.0.1' || remoteAddress === '::1') {
    return next();
  }

  // Allow RFC1918 private ranges (Docker bridge network).
  if (isPrivateIP(remoteAddress)) {
    return next();
  }

  return res.status(403).json({ error: 'Forbidden: Non-Tor origin not allowed' });
}

/**
 * Check if an IP address is in RFC1918 private ranges:
 * - 10.0.0.0/8 (10.0.0.0 to 10.255.255.255)
 * - 172.16.0.0/12 (172.16.0.0 to 172.31.255.255)
 * - 192.168.0.0/16 (192.168.0.0 to 192.168.255.255)
 */
function isPrivateIP(ip: string): boolean {
  // Simple IPv4 check for private ranges
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some(p => isNaN(p) || p < 0 || p > 255)) {
    return false; // Not a valid IPv4, assume public
  }

  const [a, b] = parts;

  // 10.0.0.0/8
  if (a === 10) return true;

  // 172.16.0.0/12
  if (a === 172 && b >= 16 && b <= 31) return true;

  // 192.168.0.0/16
  if (a === 192 && b === 168) return true;

  return false;
}