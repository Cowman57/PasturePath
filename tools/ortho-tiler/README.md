# OrthoTiler

Converts a drone orthomosaic (GeoTIFF) into an **MBTiles** file that PasturePath
can import as an offline map layer.

The `dist/OrthoTiler` folder is self-contained — it includes GDAL, so **nothing
needs to be installed**. Copy the folder anywhere and run `OrthoTiler.exe`.

## Using it

1. **Browse** to your orthomosaic (`.tif` / `.tiff` from WebODM).
   It shows the size, ground resolution, area, band count and CRS.
2. Check the **zoom levels**. Max zoom defaults to the highest level your
   resolution supports (e.g. 5 cm imagery → z21). Lower it to shrink the file.
   The estimate shows roughly how many tiles and MB you'll get.
3. Choose **PNG** (keeps the transparent survey edge) or **JPEG** (much smaller,
   edge becomes black — only offered when the source has no transparency, or the
   alpha band is dropped automatically).
4. **Convert.** Progress runs to 100%, then it opens the output folder.

Drop the resulting `.mbtiles` onto the phone and import it in PasturePath:
**Settings → Map & Tiles → My imagery → Import .mbtiles…**

## Zoom guidance

| Max zoom | Ground size of a pixel | Use |
|---|---|---|
| 18 | ~0.47 m | Small file, fine for field overview |
| 19 | ~0.24 m | Good balance |
| 20 | ~0.12 m | Detail without huge files |
| 21 | ~0.06 m | Full 5 cm detail — largest |

Roughly **60 tiles per hectare** at 5 cm, so ~2-2.5 MB/ha. A 500 ha farm at z21
lands around 1.5-2 GB; at z20 it's about a quarter of that.

> The zoom range is achieved by resampling the raster to the target resolution
> before tiling. The MBTiles driver's own `RESOLUTION` option is ignored —
> `-tr` on the source is what actually sets the maximum zoom.

## Command line

```
OrthoTiler.exe --cli <input.tif> <minZoom> <maxZoom> [--jpeg] [--out <file.mbtiles>]
```

Example:

```
OrthoTiler.exe --cli "farm ortho.tif" 15 21 --out farm.mbtiles
```

Exit codes: `0` success, `1` conversion failed, `2` bad arguments / GDAL missing,
`3` file could not be read as a georeferenced raster.

## Rebuilding from source

No SDK is required — Windows ships a C# compiler:

```
csc /nologo /target:winexe /out:bin\OrthoTiler.exe ^
    /reference:System.dll /reference:System.Windows.Forms.dll ^
    /reference:System.Drawing.dll /reference:System.Core.dll ^
    /reference:System.Web.Extensions.dll OrthoTiler.cs
```

The code is written in C# 5 (the version that compiler supports), so no string
interpolation, `?.` or expression-bodied members.

## GDAL location

The program looks for `gdal_translate.exe` in this order:

1. `gdal\` next to `OrthoTiler.exe` (the bundled copy)
2. `C:\Program Files\GDAL`
3. `%GDAL_HOME%`

It sets `PATH`, `PROJ_DATA`/`PROJ_LIB` and `GDAL_DATA` for the child processes
itself, so a system-wide GDAL install needs no PATH configuration.
