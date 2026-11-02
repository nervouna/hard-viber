# Usage image artwork

- `ShareMascot.png` is the approved Fried Laptop artwork, with only its transparent
  margins trimmed from `../Icon/Artwork/fried-laptop.png`.
- `SharePaper.png` is a flat paper texture generated with built-in Imagegen from
  the selected concept. Prompt: reproduce only the very pale cool-white paper
  grain; remove all text, charts, illustration, divider lines, shadows, and borders.

`Sources/QuotaImage.swift` renders all text and quota charts locally. The title
uses the macOS Bradley Hand Bold font. Its glyph bounds determine the mascot's
height (110%); the mascot is then raised optically to account for its smoke.
The chart texture is deterministic, and arc lengths still represent live
remaining percentages. No generated mock data is included in runtime assets.

The approved layout reference is `../../design/usage-image/selected-layout.png`.
Later refinements use English countdown units and keep each Antigravity plan and
bucket on one line, separated by ` / `.
