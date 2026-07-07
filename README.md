# DJI M3T Thermal Pipeline

One R script, two stages: convert raw DJI thermal R-JPEGs into calibrated temperature TIFFs, then clean the stitched orthomosaic into an analysis-ready GeoTIFF.

Based on original work by Teja Kattenborn & Daniel Nelson (GPL-3).

## Pipeline Overview

```
RAW DJI IMAGES (*_T.JPG)
        │
        ▼
   PART A: Convert
   (dji_m3t_thermal_pipeline_v4.R, RUN_PART <- "A")
        │
        ▼
  Calibrated float TIFFs (per-image temperature)
        │
        ▼
  Build orthomosaic in Metashape / Pix4D (external step)
        │
        ▼
  Stitched orthomosaic (.tif, band 1 = temp, band 2 = Alpha)
        │
        ▼
   PART B: Clean
   (same script, RUN_PART <- "B")
        │
        ▼
  Analysis-ready single-band GeoTIFF + quick plot
```

## Requirements

**Software**
- R (4.x recommended)
- [DJI Thermal SDK](https://www.dji.com/downloads/softwares/dji-thermal-sdk) — must contain `dji_irp.exe` (Windows)
- Metashape or Pix4D (only needed between Part A and Part B, to build the orthomosaic)

**R packages**
```r
install.packages(c("ijtiff", "exifr", "foreach", "doParallel", "terra"))
```

**Input data**
- Raw DJI Mavic 3T thermal images, named `*_T.JPG` (folder can be nested; the script searches recursively)

## Setup

1. Download and unzip the DJI Thermal SDK. Note the path to the `windows/release_x64` folder — it must contain `dji_irp.exe`.
2. Clone this repo and open `dji_m3t_thermal_pipeline_v4.R`.
3. Edit the **CONFIG block** at the top of the script (see below). This is the only part you should need to touch.

## Configuration

All settings live in one block near the top of the script.

| Variable | Description |
|---|---|
| `RUN_PART` | `"A"`, `"B"`, or `"BOTH"`. Controls which stage runs when you source the file. |
| `sdk_dir` | Path to the DJI Thermal SDK `bin` folder containing `dji_irp.exe`. |
| `in_dir` | Folder with raw `*_T.JPG` flight images (Part A input). |
| `out_dir` | Folder where per-image calibrated TIFFs are written (Part A output). |
| `emissivity` | Surface emissivity, 0.10–1.00 (vegetation ≈ 0.95–0.98). |
| `humidity` | Relative humidity at time of flight, % (20–100). |
| `distance` | Camera-to-target distance, m (SDK caps at 25). |
| `reflection` | Reflected apparent temperature, °C (≈ air temperature). |
| `spare_cores` | CPU cores to leave free during parallel conversion. |
| `ortho_in` | Path to the orthomosaic exported from Metashape/Pix4D (Part B input). Band 1 = temperature, band 2 = Alpha. |
| `ortho_out` | Path to write the cleaned, analysis-ready GeoTIFF (Part B output). |
| `temp_min_valid` / `temp_max_valid` | Temperature bounds (°C) — pixels outside this range are clipped as artifacts, not real canopy. |

## Usage

### Part A — Convert raw images

1. Set `RUN_PART <- "A"`.
2. Fill in `sdk_dir`, `in_dir`, `out_dir`, and the flight parameters (`emissivity`, `humidity`, `distance`, `reflection`).
3. Run the script (source it, or select down to `END PART A` and run).
4. Check `conversion_log.csv` in `out_dir` for any failed conversions.

**Output:** one calibrated float TIFF per input image, with EXIF/GPS metadata copied over, written to `out_dir`.

### Between Part A and Part B (external step)

Load the converted TIFFs into Metashape (or Pix4D), build the orthomosaic, and export it as a GeoTIFF with:
- Band 1 = temperature
- Band 2 = Alpha (transparency mask, optional but recommended)

### Part B — Clean the orthomosaic

1. Set `RUN_PART <- "B"`.
2. Set `ortho_in` to the exported orthomosaic path, and `ortho_out` to where the cleaned file should be written.
3. Adjust `temp_min_valid` / `temp_max_valid` if your crop/conditions need different bounds.
4. Run the script.

**Output:** a single-band, analysis-ready GeoTIFF (`ortho_out`), with edge pixels masked (via the Alpha band, if present) and out-of-range values set to `NA`. A quick preview plot is also generated.

**View in QGIS:** load `ortho_out`, then apply **Symbology → Singleband pseudocolor → Cumulative count cut 2/98 → Inferno**.

## Notes

- Set `RUN_PART <- "BOTH"` only when re-running on data where the orthomosaic already exists.
- Thermal data from DJI M3T images is stored as a binary blob inside the R-JPEG; this script calls the DJI Thermal SDK (`dji_irp`) to extract calibrated float32 values.
- Flight image naming convention expected: `*_T.JPG` for thermal, `*_V.JPG` for corresponding RGB.

## License

Originally created by Teja Kattenborn https://github.com/tejakattenborn , modified by Daniel Nelson https://github.com/DanGeospatial/dji_m3t_rpeg_to_tif/tree/main and finally modified by me .
