# Usage image artwork

- `ShareMascot.png` is the approved Fried Laptop artwork, with only its transparent
  margins trimmed from `../Icon/Artwork/fried-laptop.png`, then downscaled to
  365×400 px (Lanczos, premultiplied alpha). It is the only bundled artwork.

`Sources/QuotaKit/QuotaImage.swift` draws the image as a magazine cover inspired by
Bloomberg Businessweek (no name, logo or wordmark of it appears): a flat cover
field on the left and a black panel with one row per installed subscription on
the right, always 800×512 pt rendered at 2x.

- The cover color follows the rows: orange `#FF5B1A` when a plan is exhausted,
  yellow `#FFD21F` when a fresh plan has 20% or less left (the menu's red band),
  lime `#C6F43A` when every fresh plan is above that, grey when no row is fresh.
- The headline and the deck line are generated from the rows. The headline
  rotates by day of year through a few lines per situation; the deck only counts
  what the data shows. Stale or unavailable rows are "didn't report back", never
  "dead".
- Exhausted rows show an orange `0%` and a `DEAD` tag; stale or unavailable rows
  show `—`, a `NO SIGNAL` tag and a dashed bar. All percentages share one size,
  the largest at which the widest value fits; a single row gets a vertical layout.
- Type uses only fonts that ship with macOS: Helvetica Neue Condensed Black for
  the headline and names, SF Pro Compressed Black for the percentages.
- The mascot becomes a die-cut sticker at render time: Core Image grows a white
  border from its alpha channel (3.4% of its height), and SwiftUI adds a hard
  offset shadow and an 8° tilt. It is drawn 150 pt high, about 300 px in the 2x
  export, so the 400 px source still has headroom.

The earlier hand-drawn layout and its `SharePaper.png` paper texture remain in git
history at commit `1161b91`.
