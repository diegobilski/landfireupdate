### LANDFIRE Project
### APEX RMS - Valentin Lucet and Shreeram Senthivasan
### November 2020
### Function to generate SyncroSim library, project, and scenarios for each Map
### Zone using the cleaned rasters genereated by `scripts/processSpatialData.R`
### and `scripts/layerizeDisturbance.R`

initializeSsimLibrary <- function(libraryName, projectName) {
  # Prepare input data ---------------------------------------------------

  # Load the lookup table that will be used to color state classes by their EVC code
  # This table defines colors for cover type in 1% bins, but the data is in 10% bins
  # The filter and mutate steps below convert the 1% binned EVC codes to 10% codes
  evcColors <- read_csv(evcColorsPath) %>%
    transmute(
      EVC = VALUE,
      Color = paste("255", R, G, B, sep = ",")
    ) %>%
    # Only the codes above 100 differ between the two EVC code systems
    # Of these differing codes, we keep every 10th (eg. 10%, 20%, etc )
    filter(EVC < 100 | EVC %% 10 == 0) %>%
    # The 1% resolution code stores lifeform (tree, shrub, etc) in the 100th's digit,
    # The 10% stores this in the 10th's digit, so we divide by 10
    # Finally we add 90 to shift the correct color to the the correct lifeform
    mutate(
      EVC = if_else(EVC <= 100, true = EVC, false = EVC / 10 + 90)
    )

  ## Load table of all valid combinatiosn of Map Zone, EVT, EVH, and EVC
  allowedStates <- read_csv(allowedStatesPath)

  ## Generate a table of all unique transitions

  # Should be unique for every VDIST, PrimaryStratum, EvT, SourceStateClass
  transitionTable <- read_csv(transitionTablePath) %>%
    # Select and rename variables of importance
    dplyr::select(
      MZ,
      VDIST,
      EVT7B,
      StratumIdSource = EVT7B_Name,
      EVCB,
      EVHB,
      EVCR,
      EVHR
    ) %>%
    # Change the naming convention of MapZones e.g. from "1" to "MZ01"
    mutate(SecondaryStratumId = paste0("MZ", str_pad(MZ, 2, "left", "0"))) %>%
    # Keep only unique rows
    unique()

  # Check that EVT names are uniquely assigned to EVT IDs
  nonUniqueEVT <- transitionTable %>%
    dplyr::select(EVT7B, StratumIdSource) %>%
    unique() %>%
    dplyr::group_by(EVT7B) %>%
    dplyr::summarize(n = n(), names = list(StratumIdSource)) %>%
    dplyr::filter(n > 1)

  if (nrow(nonUniqueEVT) > 0) {
    # Build a neatly formatted list of non-unique EVT IDs and corresponding names
    nonUniqueEVTNames <- nonUniqueEVT %>%
      pmap_chr(function(EVT7B, n, names) {
        str_c(EVT7B, " : \"", str_c(names, collapse = "\" ; \""), "\"")
      }) %>%
      str_c(collapse = "\n")

    stop(
      "One or more EVT IDs in the transition table are assigned to multiple EVT Names. Please correct the following:\n",
      nonUniqueEVTNames
    )
  }

  ## Generate look-up tables for EVC and EVH codes and names

  EVClookup <- read_csv(evcTablePath) %>%
    # Make unique names for when class names are repeated
    mutate(
      CLASSNAMES = coalesce(CLASSNAMES, str_c(EVT_LIFEFORM, "_", VALUE))
    ) %>%
    # Select relevant columns and rename with stsim relevant column names
    dplyr::select(VALUE, CLASSNAMES) %>%
    rename(EVC = VALUE, StateLabelXId = CLASSNAMES) %>%
    # Shorten EVC names for cleaner SyncroSim UI
    mutate(
      StateLabelXDescription = StateLabelXId,
      StateLabelXId = str_replace(StateLabelXId, " and <=? ", "-"),
      StateLabelXId = str_replace(StateLabelXId, "Tree Cover >=", "Tr"),
      StateLabelXId = str_replace(StateLabelXId, "Tree Cover <", "Tr <"),
      StateLabelXId = str_replace(StateLabelXId, "Shrub Cover >=", "Sh"),
      StateLabelXId = str_replace(StateLabelXId, "Herb Cover >=", "Hb")
    )

  EVHlookup <- read_csv(evhTablePath) %>%
    mutate(CLASSNAMES = coalesce(CLASSNAMES, str_c(LIFEFORM, "_", VALUE))) %>%
    dplyr::select(VALUE, CLASSNAMES) %>%
    rename(EVH = VALUE, StateLabelYId = CLASSNAMES) %>%
    # Shorten EVH names for cleaner SyncroSim UI
    mutate(
      StateLabelYDescription = StateLabelYId,
      StateLabelYId = str_replace(StateLabelYId, " to ", "-"),
      StateLabelYId = str_replace(StateLabelYId, " meters?", "m"),
      StateLabelYId = str_replace(StateLabelYId, "Forest Height", "Fr"),
      StateLabelYId = str_replace(StateLabelYId, "Shrub Height", "Sh"),
      StateLabelYId = str_replace(StateLabelYId, "Herb Height", "Hb"),
      StateLabelYId = str_replace(StateLabelYId, " 0-", " < "),
    )

  # Add EVC and EVH names to transition table

  transitionTable <- transitionTable %>%

    # First join EVC B and R, renaming appropriately
    left_join(EVClookup, by = c("EVCB" = "EVC")) %>%
    rename(EVCB_Name = StateLabelXId) %>%
    left_join(EVClookup, by = c("EVCR" = "EVC")) %>%
    rename(EVCR_Name = StateLabelXId) %>%
    dplyr::select(-StateLabelXDescription.x, -StateLabelXDescription.y) %>%

    # Similarly for EVH
    left_join(EVHlookup, by = c("EVHB" = "EVH")) %>%
    rename(EVHB_Name = StateLabelYId) %>%
    left_join(EVHlookup, by = c("EVHR" = "EVH")) %>%
    rename(EVHR_Name = StateLabelYId) %>%
    dplyr::select(-StateLabelYDescription.x, -StateLabelYDescription.y) %>%

    # Create the State Class names from EVC : EVH combinations
    mutate(
      StateClassIdSource = paste0(EVCB_Name, " : ", EVHB_Name),
      StateClassIdDest = paste0(EVCR_Name, " : ", EVHR_Name)
    ) %>%

    # Add the probability column with all set to 1
    mutate(Probability = 1)

  # Build the SyncroSim Library ---------------------------------------------

  # Ensure ST-Sim is installed
  installPackage("stsim")

  # Create library and project
  dir.create("library/", showWarnings = FALSE)
  ssimSession <- session(ssimDir)
  mylibrary <- ssimLibrary(
    libraryName,
    session = ssimSession,
    packages = "stsim",
    overwrite = TRUE
  )
  myproject <- rsyncrosim::project(mylibrary, projectName, overwrite = TRUE)
  myscenario <- scenario(myproject, subScenarioName, overwrite = TRUE)

  # Create a folder for the Sub Scenario and save the folder ID number
  subScenarioFolderID <- rsyncrosim::command(
    args = list(
      create = NULL,
      folder = NULL,
      lib = filepath(mylibrary),
      name = "Sub Scenarios",
      tpid = projectId(myproject)
    ),
    session = ssimSession
  ) %>%
    # "\\d+" is a regular expression to match numbers
    str_extract("\\d+") %>%
    as.integer

  # Move the Sub Scenario into the folder
  rsyncrosim::command(
    args = list(
      move = NULL,
      scenario = NULL,
      lib = filepath(mylibrary),
      name = "Sub Scenarios",
      sid = scenarioId(myscenario),
      tfid = subScenarioFolderID
    ),
    session = ssimSession
  ) %>%
    invisible()

  # Set owner
  owner(mylibrary) <- ssimOwner
  owner(myproject) <- ssimOwner
  owner(myscenario) <- ssimOwner

  # Set descriptions
  description(mylibrary) <- libraryDescription
  description(myproject) <- projectDescription
  description(myscenario) <- subScenarioDescription

  ## +Terminology -----------------------------------------------------------

  term <- data.frame(
    AmountLabel = "Area",
    AmountUnits = "acres",
    StateLabelX = "EVC",
    StateLabelY = "EVH",
    PrimaryStratumLabel = "EVT",
    SecondaryStratumLabel = "Map Zone",
    TimestepUnits = "Timestep"
  )
  saveDatasheet(ssimObject = myproject, data = term, name = "stsim_Terminology")

  ## +Strata ----------------------------------------------------------------

  # EVT is the primary stratum, MZ is the secondary stratum
  # No tertiary stratum
  # Important to take the unique values every time
  # Filter this dataframe by EVT values that are actually present in the input

  primary <- data.frame(
    Id = transitionTable$EVT7B,
    Name = transitionTable$StratumIdSource
  ) %>%
    unique()

  # Extract colors from the evt200 sheet
  # TODO: An issue here where some IDs do not have colors and some colors do not
  # have matching IDs.

  primaryWithColors <- read_csv(evtColorTablePath) %>%
    # Select relevant columns
    dplyr::select(VALUE, R, G, B) %>%
    # Take unique and rename for later joining
    unique() %>%
    rename(Id = VALUE) %>%
    # Create the color using the SyncroSim pattern of T, R, G, B
    mutate(Color = paste("255", R, G, B, sep = ",")) %>%
    # Join and select relevant columns
    right_join(primary, by = "Id") %>%
    dplyr::select(Id, Color, Name) %>%
    as.data.frame()

  # Save the datasheet
  saveDatasheet(myproject, primaryWithColors, "stsim_Stratum")

  # Repeat for secondary stratum (MapZone), with no colors

  secondary <- data.frame(
    Id = transitionTable$MZ,
    Name = transitionTable$SecondaryStratumId
  ) %>%
    unique()
  saveDatasheet(myproject, secondary, "stsim_SecondaryStratum")

  ## +State Classes --------------------------------------------------------

  # Copy in X and Y state names from the EVC and EVH lookups, respectively

  state_x <- data.frame(
    Name = EVClookup$StateLabelXId,
    Description = EVClookup$StateLabelXDescription
  ) %>%
    unique()

  saveDatasheet(myproject, state_x, "stsim_StateLabelX")

  state_y <- data.frame(
    Name = EVHlookup$StateLabelYId,
    Description = EVHlookup$StateLabelYDescription
  ) %>%
    unique()

  saveDatasheet(myproject, state_y, "stsim_StateLabelY")

  # Build the datasheet
  stateClasses <- allowedStates %>%
    # Join relevant data
    left_join(EVClookup) %>%
    left_join(EVHlookup) %>%
    left_join(evcColors) %>%
    # Generate unique State IDS based on the combination of X and Y state
    # To do this, we "paste" the X and Y state IDs together by multiplying
    # EVC by 1000 and adding it to EVH
    mutate(
      Id = EVC * 1000 + EVH,
      Name = str_c(StateLabelXId, " : ", StateLabelYId)
    ) %>%
    # Reorder and remove unneeded columns
    select(
      Id,
      Name,
      StateLabelXId = StateLabelXId,
      StateLabelYId = StateLabelYId,
      Color
    ) %>%
    # Keep only unique values
    unique() %>%
    as.data.frame()

  saveDatasheet(myproject, stateClasses, "stsim_StateClass")

  ## +Transition Types and Groups ------------------------------------------------

  # We gather disturbance types from the VDIST table
  vdistLookup <- read_csv(vdistTablePath) %>%
    # Select only what we need, then rename
    rename(Id = value, TransitionGroupId = d_type) %>%
    # Filter out the NO Disturbance category
    filter(Id != 0) %>%
    # Create unique transition/disturbance name, and format color
    # The format of the name is : Group, Severity, Frequency
    mutate(
      Name = paste(TransitionGroupId, d_severity, d_time, sep = " - "),
      Color = paste("255", R, G, B, sep = ",")
    ) %>%
    select(Id, Name, TransitionGroupId, Color)

  # Select the relevant columns, and filter by disturbances that are actually
  # present in the input raster
  transitionTypes <- vdistLookup %>%
    dplyr::select(Id, Name, Color) %>%
    unique() %>%
    as.data.frame()

  saveDatasheet(myproject, transitionTypes, "stsim_TransitionType")

  ## Transition Groups
  # For groups, we append the disturbance class to the existing datasheet
  transitionGroups <- vdistLookup %>%
    dplyr::select(Name = TransitionGroupId) %>%
    unique()

  saveDatasheet(myproject, transitionGroups, "stsim_TransitionGroup")

  ## Transition Types by groups

  typesByGroup <- vdistLookup %>%
    dplyr::select(Id, Name, TransitionGroupId) %>%
    unique() %>%
    dplyr::select(-Id) %>%
    rename(TransitionTypeId = Name) %>%
    as.data.frame()

  saveDatasheet(myproject, typesByGroup, "stsim_TransitionTypeGroup")

  ## Transition simulation groups
  # The same than groups, used for vizualization

  simulationGroups <- data.frame(
    TransitionGroupId = unique(vdistLookup$TransitionGroupId)
  )

  saveDatasheet(myproject, simulationGroups, "stsim_TransitionSimulationGroup")

  ## +Transitions  ---------------------------------------------------------------

  ## Deterministic

  # Generate locations for unique state classes to be used in the SyncroSim
  # Transition Pathways Diagrams

  locations <-
    stateClasses %>%
    mutate(
      letter = case_when(
        str_detect(StateLabelXId, "10-20") ~ "A",
        str_detect(StateLabelXId, "20-30") ~ "B",
        str_detect(StateLabelXId, "30-40") ~ "C",
        str_detect(StateLabelXId, "40-50") ~ "D",
        str_detect(StateLabelXId, "50-60") ~ "E",
        str_detect(StateLabelXId, "60-70") ~ "F",
        str_detect(StateLabelXId, "70-80") ~ "G",
        str_detect(StateLabelXId, "80-90") ~ "H",
        str_detect(StateLabelXId, "90-100") ~ "I",
        str_detect(StateLabelXId, "< 10") ~ "J", # J is reserved for uncommon cover labels
        str_detect(StateLabelXId, "Sparse") ~ "J", # K is reserved for uncommon cover labels
        TRUE ~ "K"
      ),
      number = case_when(
        str_detect(StateLabelYId, "Fr > ") ~ 1,
        str_detect(StateLabelYId, "Fr 25") ~ 2,
        str_detect(StateLabelYId, "Fr 10") ~ 3,
        str_detect(StateLabelYId, "Fr 5-") ~ 4,
        str_detect(StateLabelYId, "Fr < ") ~ 5,
        str_detect(StateLabelYId, "Sh > ") ~ 6,
        str_detect(StateLabelYId, "Sh 1.0") ~ 7,
        str_detect(StateLabelYId, "Sh 0.5") ~ 8,
        str_detect(StateLabelYId, "Sh < ") ~ 9,
        str_detect(StateLabelYId, "Hb > ") ~ 10,
        str_detect(StateLabelYId, "Hb 0.5") ~ 11,
        str_detect(StateLabelYId, "Hb < ") ~ 12,
        TRUE ~ NA_real_
      ),
      number = suppressWarnings(replace(number, is.na(number), 13:100)),
      # Deal with mixed forms
      mixedLifeForm = case_when(
        str_detect(StateLabelXId, "Tr") &
          !str_detect(StateLabelYId, "Fr") ~ TRUE,
        str_detect(StateLabelXId, "Sh") &
          !str_detect(StateLabelYId, "Sh") ~ TRUE,
        str_detect(StateLabelXId, "Hb") &
          !str_detect(StateLabelYId, "Hb") ~ TRUE,
        TRUE ~ FALSE
      ),
      number = if_else(mixedLifeForm, number + 14, number),
      # Clean up
      Location = str_c(letter, number)
    ) %>%
    dplyr::select(Name, Location)

  # Join the locations back into the state class table and clean up the datasheet
  deterministicTransitions <- stateClasses %>%
    # Make sure to expand the grid to all combinations of MZ present
    expand_grid(StratumIdSource = primary$Name) %>%
    # Join with the location info
    left_join(locations, by = "Name") %>%
    # Cleanup
    dplyr::select(Name, Location, StratumIdSource) %>%
    rename(StateClassIdSource = Name) %>%
    unique() %>%
    as.data.frame()

  saveDatasheet(
    myscenario,
    deterministicTransitions,
    "stsim_DeterministicTransition"
  )

  ## Probabilistic zzz
  probabilisticTransitions <- transitionTable %>%
    # Join the IDS
    left_join(transitionTypes, by = c("VDIST" = "Id")) %>%
    # Rename and select what we need
    rename(TransitionTypeId = Name) %>%
    dplyr::select(
      StratumIdSource,
      SecondaryStratumId,
      StateClassIdSource,
      StateClassIdDest,
      TransitionTypeId,
      Probability
    ) %>%
    as.data.frame()

  # Find the unique set of all state classes listed in the transition table
  transitionStateClasses <- unique(c(
    probabilisticTransitions$StateClassIdSource,
    probabilisticTransitions$StateClassIdDest
  ))

  # Check if any of these state classes are not listed in the set of valid state classses
  invalidStates <- transitionStateClasses[
    !transitionStateClasses %in% stateClasses$Name
  ]

  if (length(invalidStates) > 0) {
    stop(str_c(
      "One or more unexpected combinations of EVC and EVH were found in the transition table. ",
      str_c(invalidStates, collapse = "; ")
    ))
  }

  saveDatasheet(myscenario, probabilisticTransitions, "stsim_Transition")

  ## +Pipeline -----------------------------------------------------------------

  pipeline <- data.frame(
    StageNameId = "ST-Sim",
    RunOrder = 1
  )

  saveDatasheet(myscenario, pipeline, "core_Pipeline")

  ## +Run Control --------------------------------------------------------------

  runControl <- data.frame(
    MinimumIteration = minimumIteration,
    MaximumIteration = maximumIteration,
    MinimumTimestep = minimumTimestep,
    MaximumTimestep = maximumTimestep,
    IsSpatial = TRUE
  )

  saveDatasheet(myscenario, runControl, "stsim_RunControl")

  ## +Output Options -----------------------------------------------------------

  outputOptionsSummary <-
    data.frame(
      SummaryOutputSC = TRUE,
      SummaryOutputSCTimesteps = 1,
      SummaryOutputTR = TRUE,
      SummaryOutputTRTimesteps = 1
    )
  outputOptionsSpatial <-
    data.frame(
      RasterOutputSC = TRUE,
      RasterOutputSCTimesteps = 1,
      RasterOutputST = TRUE,
      RasterOutputSTTimesteps = 1,
      RasterOutputTR = TRUE,
      RasterOutputTRTimesteps = 1
    )

  saveDatasheet(myscenario, outputOptionsSummary, "stsim_OutputOptions")
  saveDatasheet(myscenario, outputOptionsSpatial, "stsim_OutputOptionsSpatial")

  ## +Multiprocessing -----------------------------------------------------------

  multiprocessing <-
    data.frame(
      EnableMultiprocessing = TRUE,
      MaximumJobs = ssimJobs,
      EnableMultiScenario = FALSE
    )

  saveDatasheet(myscenario, multiprocessing, "core_Multiprocessing")

  # Charts and Plots -----------------------------------------------------------

  # Note: Temporarily removed until these can be updated for SyncroSim 2.5

  # # Load CSV describing how to build default charts
  # defaultCharts <-
  #   read_csv(defaultChartsPath) %>%
  #   as.data.frame()
  #
  # defaultMaps <-
  #   read_csv(defaultMapsPath) %>%
  #   as.data.frame()
  #
  # saveDatasheet(myproject, defaultCharts, "corestime_Charts")
  # saveDatasheet(myproject, defaultMaps, "corestime_Maps")
}

buildSsimScenarios <- function(
  runTag,
  scenarioName,
  scenarioDescription,
  libraryName,
  projectName
) {
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

  # Clean Raster Paths
  stateClassRasterPath <- str_c(cleanRasterDirectory, "StateClass.tif")
  primaryStratumRasterPath <- str_c(cleanRasterDirectory, "EVT.tif")
  secondaryStratumRasterPath <- str_c(cleanRasterDirectory, "MapZone.tif")

  tilingRasterPath <- str_c(cleanRasterDirectory, "Tiling.tif")

  # Don't build a scenario if the raster is empty (single NA cell)
  stateClassRaster <- rast(stateClassRasterPath)
  if (ncell(stateClassRaster) == 1 && is.na(stateClassRaster)[][1]) {
    return()
  }

  # Build Scenario ------------------------------------------------------------
  ssimSession <- session(ssimDir)
  mylibrary <- ssimLibrary(libraryName, session = ssimSession)
  myproject <- rsyncrosim::project(mylibrary, projectName)
  myscenario <- scenario(myproject, scenarioName, overwrite = TRUE)
  description(myscenario) <- scenarioDescription

  ## +Common Dependency --------------------------------------------------------

  # Add the Sub Scenario as a dependency to import common model info
  dependency(myscenario) <- subScenarioName

  ## +Transition spatial multipliers -------------------------------------------

  # Collect the names and create path files
  multiplierGroupNames <-
    transitionMultiplierDirectory %>%
    list.files("tif$") %>%
    str_sub(end = -5) %>%
    str_c(" [Type]")

  multiplierFileNames <-
    transitionMultiplierDirectory %>%
    list.files("tif$", full.names = TRUE)

  # Compose and save the data frame
  if (length(multiplierFileNames) > 0) {
    spatialMultiplier <- data.frame(
      TransitionGroupId = multiplierGroupNames,
      MultiplierFileName = multiplierFileNames
    )

    saveDatasheet(
      myscenario,
      spatialMultiplier,
      "stsim_TransitionSpatialMultiplier"
    )
  } else {
    warning(paste0(
      "There were no disturbances found in ",
      runTag,
      ". This is not necessarily an error, please check the raw data."
    ))
  }

  ## +Transition Multipliers ---------------------------------------------------

  # Get a list of all disturbance types absent in the Map Zone
  absentDisturbanceTypes <-
    read_csv(vdistTablePath) %>%
    # Select only what we need, then rename
    rename(Id = value, TransitionGroupId = d_type) %>%
    # Filter out the NO Disturbance category
    filter(Id != 0) %>%
    # Create unique transition/disturbance name, and format color
    # The format of the name is : Group, Severity, Frequency
    transmute(
      Name = paste(TransitionGroupId, d_severity, d_time, sep = " - ")
    ) %>%
    pull %>%
    str_c(" [Type]") %>%
    setdiff(multiplierGroupNames)

  absentTransitionMultipliers <- data.frame(
    TransitionGroupId = absentDisturbanceTypes,
    Amount = 0
  )

  saveDatasheet(
    myscenario,
    absentTransitionMultipliers,
    "stsim_TransitionMultiplierValue"
  )

  ## +Initial conditions --------------------------------------------------------

  initialConditionsSpatial <- data.frame(
    StateClassFileName = stateClassRasterPath,
    StratumFileName = primaryStratumRasterPath,
    SecondaryStratumFileName = secondaryStratumRasterPath
  )

  saveDatasheet(
    myscenario,
    initialConditionsSpatial,
    "stsim_InitialConditionsSpatial"
  )

  ## +Spatial multiprocessing ---------------------------------------------------
  spatialMultiprocessing <- data.frame(MaskFileName = tilingRasterPath)

  saveDatasheet(
    myscenario,
    spatialMultiprocessing,
    "core_SpatialMultiprocessing"
  )
}
