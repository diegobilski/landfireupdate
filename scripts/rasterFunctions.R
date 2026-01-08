### LANDFIRE Project
### APEX RMS - Shreeram Senthivasan
### November 2020
### This a header file that defines memory-safe raster functions that are optimized
### for large data files that cannot easily be held in memory.

# A memory-safe function to convert a raster with multiple values (map zones)
# into a mask for a single value (map zone)
# - Requires an output filename, slower than raster::mask for small rasters
maskByMapzone <- function(inputRaster, maskValue, filename) {
  # Integer mask values save memory
  maskValue <- as.integer(maskValue)

  # Generate empty raster with appropriate dimensions
  outputRaster <- rast(inputRaster)

  rcl <- matrix(
    c(
      -999,
      maskValue - 0.5,
      maskValue, # Left bound (open)
      maskValue - 0.5,
      maskValue,
      999, # Right bound (closed)
      NA_integer_,
      maskValue,
      NA_integer_
    ), # Final value
    ncol = 3
  )

  outputRaster <- classify(
    inputRaster,
    rcl = rcl,
    right = TRUE,
    overwrite = TRUE,
    filename = filename
  )

  # # Calculate mask and write to output block-by-block
  # blockInfo <- writeStart(outputRaster, filename, overwrite=TRUE)
  #
  # for(i in seq(blockInfo$n)) {
  #   blockMask <-
  #     values(inputRaster, row = blockInfo$row[i], nrows = blockInfo$nrows[i]) %>%
  #     `==`(maskValue) %>%
  #     if_else(true = maskValue, false = NA_integer_)
  #   writeValues(outputRaster, v = blockMask, start = blockInfo$row[i], nrows = blockInfo$nrows[i])
  # }
  #
  # writeStop(outputRaster)

  return(outputRaster)
}

# A memory-safe implementation of `raster::unique()` optimized for large rasters
# - ignore are the levels to exclude from the output
uniqueInRaster <- function(inputRaster, ignore = NA) {
  # Choose number of blocks to split rasters into when processing to limit memory
  blockInfo <- blocks(inputRaster)

  # Calculate unique values in each block
  map(
    seq(blockInfo$n),
    ~ unique(values(
      inputRaster,
      row = blockInfo$row[.x],
      nrows = blockInfo$nrows[.x]
    )) %>%
      as.numeric
  ) %>%
    # Consolidate values from each block
    flatten_dbl %>%
    unique() %>%
    # Exclude values to ignore
    `[`(!. %in% ignore) %>%
    return
}

# A memory-safe implementation of raster::crop() optimized for large rasters
# - Requires an extent object, unlike raster::crop()
# - Requires an output filename, slower than raster::crop for small rasters
cropRaster <- function(inputRaster, filename, outputExtent) {
  # Create empty raster to hold output
  outputRaster <- rast(inputRaster) %>%
    crop(outputExtent)

  # Calculate offset from original
  offsetAbove <- round(
    (ymax(extent(inputRaster)) - ymax(outputExtent)) / res(inputRaster)[2]
  )
  offsetLeft <- round(
    (xmin(outputExtent) - xmin(extent(inputRaster))) / res(inputRaster)[1]
  )

  if (offsetAbove < 0 | offsetLeft < 0) {
    stop(
      "Attempting to crop a smaller raster to a larger extent. This should not happen and could cause unexpected behaviour."
    )
  }

  ## Split output into manageable chunks and fill with data from input
  blockInfo <- writeStart(outputRaster, filename, overwrite = TRUE)

  for (i in seq(blockInfo$n)) {
    writeValues(
      outputRaster,
      getValuesBlock(
        inputRaster,
        row = blockInfo$row[i] + offsetAbove,
        nrows = blockInfo$nrows[i],
        col = offsetLeft + 1,
        ncols = ncol(outputRaster)
      ),
      blockInfo$row[i]
    )
  }

  writeStop(outputRaster)

  return(outputRaster)
}

# Function to convert a vector, etc. of number into a multiplicative mask
# - Replaces all values with 1, NA remains as NA
# - Assumes no negative numbers (specifically, no -1)
maskify <- function(x) {
  x <- x + 1L # Used to avoid divide by zero errors, this is why -1 is not acceptable
  return(x / x)
}

# A memory safe implementation of raster::mask() optimized for large rasters
# - Requires an output filename, slower than raster::mask for small rasters
# - Input and mask rasters must have same extent (try cropRaster() if not)
maskRaster <- function(inputRaster, filename, maskingRaster) {
  # Create an empty raster to hold the output
  outputRaster <- raster(inputRaster)

  ## Split output into manageable chunks and fill with data from input
  ## Calculate mask and write to output block-by-block
  blockInfo <- writeStart(outputRaster, filename, overwrite = TRUE)

  # Each block of the mask raster is converted into a multiplicative mask
  # and multiplied with the corresponding block of the input raster
  for (i in seq(blockInfo$n)) {
    maskedBlock <-
      values(
        maskingRaster,
        row = blockInfo$row[i],
        nrows = blockInfo$nrows[i]
      ) %>%
      maskify %>%
      `*`(values(
        inputRaster,
        row = blockInfo$row[i],
        nrows = blockInfo$nrows[i]
      ))
    writeValues(
      outputRaster,
      maskedBlock,
      blockInfo$row[i],
      nrows = blockInfo$nrows[i]
    )
  }

  writeStop(outputRaster)

  return(outputRaster)
}

# A function to crop rasters down to remove borders filled with only NA's
# - Uses binary search to quickly process large rasters with large empty borders
# - Requires an output filename, slower than raster::trim for small rasters
# - maxBlockSizePower is an integer that will be used to calculate the max number
#   of rows / cols to load into memory. Specifically 2^maxBlockSizePower rows and
#   cols will be loaded at most at a time
trimRaster <- function(inputRaster, filename, maxBlockSizePower = 11) {
  # Reading portions of large rasters that can't be held in memory is slow, so
  # we want to minimize the number of reads as we identify how much we can trim
  # off each of the four sides of the raster

  # One simplistic approach is to check large blocks at a time until a block
  # with non-NA data is found. Next halve the size of the search block and
  # continue searching. Keep halving the the width of the search block until you
  # find the single first column with data. This is effectively a binary search
  # once the first (largest) block with non-NA data is found.

  # Note: Temporarily replace by:
  # outputRaster <- trim(inputRaster, filename = filename, overwrite = T)

  # Setup --------------------------------------------------------------------
  # Decide how to split input into manageable blocks
  maxBlockSize <- 2^(maxBlockSizePower)
  # Make sure max block size is smaller than the number of columns and rows
  while (ncol(inputRaster) < maxBlockSize | nrow(inputRaster) < maxBlockSize) {
    maxBlockSize = maxBlockSize / 2
    maxBlockSizePower = maxBlockSizePower - 1
  }
  descendingBlockSizes <- 2^((maxBlockSizePower - 1):0)

  # Initialize counters
  trimAbove <- 1
  trimBelow <- nrow(inputRaster) + 1
  trimLeft <- 1
  trimRight <- ncol(inputRaster) + 1

  # Top ----------------------------------------------------------------------
  # Search for the first block from the top with data
  while (
    values(inputRaster, row = trimAbove, nrows = maxBlockSize) %>%
      is.na %>%
      all
  ) {
    trimAbove <- trimAbove + maxBlockSize
  }

  # Now do a binary search for the first row with data
  for (i in descendingBlockSizes) {
    if (values(inputRaster, row = trimAbove, nrows = i) %>% is.na %>% all) {
      trimAbove <- trimAbove + i
    }
  }

  # Pad if possible
  trimAbove <- max(trimAbove - 2, 1)

  # Bottom  -------------------------------------------------------------------
  # Repeat from the bottom up, first finding a block that is not all NA
  while (
    values(
      inputRaster,
      row = trimBelow - maxBlockSize,
      nrows = maxBlockSize
    ) %>%
      is.na %>%
      all
  ) {
    trimBelow <- trimBelow - maxBlockSize
  }

  # Binary search for last row with data
  for (i in descendingBlockSizes) {
    if (values(inputRaster, row = trimBelow - i, nrows = i) %>% is.na %>% all) {
      trimBelow <- trimBelow - i
    }
  }

  # Calculate height of the trimmed raster
  outputRows <- trimBelow - trimAbove

  # Left  --------------------------------------------------------------------
  # Search for the first block from the left with data
  while (
    values(
      inputRaster,
      col = trimLeft,
      ncols = maxBlockSize,
      row = trimAbove,
      nrows = outputRows
    ) %>%
      is.na %>%
      all
  ) {
    trimLeft <- trimLeft + maxBlockSize
  }

  # Now do a binary search for the first row with data
  for (i in descendingBlockSizes) {
    if (
      values(
        inputRaster,
        col = trimLeft,
        ncols = i,
        row = trimAbove,
        nrows = outputRows
      ) %>%
        is.na %>%
        all
    ) {
      trimLeft <- trimLeft + i
    }
  }

  # Pad if possible
  trimLeft <- max(trimLeft - 2, 1)

  # Right  --------------------------------------------------------------------
  # Repeat for the first block from the right with data
  while (
    values(
      inputRaster,
      col = trimRight - maxBlockSize,
      ncols = maxBlockSize,
      row = trimAbove,
      nrows = outputRows
    ) %>%
      is.na %>%
      all
  ) {
    trimRight <- trimRight - maxBlockSize
  }

  # Now do a binary search for the first row with data
  for (i in descendingBlockSizes) {
    if (
      values(
        inputRaster,
        col = trimRight - i,
        ncols = i,
        row = trimAbove,
        nrows = outputRows
      ) %>%
        is.na %>%
        all
    ) {
      trimRight <- trimRight - i
    }
  }

  # Calculate width of the trimmed raster
  outputCols <- trimRight - trimLeft

  # Crop  ---------------------------------------------------------------------

  # Don't crop if there is nothing to crop
  if (
    trimAbove == 1 &
      trimLeft == 1 &
      trimBelow == nrow(inputRaster) + 1 &
      trimRight == ncol(inputRaster) + 1
  ) {
    writeRaster(inputRaster, filename = filename, overwrite = T)
    return(inputRaster)
  }

  # Convert trim variables to x,y min,max
  outXmin <- xmin(extent(inputRaster)) + trimLeft * res(inputRaster)[1]
  outXmax <- outXmin + outputCols * res(inputRaster)[1]
  outYmax <- ymax(extent(inputRaster)) - trimAbove * res(inputRaster)[2]
  outYmin <- outYmax - outputRows * res(inputRaster)[2]

  return(
    cropRaster(
      inputRaster,
      filename,
      extent(c(xmin = outXmin, xmax = outXmax, ymin = outYmin, ymax = outYmax))
    )
  )
}

# Function to create and save a binary raster given a non-binary raster and the
# value to keep
# - Used to binarize disturbance maps for use as spatial multipliers in SyncroSim
saveDistLayer <- function(
  distValue,
  distName,
  fullRaster,
  transitionMultiplierDirectory
) {
  # Construct output name
  outputRasterName <- paste0(transitionMultiplierDirectory, distName, ".tif")

  # Construct reclassification matrix to binarize layer
  rcl <- matrix(
    c(
      -Inf,
      distValue - 0.5,
      distValue, # Left bound (open)
      distValue - 0.5,
      distValue,
      Inf, # Right bound (closed)
      0,
      1,
      0
    ), # Final value
    ncol = 3
  )

  # Binarize and save
  classify(fullRaster, rcl = rcl, filename = outputRasterName, overwrite = TRUE)

  # writeRaster(
  #   layerize(fullRaster, classes = distValue),
  #   paste0(transitionMultiplierDirectory, distName, ".tif"),
  #   overwrite = TRUE
  # )
}

# Function to generate a tiling mask given template
# - To avoid holding the entire raster in memory, the raster is written directly
#   to file row-by-row. This way only one row of the tiling needs to be held in
#   memory at a time. This is also why the number of rows (and implicitly the size
#   of a given row) cannot be chosen manually
# - minProportion is used to determine the size threshold for consolidating tiles
#   that are too small into neighboring tiles. Represented as a proportion of a
#   full tile
tilize <- function(templateRaster, filename, tempfilename, tileSize) {
  # Catch case where the Map Zone has no disturbances
  # - && is used to allow early stopping (which is not supported by the vectorized &)
  if (ncell(templateRaster) == 1 && is.na(templateRaster)[][1]) {
    tileRaster <- rast(templateRaster)
    set.values(tileRaster, 1, 1)
    writeRaster(tileRaster, filename = filename, overwrite = T)
    return(tileRaster)
  }

  # Calculate recommended block size of template
  blockInfo <- blocks(templateRaster)

  # Check that the blockSize is meaningful
  # - This should only matter for very small rasters, such as in test mode
  if (max(blockInfo$nrows) == 1) {
    blockInfo <- list(row = 1, nrows = nrow(templateRaster), n = 1)
  }

  # Calculate dimensions of each tile
  tileHeight <- blockInfo$nrows[1]
  tileWidth <- floor(tileSize / tileHeight)

  # Calculate number of rows and columns
  ny <- blockInfo$n
  nx <- ceiling(ncol(templateRaster) / tileWidth)

  # Generate a string of zeros the width of one tile
  oneTileWidth <- rep(0, tileWidth)

  # Generate one line of one row, repeat to the height of one row
  oneRow <-
    as.vector(vapply(
      seq(nx),
      function(i) oneTileWidth + i,
      FUN.VALUE = numeric(tileWidth)
    )) %>%
    `[`(1:ncol(templateRaster)) %>% # Trim the length of one row to fit in template
    rep(tileHeight)

  # Write an empty raster with the correct metadata to file
  tileRaster <- rast(templateRaster)

  # Write tiling to file row-by-row
  writeStart(tileRaster, filename, overwrite = TRUE)
  for (i in seq(blockInfo$n)) {
    if (blockInfo$nrows[i] < tileHeight) {
      oneRow <- oneRow[1:(ncol(tileRaster) * blockInfo$nrows[i])]
    }

    writeValues(tileRaster, oneRow, blockInfo$row[i], blockInfo$nrows[i])
    oneRow <- oneRow + nx
  }
  tileRaster <- writeStop(tileRaster)

  # Mask raster by template
  tileRaster <-
    mask(
      tileRaster,
      mask = templateRaster,
      filename = tempfilename,
      overwrite = TRUE
    )

  # Consolidate small tiles into larger groups
  # - We want a map from the original tile IDs to new consolidated tile IDs
  reclassification <-
    # Find the number of cells in each tile ID
    tabulateRaster(tileRaster) %>%
    # Sort by ID to approximately group tiles by proximity
    arrange(value) %>%
    # Consolidate into groups up to size tileSize
    transmute(
      from = value,
      to = consolidateGroups(freq, tileSize)
    ) %>%
    as.matrix()

  # Reclassify the tiling raster to the new consolidated IDs
  tileRaster <-
    classify(
      tileRaster,
      reclassification,
      filename = filename,
      overwrite = T
    )

  return(tileRaster)
}

# Generate a table of values present in a raster and their frequency
# - values are assumed to be integers and the max value is known
tabulateRaster <- function(inputRaster) {
  # Calculate recommended block size of template
  blockInfo <- blocks(inputRaster)

  # Calculate frequency table in each block and consolidate
  tables <- map(
    seq(blockInfo$n),
    ~ table(values(
      inputRaster,
      row = blockInfo$row[.x],
      nrows = blockInfo$nrows[.x]
    ))
  ) %>%
    map(as.data.frame) %>%
    do.call(rbind, .) %>% # do.call is used to convert the list of tables to a sequence of arguments for `rbind`
    rename(value = 1) %>%
    group_by(value) %>%
    summarize(freq = sum(Freq)) %>%
    ungroup() %>%
    mutate(value = value %>% as.character %>% as.numeric) %>% # Convert from factor to numeric
    return
}

# Takes a vector of sizes (input) and a maximum size per group (threshold) and
# returns a vector of integers assigning the inputs to groups up to size threshold
# - Used to consolidate tiling groups into more even groups
consolidateGroups <- function(input, threshold) {
  # Initialized counters and output
  counter <- 1
  cumulator <- 0
  output <- integer(length(input))

  # For each input, decide whether or not to start a new group
  # Store that decision in output
  for (i in seq_along(input)) {
    cumulator <- cumulator + input[i]
    if (cumulator > threshold) {
      cumulator <- input[i]
      counter <- counter + 1
    }
    output[i] <- counter
  }

  return(output)
}

separateStateClass <- function(stateClassRaster, evcRasterPath, evhRasterPath) {
  # Create empty rasters to hold EVC and EVH data
  evcRaster <- rast(stateClassRaster)
  evhRaster <- rast(stateClassRaster)

  ## Split state class raster into manageable chunks
  blockInfo <- blocks(stateClassRaster)

  ## Calculate EVC and EVH from State Class block-by-block and write the results to their respective files
  writeStart(evcRaster, evcRasterPath, overwrite = TRUE)
  writeStart(evhRaster, evhRasterPath, overwrite = TRUE)

  for (i in seq(blockInfo$n)) {
    stateClassValues <-
      values(
        stateClassRaster,
        row = blockInfo$row[i],
        nrows = blockInfo$nrows[i]
      )

    evcValues <- as.integer(stateClassValues / 1000) # EVC is the first three digits of the six digit state class code
    evhValues <- stateClassValues %% 1000 # EVH is the last three digits, `%%` is the modulo, or remainder function

    writeValues(
      evcRaster,
      evcValues,
      blockInfo$row[i],
      nrows = blockInfo$nrows[i]
    )
    writeValues(
      evhRaster,
      evhValues,
      blockInfo$row[i],
      nrows = blockInfo$nrows[i]
    )
  }

  # End writing to rasters
  evcRaster <- writeStop(evcRaster)
  evhRaster <- writeStop(evhRaster)

  # Silent return
  invisible()
}
