# Usage image artwork

- `ShareMascot.png` is the approved Fried Laptop artwork, with only its transparent
  margins trimmed from `../Icon/Artwork/fried-laptop.png`, then downscaled to
  365×400 px (Lanczos, premultiplied alpha). It is drawn about 79 pt high, which is
  158 px in the 2x export, so this keeps roughly 2.5x headroom for the crayon texture.
- `SharePaper.png` is a flat paper texture generated with built-in Imagegen from
  the selected concept. Prompt: reproduce only the very pale cool-white paper
  grain; remove all text, charts, illustration, divider lines, shadows, and borders.
  It is 1568×1003 px, close to the 1600×1024 px it fills in the export, so it is not
  resized. It has only 208 distinct colors, so it is stored as an indexed PNG
  that decodes to exactly the original pixels.

`Sources/QuotaImage.swift` renders all text and quota charts locally. The title
uses the macOS Bradley Hand Bold font. Its glyph bounds determine the mascot's
height (110%); the mascot is then raised optically to account for its smoke.
The chart texture is deterministic, and arc lengths still represent live
remaining percentages. No generated mock data is included in runtime assets.

The approved layout reference image (`design/usage-image/selected-layout.png`) was
removed from the tree and remains in git history at commit `c683314`. Later
refinements use English countdown units and keep each Antigravity plan and bucket
on one line, separated by ` / `.
