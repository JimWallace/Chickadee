### Changed

- **Submissions stat card is now cyclable (24h/7d/30d).** On the instructor
  assignment-submissions page the *Submissions* card behaves like the dashboard
  cards: click (or Enter/Space) cycles its sparkline through submissions-over-time
  for the last 24 hours (hourly), 7 days, and 30 days (daily), updating the
  window chip and count. All three windows are rendered server-side, so the 24h
  view still shows without JavaScript. The grade and attempts charts stay
  fixed distributions (they have no time axis).
- **Admin dashboard: dropped the *Max Queue* card** (Max Load conveys the same
  or more) and turned *Active Users* into a cyclable metric card in its place —
  a compact sparkline of distinct active users that cycles 24h/7d/30d on click,
  replacing the large standalone activity chart at the foot of the page.

### Fixed

- **Distribution sparklines hid small bins.** Bars were rendered at the
  `.spark-fill` 2px floor for *every* bucket, so a grade bin with one or two
  students looked identical to an empty bin and the chart appeared to undercount
  (e.g. ~33 students shown for 37 graded). Empty buckets now render
  flat/transparent and any populated bucket gets a clearly visible minimum
  height, so every bin with students is distinct. (The data was always complete
  — bin tooltips already summed correctly.)
