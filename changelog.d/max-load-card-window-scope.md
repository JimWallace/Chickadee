### Fixed

- **Admin "Max Load" card headline now scoped to its own window.** The load
  points feeding the diagnostic cards are fetched once for the longest
  (30-day) window and reused across the 24h / 7d / 30d cards, but the
  headline peak was computed over that whole fetch instead of the displayed
  window — so every card reported the 30-day peak (e.g. a stale `13/13`) even
  when its sparkline never reached it. The peak is now restricted to the load
  points that fall inside each card's grid, matching the sparkline.
