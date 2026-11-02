# Quota icon

The selected direction is **Fried Laptop**, under the theme “Somebody vibed too hard.”
The editable source is `Quota.icon`, created in Icon Composer 27.2. Keep the tired
expression, orange screen, blue keyboard, smoke curl, and hand-drawn texture.
Default and dark appearances use the original crayon artwork. The mono
appearance uses the matching high-contrast outline also used in the menu bar.
Appearance-specific values are kept together in specialization arrays; do not
add a competing base property alongside an array for the same value.

The three generated proposals (Fried Laptop, Melted Groove, Spent Spark) and the
presentation board they came from are not kept in the repository. They were
removed from its history as well, to keep clones small.

`Artwork/fried-laptop.png` is the approved character isolated on transparency.
`Artwork/menu-bar-source.png` is its simplified black template artwork. Both
were produced with the built-in Imagegen tool using the Fried Laptop proposal
as the visual reference. The production prompts preserve the selected shape,
colors, tilt, face, and texture; remove the presentation board and icon tile;
and require true transparency. The menu prompt additionally removes color,
texture, mouth, cheek marks, and tiny details, retaining the laptop outline,
sleepy eyes, and smoke for small-size readability.

Regenerate the menu bar's 18 px and 36 px renditions after editing its source:

```sh
xcrun swift -module-cache-path build/module-cache scripts/prepare-menu-icon.swift "$PWD"
```

`scripts/build.sh` compiles `Quota.icon` and `../MenuBar.xcassets` with Apple's
asset compiler. The resulting asset catalog provides the layered app icon and
the template menu image; the generated ICNS supports older macOS versions.
The asset compiler's icon metadata is merged into the app's Info.plist.

The runtime marks the menu image as a template, so macOS controls its color in
light, dark, and selected menu bar states. The image remains unchanged when
copying a usage snapshot.
