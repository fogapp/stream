/**
 * TMDB's image CDN, for provider candidates that Stream hasn't downloaded
 * (the Fix match picker). Everything a person browses is served from
 * Stream's own artwork cache instead.
 */
export function tmdbImage(path: string | null, width: 92 | 154 | 185 | 342 = 154): string | null {
  return path ? `https://image.tmdb.org/t/p/w${width}${path}` : null;
}
