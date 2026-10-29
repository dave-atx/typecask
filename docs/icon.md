# The app icon

`Typecask/AppIcon.icon` is an Icon Composer document, and Xcode builds the app icon from it in
every appearance iOS asks for: default, dark, clear and tinted. Open it in Icon Composer, which
comes with Xcode (Xcode › Open Developer Tool › Icon Composer).

<img src="icon/default.png" width="128" alt="Default"> <img src="icon/dark.png" width="128" alt="Dark">
<img src="icon/tinted-light.png" width="128" alt="Tinted light"> <img src="icon/tinted-dark.png" width="128" alt="Tinted dark">
<img src="icon/clear-light.png" width="128" alt="Clear light"> <img src="icon/clear-dark.png" width="128" alt="Clear dark">

Default, dark, tinted light and dark, clear light and dark.

## What it's made of

The canvas is 1024 points, and each layer is an SVG drawn on the whole canvas, so it lands where it
was drawn without any positioning in Icon Composer.

| Part | What it is | Settings |
| --- | --- | --- |
| Background | the document's fill, `#1C1B22` | solid; iOS darkens it on its own for dark |
| `cursor` group | `cursor.svg`, the orange bar, `#FF9F43` | glass, specular, 20% translucency, shadow in the layer's color at 50% |
| `T` group | `T.svg`, the cream T, `#F7F5F0`, one path | glass, specular, 20% translucency, neutral shadow at 50% |

Liquid Glass settings apply to a group, not a layer, so the T and the cursor are a group each and
sit on separate panes of glass. The T is a single path so the glass has one outline to light; the old icon
drew the stem and the bar as two rounded rectangles, which left a notch either side of the join.

In clear and tinted, iOS draws every layer in one color and takes each layer's brightness from its
own color, so the T reads white and the cursor a step dimmer. If a change makes the two hard to
tell apart there, give the cursor a darker gray for Mono in Icon Composer rather than changing its
orange.

## After changing it

```sh
scripts/icon.sh
```

That renders the icon with `ictool`, Icon Composer's command-line tool, into:

- `docs/icon/`, the pictures above. `default.png` is 1024 pixels, and `scripts/site-catalog.sh`
  takes it from the release tag for the site's favicon, touch icon and `og:image`.
- `Typecask/Assets.xcassets/AboutIcon.imageset/`, the About screen's copy, in default and dark,
  since an app can't load its own icon as an image.

Check the renders here before committing, then build the app: Xcode reports a broken `.icon` only
when it compiles the asset catalog.
