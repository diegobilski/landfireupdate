### LANDFIRE Project
### APEX RMS - Shreeram Senthivasan
### December 2020
### This script is used to reconstruct EVC and EVH raster maps for an entire
### Geo Area using the output of the SyncroSim library constructed by the
### `batchProcess.R` script

# Setup -----------------------------------------------------------------------

library(rsyncrosim) # for building and connecting to SyncroSim files
library(terra) # provides functions for manipulating rasters
library(furrr) # for parallel iteration
library(logr) # for generating logs with RScript
library(tidyverse) # provides general data manipulation functions
library(yaml) # used to read configuration file

terraOptions(memmax = 3)

# Load configuration options and global constants
source("scripts/constants.R")

# Load custom raster functions optimized for working with large rasters
source("scripts/rasterFunctions.R")

# Begin logging ------------------------------------------------------------

logFile <- log_open(logFilePath)

# Generate Directories and Paths -----------------------------------------------

log_print("Preparing stitched raster map output folder.")

# Build temp folder names for each step of reconstruction
categoricalTempFolder <- str_c(stitchedRasterDirectory, "categorical/")
continuousTempFolder <- str_c(stitchedRasterDirectory, "continuous/")
evcCategoricalTempFolder <- str_c(stitchedRasterDirectory, "categorical/evc/")
evhCategoricalTempFolder <- str_c(stitchedRasterDirectory, "categorical/evh/")
evcContinuousTempFolder <- str_c(stitchedRasterDirectory, "continuous/evc/")
evhContinuousTempFolder <- str_c(stitchedRasterDirectory, "continuous/evh/")

# Delete outputs from previous run to avoid mixing results
unlink(file.path(stitchedRasterDirectory), recursive = T)

# Create directory and paths to store stitched raster maps
dir.create(stitchedRasterDirectory, showWarnings = F)
dir.create(categoricalTempFolder, showWarnings = F)
dir.create(continuousTempFolder, showWarnings = F)
dir.create(evcCategoricalTempFolder, showWarnings = F)
dir.create(evhCategoricalTempFolder, showWarnings = F)
dir.create(evcContinuousTempFolder, showWarnings = F)
dir.create(evhContinuousTempFolder, showWarnings = F)

# Calculate final extent of the stitched rasters
fullExtent <- ext(rast(mapzoneRawRasterPath))

# Load necessary raw raster maps
evcContinuousRawRaster <- rast(evcRawRasterPath)
evhContinuousRawRaster <- rast(evhRawRasterPath)

# Create names for the output rasters
evcOverlaidRasterPath <- str_c(stitchedRasterDirectory, "EVC.tif")
evhOverlaidRasterPath <- str_c(stitchedRasterDirectory, "EVH.tif")

# Extract Data from SyncroSim Library ------------------------------------------

log_print("Loading data from SyncroSim.")

# Connect to the SyncroSim Library
ssimSession <- session(ssimDir)
mylibrary <- ssimLibrary(libraryName, session = ssimSession)
myproject <- rsyncrosim::project(mylibrary, projectName)

# Find the list of result scenarios
# - Keep only the last successful run from each scenario

# Create a sink to capture verbose output
sink("temp.sink")

resultScenarios <- scenario(mylibrary, summary = T) %>%

  # Only consider result scenarios
  filter(IsResult == "Yes") %>%

  # Examine run logs to see which runs failed
  mutate(
    failed = map_lgl(
      ScenarioId,
      ~ scenario(mylibrary, .x) %>%
        runLog %>%
        str_detect("Failure")
    )
  ) %>%

  # Remove failed runs
  filter(failed == FALSE) %>%

  # Only keep last run from each parent scenario
  group_by(ParentId) %>%
  filter(ScenarioId == max(ScenarioId)) %>%
  pull(ScenarioId)

# Close and delete sink
sink()
unlink("temp.sink")

if (length(resultScenarios) == 0) {
  stop(str_c(
    "No result scenarios found! Please ensure that you've run the relevant ",
    "SyncroSim scenarios and that the library and project name set in the ",
    "config file match those of the maps you are trying to reconstruct."
  ))
}

# Pull out the relevant raster from each result scenario as a list without using raster
stateClassRasters <-
  map(resultScenarios, function(sid) {
    datasheetSpatRaster(
      scenario(mylibrary, sid),
      "stsim_OutputSpatialState",
      timestep = 1
    )
  })

# Keep track of the number of Map Zones for later
mapzoneCount <- length(stateClassRasters)

# Generate a raster file name for each result scenario found
rasterFileNames <- str_c(seq(mapzoneCount), ".tif")

log_print(str_c(
  "Found ",
  mapzoneCount,
  " valid scenario(s)! Please check that this is correct!"
))

# Generate EVC and EVH from State Class ----------------------------------------

log_print("Separating out EVC and EVH.")

# Begin parallel processing
# plan(multisession, workers = nThreads)
# Note: Currently running sequentially due to potential parallel access issues with terra
plan(sequential)

future_pwalk(
  list(
    stateClassRaster = stateClassRasters,
    evcRasterPath = str_c(evcCategoricalTempFolder, rasterFileNames),
    evhRasterPath = str_c(evhCategoricalTempFolder, rasterFileNames)
  ),
  separateStateClass,
  .options = furrr_options(seed = TRUE)
)

# Return to sequential operation
plan(sequential)

# Convert EVC and EVH to continuous codes --------------------------------------

log_print("Converting EVC and EVH to continuous codes.")

# Load necessary rasters
evcRasters <- map(str_c(evcCategoricalTempFolder, rasterFileNames), rast)
evhRasters <- map(str_c(evhCategoricalTempFolder, rasterFileNames), rast)

# Generate necessary file names
evcContRasterPaths <- str_c(evcContinuousTempFolder, rasterFileNames)
evhContRasterPaths <- str_c(evhContinuousTempFolder, rasterFileNames)

# Setup the two crosswalks from class codes to continuous codes
evcCrosswalk <-
  read_csv(evcTablePath) %>%
  select(from = VALUE, to = CONTINUOUS) %>%
  as.matrix

evhCrosswalk <-
  read_csv(evhTablePath) %>%
  select(from = VALUE, to = CONTINUOUS) %>%
  as.matrix

# Begin parallel processing
# plan(multisession, workers = nThreads)
# Note: Currently running sequentially due to potential parallel access issues with terra
plan(sequential)

# Reclassify both rasters using the constructed crosswalks and raster::reclassify()
evcContinuousRasters <-
  future_pmap(
    list(
      x = evcRasters,
      filename = evcContRasterPaths
    ),
    classify,
    rcl = evcCrosswalk,
    overwrite = TRUE,
    .options = furrr_options(seed = TRUE)
  )

evhContinuousRasters <-
  future_pmap(
    list(
      x = evhRasters,
      filename = evhContRasterPaths
    ),
    classify,
    rcl = evhCrosswalk,
    overwrite = TRUE,
    .options = furrr_options(seed = TRUE)
  )

# Return to sequential operation
plan(sequential)

# We can now remove the categorical EVC and EVH folder
unlink(file.path(categoricalTempFolder), recursive = T)

# Stitch and overlay disturbed EVC and EVH over initial EVC and EVH ------------

log_print("Stitching and overlaying raster maps.")

# If in test mode, crop down the raw continuous EVC and EVH maps
if (cropToExtent) {
  evcContinuousRawRaster <- crop(evcContinuousRawRaster, cropExtent)
  evhContinuousRawRaster <- crop(evhContinuousRawRaster, cropExtent)

  # Also update the extent to use for merging
  fullExtent <- cropExtent
}

# Append arguments for `raster::merge()` to the previously generated list of rasters
# This will allow us to pass a variable number of arguments to `raster::merge()`
# using `do.call()`

evcMergeArgs <- c(
  evcContinuousRasters, # the updated continuous data
  evcContinuousRawRaster, # the undisturbed continuous data
  filename = evcOverlaidRasterPath, # output file name
  #ext = fullExtent,                      # the final extent of the raster - Note: not recognized by terra::merge
  wopt = list(list(
    datatype = 'INT2S', # used signed integers for output
    overwrite = T
  ))
)

evhMergeArgs <- c(
  evhContinuousRasters, # the updated continuous data
  evhContinuousRawRaster, # the undisturbed continuous data
  filename = evhOverlaidRasterPath, # output file name
  #ext = fullExtent,                      # the final extent of the raster - Note: not recognized by terra::merge
  wopt = list(list(
    datatype = 'INT2S', # used signed integers for output
    overwrite = T
  ))
)

# Use raster::merge() to overlay the new continuous data over the old continuous
# EVC and EVH raster maps
evcOverlaidRaster <- do.call(terra::merge, evcMergeArgs)
evhOverlaidRaster <- do.call(terra::merge, evhMergeArgs)

# Finally we can remove the unmerged continuous EVC and EVH folder
unlink(file.path(continuousTempFolder), recursive = T)

# Wrap up ----------------------------------------------------------------------

log_print(str_c(
  "Done reconstructing Geo Area! ",
  "Stitched raster maps can be found in ",
  stitchedRasterDirectory
))

log_close()
