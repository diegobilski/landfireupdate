### LANDFIRE Project
### APEX RMS - Shreeram Senthivasan
### November 2020
### The function defined in this script is used to convert disturbance rasters
### into binary rasters for each disturbance level. These will later be used by
### SyncroSim as transition spatial multipliers

layerizeDisturbance <- function(runTag) {
  # Generate run-specific file paths ---------------------------------------

  # Directory to store cleaned rasters
  # Note that the working directory is prepended since SyncroSim needs absolute paths
  cleanRasterDirectory <- str_c(
    getwd(),
    "/",
    cleanRasterDirectoryRelative,
    "/",
    runTag,
    "/"
  )

  # Directory and prefix for FDIST binary rasters (spatial multipliers)
  transitionMultiplierDirectory <- str_c(
    cleanRasterDirectory,
    "transitionMultipliers/"
  )
  dir.create(transitionMultiplierDirectory, showWarnings = F)

  # Clean Raster Paths
  vdistRasterPath <- str_c(cleanRasterDirectory, "VDIST.tif")

  # VDIST info for layerizing
  vdistInfoPath <- str_c(cleanRasterDirectory, "VDIST.csv")

  # Load Data -----------------------------------------------------------------
  vdistInfo <- read_csv(vdistInfoPath)
  vdistRaster <- rast(vdistRasterPath)

  # Layerize disturbace raster -------------------------------------------------

  # Note: Temporarily restructuring parallelization for compatibility with new layerizing code
  # # Begin parallel processing
  # #plan(multisession, workers = nThreads)
  plan(sequential)

  # Split the VDIST raster into binary layers
  # One layer is constructed at a time per thread to limit memory use per thread
  future_walk2(
    vdistInfo$vdist,
    vdistInfo$name,
    saveDistLayer,
    fullRaster = vdistRaster,
    transitionMultiplierDirectory = transitionMultiplierDirectory,
    .options = furrr_options(seed = TRUE)
  )

  # Return to sequential operation
  plan(sequential)
}
