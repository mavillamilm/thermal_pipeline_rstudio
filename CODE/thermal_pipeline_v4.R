# ==============================================================================
# dji_m3t_thermal_pipeline_v4.R
#
# One file, two stages, one settings block.
#
#   PART A  -- convert raw DJI R-JPEGs (*_T.JPG) to calibrated float TIFFs
#   ----  (run Metashape / Pix4D in between to build the orthomosaic)  ----
#   PART B  -- clean the stitched orthomosaic (mask edges, clip junk, write
#              an analysis-ready single-band GeoTIFF) and quick-plot it
#
# HOW TO USE
#   1. Edit the CONFIG block below once (paths + flight parameters).
#   2. Run PART A:  select from the "PART A" banner down to the "END PART A"
#      banner, press Ctrl+Enter (or set RUN_PART <- "A" and source the file).
#   3. Build the orthomosaic in Metashape, export it as a GeoTIFF, and put
#      its path in ortho_in below.
#   4. Run PART B the same way (RUN_PART <- "B").
#
#   Tip: set RUN_PART to "A", "B", or "BOTH". "BOTH" only makes sense if the
#   orthomosaic already exists (i.e. you are re-running).
#
# Based on original work by Teja Kattenborn & Daniel Nelson (GPL-3).
# ==============================================================================

## ===== CONFIG (edit this block only) =========================================

# Which stage to run when you source the whole file: "A", "B", or "BOTH"
RUN_PART <- "B"

## --- shared ---
# DJI Thermal SDK binary folder (must contain dji_irp.exe on Windows):
sdk_dir <- "C:/dji_thermal_sdk_v1.8_20250829/utility/bin/windows/release_x64"

## --- PART A: conversion ---
in_dir  <- "C:/UAV_DATA/RAW_FLIGHTS/FCB_CORN_20260615_F023"
out_dir <- "C:/UAV_DATA/PROCESSED/FCB_CORN_20260615_F023"

emissivity <- 0.96   # 0.10-1.00 (vegetation ~0.95-0.98)
humidity   <- 68.3     # relative humidity %, 20-100
distance   <- 11     # camera-target distance m (SDK caps at 25)
reflection <- 28     # reflected apparent temperature deg C (~air temp)

spare_cores <- 2     # CPU cores to leave free

## --- PART B: orthomosaic cleanup ---
# The orthomosaic you exported from Metashape (band 1 = temp, band 2 = Alpha):
ortho_in   <- "C:/UAV_DATA/METASHAPE_PROJECTS/FCB_CORN_20260615_F023/FCB_CORN_20260615_F023_MOSAIC.tif"
# Where to write the cleaned, analysis-ready single-band file:
ortho_out  <- "C:/UAV_DATA/METASHAPE_PROJECTS/FCB_CORN_20260615_F023/thermal_ortho_clean.tif"
  

temp_min_valid <- 5    # clip pixels below this (deg C) -> not real canopy
temp_max_valid <- 50   # clip pixels above this (deg C) -> not real canopy

## ===== END CONFIG ============================================================


# ==============================================================================
# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>  PART A: CONVERSION  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# ==============================================================================
if (RUN_PART %in% c("A", "BOTH")) {

  library(ijtiff)
  library(exifr)
  library(foreach)
  library(doParallel)

  is_windows <- .Platform$OS.type == "windows"
  irp_bin <- file.path(sdk_dir, if (is_windows) "dji_irp.exe" else "dji_irp")
  if (!file.exists(irp_bin))
    stop("DJI Thermal SDK binary not found at: ", irp_bin)

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  in_files <- list.files(in_dir, full.names = TRUE, recursive = TRUE,
                         pattern = "_T\\.(jpg|jpeg)$", ignore.case = TRUE)
  if (length(in_files) == 0)
    stop("No *_T.JPG thermal images found in: ", in_dir)
  message(length(in_files), " thermal images found.")

  exif_tags <- c("Model", "Make", "Orientation", "FocalLength",
                 "FocalLengthIn35mmFormat", "DigitalZoomRatio", "ApertureValue",
                 "GPSAltitude", "GPSAltitudeRef",
                 "GPSLatitude", "GPSLatitudeRef",
                 "GPSLongitude", "GPSLongitudeRef",
                 "DateTimeOriginal", "CreateDate",
                 "ImageWidth", "ImageHeight")

  message("Reading EXIF metadata of all images (one batch call)...")
  exif_all <- exifr::read_exif(in_files, tags = exif_tags)

  build_exif_args <- function(row) {
    tags <- c("Model", "Make", "Orientation", "FocalLength",
              "FocalLengthIn35mmFormat", "DigitalZoomRatio", "ApertureValue",
              "GPSAltitude", "GPSAltitudeRef",
              "GPSLatitude", "GPSLatitudeRef",
              "GPSLongitude", "GPSLongitudeRef",
              "DateTimeOriginal", "CreateDate")
    args <- character(0)
    for (tg in tags) {
      val <- row[[tg]]
      if (!is.null(val) && length(val) == 1 && !is.na(val))
        args <- c(args, paste0("-", tg, "=", val))
    }
    c(args, "-overwrite_original")
  }

  n_cores <- max(1, parallel::detectCores() - spare_cores)
  clust   <- makeCluster(n_cores)
  registerDoParallel(clust)
  message("Converting on ", n_cores, " cores...")

  log_df <- foreach(i = seq_along(in_files),
                    .combine  = rbind,
                    .packages = c("ijtiff", "exifr")) %dopar% {

    in_name <- in_files[i]
    status  <- "ok"; msg <- ""

    tryCatch({
      row <- exif_all[exif_all$SourceFile == in_name, ][1, ]
      w <- row$ImageWidth; h <- row$ImageHeight
      if (is.na(w) || is.na(h)) { w <- 640; h <- 512 }

      base     <- tools::file_path_sans_ext(basename(in_name))
      out_raw  <- file.path(out_dir, paste0(base, ".raw"))
      out_tif  <- file.path(out_dir, paste0(base, ".tif"))

      res <- system2(irp_bin,
                     args = c("-s", shQuote(in_name),
                              "-a", "measure",
                              "-o", shQuote(out_raw),
                              "--measurefmt", "float32",
                              "--emissivity", emissivity,
                              "--humidity",   humidity,
                              "--distance",   distance,
                              "--reflection", reflection),
                     stdout = TRUE, stderr = TRUE)
      if (!file.exists(out_raw) || file.size(out_raw) == 0)
        stop("dji_irp produced no output: ", paste(res, collapse = " | "))

      n_px <- file.size(out_raw) / 4
      if (n_px != w * h)
        stop(sprintf("size mismatch: raw has %d px, EXIF says %dx%d", n_px, w, h))

      raw_vals <- readBin(out_raw, what = "double", size = 4,
                          n = n_px, endian = "little")
      img <- matrix(raw_vals, nrow = h, ncol = w, byrow = TRUE)
      ijtiff::write_tif(img, path = out_tif, overwrite = TRUE, msg = FALSE)

      exifr::exiftool_call(args = build_exif_args(row), fnames = out_tif,
                           quiet = TRUE)
      file.remove(out_raw)

    }, error = function(e) {
      status <<- "error"; msg <<- conditionMessage(e)
    })

    data.frame(file = basename(in_name), status = status, message = msg,
               stringsAsFactors = FALSE)
  }

  stopCluster(clust)

  write.csv(log_df, file.path(out_dir, "conversion_log.csv"), row.names = FALSE)
  n_ok  <- sum(log_df$status == "ok")
  n_err <- sum(log_df$status == "error")
  message(n_ok, " images converted, ", n_err, " failed.")
  if (n_err > 0) {
    message("Failed images (see conversion_log.csv):")
    print(log_df[log_df$status == "error", c("file", "message")])
  }
  message("PART A done. Output written to: ", out_dir)
  message(">>> Next: build the orthomosaic in Metashape, then run PART B.")
}
# ============================  END PART A  ====================================


# ==============================================================================
# >>>>>>>>>>>>>>>>>>>>>>>>>>>  PART B: ORTHO CLEANUP  <<<<<<<<<<<<<<<<<<<<<<<<<<<<
# ==============================================================================
if (RUN_PART %in% c("B", "BOTH")) {

  library(terra)

  if (!file.exists(ortho_in))
    stop("Orthomosaic not found at: ", ortho_in,
         "\n   (Export it from Metashape first, then set ortho_in.)")

  o <- rast(ortho_in)
  message("Loaded orthomosaic with ", nlyr(o), " band(s).")
  print(global(o[[1]], c("min", "max"), na.rm = TRUE))

  temp <- o[[1]]

  # If an Alpha band exists (band 2), use it to drop the empty edge pixels
  if (nlyr(o) >= 2) {
    message("Masking edge pixels using the Alpha band...")
    temp <- mask(temp, o[[2]], maskvalues = 0)
  } else {
    message("No Alpha band found; relying on value clipping only.")
  }

  # Clip physically-impossible values (edge/blend artifacts)
  temp[temp < temp_min_valid] <- NA
  temp[temp > temp_max_valid] <- NA

  message("Cleaned temperature range:")
  print(global(temp, c("min", "max", "mean"), na.rm = TRUE))

  writeRaster(temp, ortho_out, overwrite = TRUE, NAflag = -9999)
  message("PART B done. Clean ortho written to: ", ortho_out)

  # Quick visual check (independent of QGIS)
  plot(temp, col = hcl.colors(100, "Inferno"),
       main = "Canopy temperature (deg C)")

  message(">>> Load this file in QGIS: ", ortho_out)
  message("    Symbology > Singleband pseudocolor > Cumulative count cut 2/98 > Inferno")
}
# ============================  END PART B  ====================================
