### LANDFIRE Project
### APEX RMS - Shreeram Senthivasan
### November 2020
### This a header file with global variables used by other scripts in this directory.
### Please check the paths and options set here prior to running the other scripts.

# Load Config -----------------------------------------------------------

config <- read_yaml("config/config.yaml")

# Parse Config ----------------------------------------------------------

if (!config$dataFolder %>% dir.exists) {
  stop("Could not find input data folder. Please check config file.")
}

if (!config$mapzonesToKeep %>% is.integer) {
  stop("Invalid list of Map Zones to keep. Please check config file.")
}

if (!all(config$tsdToRemove %in% 1:3)) {
  stop("Invalid list of TSD codes to filter out. Please check config file.")
}

# Check that the number of requested R threads is valid
if (config$nThreads %>% is.null) {
  nThreads <- future::availableCores()
  message("Using all available cores to build SyncroSim Library")
} else if (
  config$nThreads %>% as.integer %>% is.na | config$nThreads %>% as.integer < 1
) {
  nThreads <- future::availableCores()
  warning(
    "Invalid number of threads requested. Using all available cores to build SyncroSim Library"
  )
} else {
  nThreads <- config$nThreads
}

# Check that the number of requested SyncroSim jobs is valid
if (
  config$ssimJobs %>% as.integer %>% is.na | config$ssimJobs %>% as.integer < 1
) {
  ssimJobs <- 8
  warning(
    "Invalid number of SyncroSim jobs requested. Using default value of 8 SyncroSim jobs to run the library after building."
  )
}

# Check that the number of tiling columns is valid
if (as.integer(config$tileSize) %>% is.na) {
  warning(
    "Invalid number of tile size in config file. Using default tile size of 250."
  )
  config$tileSize <- 250
}

# Check whether or not crop to a smaller extent for testing
cropToExtent <- FALSE
if (config$cropToExtent == "1") {
  cropToExtent <- TRUE
} else if (config$cropToExtent != "0") {
  warning(
    "Unrecognized value for `cropToExtent` in config file. Not cropping to extent!"
  )
}


# Overall Options --------------------------------------------------------

# Which mapzones to process
mapzonesToKeep <- config$mapzonesToKeep

# Tags used to identify the independent runs (one per Map Zone)
# They are used to generate names for output folders, etc
runTags <- str_c("Map Zone ", mapzonesToKeep)

# The name of the SyncroSim library to store the scenario, etc. in
runLibrary <- config$libraryName

tsdToRemove <- config$tsdToRemove

# SyncroSim installation directory
# - If left blank (NA), convert to NULL to use default installation location
ssimDir <- config$ssimDir

# Log file path
logFilePath <- "run.log"
dir.create("log", showWarnings = F)

# Raw Inputs --------------------------------------------------------------

# Directory holding raw rasters
rawRasterDirectory <- str_c(config$dataFolder, "/raw/")
if (!rawRasterDirectory %>% dir.exists) {
  stop(
    "The raw data subfolder was not found within input data folder! Please see the README for how the input data folder should be organized."
  )
}

# Raw input rasters
mapzoneRawRasterPath <- str_c(rawRasterDirectory, "Map Zones.tif")
evtRawRasterPath <- str_c(rawRasterDirectory, "EVT.tif")
evhRawRasterPath <- str_c(rawRasterDirectory, "EVH.tif")
evcRawRasterPath <- str_c(rawRasterDirectory, "EVC.tif")
fdistRawRasterPath <- str_c(rawRasterDirectory, "FDIST.tif")

# Check that all input rasters are present
if (!mapzoneRawRasterPath %>% file.exists) {
  stop(
    "Could not find the raw Map Zone raster map. Please see the README for how input data should be organized."
  )
}
if (!evtRawRasterPath %>% file.exists) {
  stop(
    "Could not find the raw EVT raster map. Please see the README for how input data should be organized."
  )
}
if (!evhRawRasterPath %>% file.exists) {
  stop(
    "Could not find the raw EVH raster map. Please see the README for how input data should be organized."
  )
}
if (!evcRawRasterPath %>% file.exists) {
  stop(
    "Could not find the raw EVC raster map. Please see the README for how input data should be organized."
  )
}
if (!fdistRawRasterPath %>% file.exists) {
  stop(
    "Could not find the raw FDIST raster map. Please see the README for how input data should be organized."
  )
}

# Raw non-spatial data directory
rawNonSpatialDirectory <- str_c(rawRasterDirectory, "nonspatial/")
if (!rawNonSpatialDirectory %>% dir.exists) {
  stop(
    "The raw, non-spatial data subfolder was not found within input data folder! Please see the README for how the input data folder should be organized."
  )
}

# Load all non-spatial data
transitionTablePath <- str_c(rawNonSpatialDirectory, "Transition Table.csv")
evtColorTablePath <- str_c(rawNonSpatialDirectory, "EVT Colors.csv")

if (!transitionTablePath %>% file.exists) {
  stop(
    "Could not find the file `Transition Table.csv`. This file outlines all transition rules. Please see the README for how input data should be organized."
  )
}
if (!evtColorTablePath %>% file.exists) {
  stop(
    "Could not find the file `EVT Colors.csv`. This file is used to connect EVT codes to colors for mapping. Please see the README for how input data should be organized."
  )
}

# Load shared non-spatial data
sharedNonSpatialDirectory <- "data/shared/"

allowedStatesPath <- str_c(sharedNonSpatialDirectory, "All Combinations.csv")
distCrosswalkPath <- str_c(
  sharedNonSpatialDirectory,
  "Disturbance Crosswalk.csv"
)
evcCrosswalkPath <- str_c(sharedNonSpatialDirectory, "EVC Crosswalk.csv")
evhCrosswalkPath <- str_c(sharedNonSpatialDirectory, "EVH Crosswalk.csv")
evcTablePath <- str_c(sharedNonSpatialDirectory, "EVC LUT.csv")
evhTablePath <- str_c(sharedNonSpatialDirectory, "EVH LUT.csv")
vdistTablePath <- str_c(sharedNonSpatialDirectory, "VDIST LUT.csv")
evcColorsPath <- str_c(sharedNonSpatialDirectory, "EVC Colors.csv")
recentlyDisturbedPath <- str_c(
  sharedNonSpatialDirectory,
  "Recently Disturbed EVT.csv"
)

if (!allowedStatesPath %>% file.exists) {
  stop(
    "Could not find the file `All Combinations.csv`. This file provides every valid combination of EVT, EVC, EVH, and Map Zone. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!distCrosswalkPath %>% file.exists) {
  stop(
    "Could not find the file `Disturbance Crosswalk.csv`. This file is used to convert FDIST codes to VDIST. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!evcCrosswalkPath %>% file.exists) {
  stop(
    "Could not find the file `EVC Crosswalk.csv`. This file is used to convert continuous EVC codes to categorical codes. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!evhCrosswalkPath %>% file.exists) {
  stop(
    "Could not find the file `EVH Crosswalk.csv`. This file is used to convert continuous EVH codes to categorical codes. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!evcTablePath %>% file.exists) {
  stop(
    "Could not find the file `EVC LUT.csv`. This file is used to connect EVC codes to names. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!evhTablePath %>% file.exists) {
  stop(
    "Could not find the file `EVH LUT.csv`. This file is used to connect EVH codes to names. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!vdistTablePath %>% file.exists) {
  stop(
    "Could not find the file `VDIST LUT.csv`. This file is used to connect disturbance codes to names and disturbance types. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!evcColorsPath %>% file.exists) {
  stop(
    "Could not find the file `EVC Colors.csv`. This file is used to connect EVC codes to colors for mapping. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}
if (!recentlyDisturbedPath %>% file.exists) {
  stop(
    "Could not find the file `Recently Disturbed EVT.csv`. This file provides the list of EVT codes for recently disturbed cells. This file should be provided by the GitHub repo, please check that the project repository is up to date."
  )
}

# Default Maps and Charts -----------------------------------------------

# Note: Temporarily removed

# defaultChartsPath <- str_c(sharedNonSpatialDirectory, "Default SyncroSim Charts.csv")
# defaultMapsPath   <- str_c(sharedNonSpatialDirectory, "Default SyncroSim Maps.csv")
#
# if(!defaultChartsPath %>% file.exists)
#   stop("Could not find the file `Default SyncroSim Charts.csv`. This file describes how the default charts in SyncroSim should be built. This file should be provided by the GitHub repo, please check that the project repository is up to date.")
# if(!defaultMapsPath %>% file.exists)
#   stop("Could not find the file `Default SyncroSim Maps.csv`. This file describes how the default maps in SyncroSim should be built. This file should be provided by the GitHub repo, please check that the project repository is up to date.")

# Output Raster Options ---------------------------------------------------

# Setup crop extent
if (cropToExtent) {
  # Check that file defining crop extent exists
  if (!config$cropExtentPath %>% file.exists) {
    stop(
      "File defining crop extent not found! Please correct the `cropExtentPath` or disable `cropToExtent`."
    )
  }

  # Read in crop data
  cropData <- read_csv(config$cropExtentPath) %>%
    pull(2, name = 1) %>% # Extract column 2, and use column 1 as names
    as.list()

  # Check that format is correct
  if (any(cropData %>% names %>% sort != c("xmax", "xmin", "ymax", "ymin"))) {
    stop(
      "The format of the crop extent definition is not valid! Please correct the format or disable `cropToExtent`. Please see the examples in `config/Crop Extents/ for appropriate formats."
    )
  }

  cropExtent <- extent(
    cropData$xmin,
    cropData$xmax,
    cropData$ymin,
    cropData$ymax
  )
}

# A tiling mask is produced to allow for Spatial Multiprocessing in SyncroSim
# The size of the rows is dictated by the size of the raster and memory constraints,
# but the number of columns can be set here
tileSize <- as.integer(config$tileSize * 1000)

# As part of the processing step, cleaned and cropped rasters are built.
# This is the directory they will be organized in. Each Map Zone will have it's
# own subdirectory within this folder and the absolute path must also be
# constructed for SyncroSim later.
cleanRasterDirectoryRelative <- str_c(config$dataFolder, "/clean/")

# After running the SyncroSim library, it is often useful to stitch the
# individual Map Zone raster maps back into the full Geo Area.
# This is the directory the stitched raster maps will be stored in
stitchedRasterDirectory <- str_c(config$dataFolder, "/stitched/")

# Run Controls  -------------------------------------------------------

minimumIteration <- 1
maximumIteration <- 1
minimumTimestep <- 0
maximumTimestep <- 1

# SyncroSim Options -----------------------------------------------------
libraryName <- str_c("library/", runLibrary)
projectName <- config$projectName
subScenarioName <- "Shared Model Info"
scenarioNames <- runTags

# Set the owner for all SyncroSim objects
ssimOwner <- "LANDFIRE"

# Set descriptions for SyncroSim objects
libraryDescription <- str_c(
  "ST-Sim library for updating LANDFIRE EVC and ",
  "EVH based on starting MZ, EVT, EVC, EVH and ",
  "disturbances during the update period."
)
projectDescription <- str_c("Models for updating the ", config$projectName)
subScenarioDescription <- str_c(
  "Sub Scenario used to define common model info ",
  "used by all other scenarios in the project."
)
scenarioDescriptions <- str_c("Model scenario for Map Zone ", mapzonesToKeep)

# Set the number of concurrent jobs to in SyncroSim
ssimJobs <- as.integer(config$ssimJobs)
