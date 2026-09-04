# =============================================================================
# NCES ACS-ED Tables Data Ingestion
# Source: https://nces.ed.gov/programs/edge/Demographic/acsedtables
#
# The ACS-ED Tables page is a single-page app whose API requires a bearer token
# and is WAF-blocked to scripted clients. The legacy EDGE TableViewer JSON API
# that sits behind it is open and serves the same tabulations, so this ingest
# uses that:
#
#   POST /programs/edge/TableViewer/tableListGetAll  -> tables available in a vintage
#   POST /programs/edge/TableViewer/TableGet         -> a table's cell labels
#   POST /programs/edge/TableViewer/TableExportToCSV -> pipe-delimited export,
#                                                       written to /tempfiles/sdds/
#
# One export call per (table, vintage) returns every geography at once:
# national, 52 states/DC/PR, and ~13,400 school districts.
#
# Outputs
#   standard/data_state.csv.gz  national + state, geography = FIPS
#   standard/data_lea.csv.gz    school district, geography = 7-digit NCES LEAID
# =============================================================================

library(dplyr)

process <- dcf::dcf_process_record()

EDGE <- "https://nces.ed.gov/programs/edge"
DATASET <- "acs"

# The API identifies a vintage by the final year of its five-year period, so
# 2009 is the 2005-2009 file and 2023 is the 2019-2023 one. All 15 published
# vintages.
YEARS <- 2009:2023

# The 2005-09 through 2007-11 vintages are stored with an ACS-ED population
# group ("enrollment type") dimension, and their stored procedures fail unless
# one is supplied. These are the codes for the whole population, which is what
# the 2008-12 vintage onwards returns unconditionally. Codes are vintage-
# specific: the 2005-09 file numbers the same group 301 rather than 001.
POP_GROUP <- c("2009" = "301", "2010" = "001", "2011" = "001")

# The export's attribute-set slot: the bare code, or empty for later vintages.
pop_group <- function(year) {
  code <- POP_GROUP[as.character(year)]
  if (is.na(code)) "" else unname(code)
}

# The TableGet parameter. It must be JSON null, not an empty string, for the
# 2008-2012 vintage onwards - an empty string makes the query return no rows.
pop_group_arg <- function(year) {
  code <- pop_group(year)
  if (code == "") "null" else paste0('"', code, '"')
}

# -----------------------------------------------------------------------------
# 1. API helpers
# -----------------------------------------------------------------------------

# The endpoints take JSON-ish bodies with unquoted keys, exactly as the site's
# own scripts send them.
nces_post <- function(endpoint, body, timeout = 900) {
  for (attempt in 1:4) {
    res <- try(
      httr::POST(
        paste0(EDGE, "/", endpoint),
        httr::add_headers(
          `Content-Type` = "application/json; charset=utf-8",
          `X-Requested-With` = "XMLHttpRequest",
          Referer = paste0(EDGE, "/TableViewer/", DATASET, "/", max(YEARS))
        ),
        body = body,
        httr::timeout(timeout)
      ),
      silent = TRUE
    )
    if (!inherits(res, "try-error") && httr::status_code(res) == 200) {
      txt <- httr::content(res, "text", encoding = "UTF-8")
      # An application error comes back as the site's HTML error page.
      if (!startsWith(trimws(txt), "<")) {
        return(jsonlite::fromJSON(txt, simplifyVector = FALSE))
      }
    }
    Sys.sleep(5 * attempt)
  }
  NULL
}

# Tables present in a given vintage.
nces_table_list <- function(year) {
  res <- nces_post(
    "TableViewer/tableListGetAll",
    sprintf('{iYear : %d, sDataset : "%s"}', year, DATASET)
  )
  if (is.null(res)) character() else vapply(res, function(x) x$tableId, "")
}

# Labels are matched after normalisation, because wording drifts across
# vintages (e.g. "Enrolled in college, undergraduate years" vs
# "... college undergraduate years"). Periods are kept: B17024's income-to-
# poverty bands are labelled ".50 to .74".
norm_label <- function(x) {
  x <- tolower(x)
  # EDGE label text uses straight quotes and apostrophes only.
  x <- gsub('"', "", x, fixed = TRUE)
  x <- gsub("[',:;]", "", x)
  x <- gsub("[()]", " ", x)
  x <- gsub("\\s*>\\s*", " > ", x)
  x <- gsub("[ \t]+", " ", x)
  trimws(x)
}

# Cell labels for a table, read off the national preview. The Nth label
# corresponds to the {table}_{N}est / {table}_{N}moe columns in the export.
nces_labels <- function(table_id, year) {
  res <- nces_post(
    "TableViewer/TableGet",
    sprintf(
      '{iYear : %d, sDataset : "%s", sTableId : "%s", sUniverse : null, sGradeAge : null, sEnrollmentType : %s, sGeoType : "US", sGeoId : "US"}',
      year, DATASET, table_id, pop_group_arg(year)
    )
  )
  if (is.null(res) || is.null(res$html)) return(NULL)

  m <- gregexpr('<td class="label, indent([0-9]+)">(.*?)</td>', res$html, perl = TRUE)
  hits <- regmatches(res$html, m)[[1]]
  if (!length(hits)) return(NULL)

  indent <- as.integer(sub('^<td class="label, indent([0-9]+)">.*$', "\\1", hits))
  label <- sub('^<td class="label, indent[0-9]+">(.*)</td>$', "\\1", hits)

  # Build each cell's full label path by walking the indent stack, so a cell can
  # be identified by its own label plus its ancestors rather than by position
  # (positions shift between vintages when Census revises a table).
  stack <- character()
  path <- character(length(label))
  for (i in seq_along(label)) {
    d <- indent[i] + 1L
    if (length(stack) >= d) stack <- stack[seq_len(d - 1L)]
    stack[d] <- label[i]
    path[i] <- paste(stack[seq_len(d)], collapse = " > ")
  }

  tibble(
    cell = seq_along(label),
    indent = indent,
    label = label,
    path = path,
    leaf_norm = norm_label(label),
    path_norm = norm_label(path)
  )
}

# Export a whole table for every geography, and return its local path.
nces_export <- function(table_id, year, dest_dir) {
  # An attribute set is tableId-universe-gradeAge-enrollmentType-geoType-geoId;
  # only the enrollment-type slot is ever populated here, and geoType "All"
  # returns national, state and every school district in one file.
  res <- nces_post(
    "TableViewer/TableExportToCSV",
    sprintf(
      '{iYear : %d, sDataset : "%s", sTableAttrSets : "%s---%s-All-All`"}',
      year, DATASET, table_id, pop_group(year)
    )
  )
  if (is.null(res) || is.null(res$filename) || is.null(res$path)) return(NULL)

  url <- paste0("https://nces.ed.gov", gsub("\\\\", "/", res$path), res$filename)
  dest <- file.path(dest_dir, paste0(table_id, "_", year, ".txt"))
  ok <- try(
    curl::curl_download(url, dest, quiet = TRUE, handle = curl::new_handle(timeout = 1800)),
    silent = TRUE
  )
  if (inherits(ok, "try-error") || !file.exists(dest)) return(NULL)
  dest
}

# -----------------------------------------------------------------------------
# 2. Indicator definitions
#
# Each indicator names the cells that make up its numerator (and, for a
# percent, its denominator). A cell is selected by regexes on its normalised
# leaf label and full label path; `n` is the number of cells the selector is
# expected to match, and is checked on every vintage so a table revision
# surfaces as a warning and an NA rather than a silently wrong number.
# -----------------------------------------------------------------------------

sel <- function(leaf = NULL, path = NULL, not_path = NULL, n = NULL) {
  list(leaf = leaf, path = path, not_path = not_path, n = n)
}

# Exact-match helper: anchors each alternative so "5 years" does not also
# match "15 years" or "75 years and over".
one_of <- function(...) paste0("^(", paste(c(...), collapse = "|"), ")$")

# A path selector that must match one of several age segments.
one_of_path <- function(x) paste0("> (", paste(x, collapse = "|"), ") >")

AGES_UNDER18_B17001 <- c(
  "under 5 years", "5 years", "6 to 11 years", "12 to 14 years",
  "15 years", "16 and 17 years"
)
AGES_5_17_B14003 <- c("5 to 9 years", "10 to 14 years", "15 to 17 years")
AGES_UNDER18_B17024 <- c("under 6 years", "6 to 11 years", "12 to 17 years")
FPL_UNDER_185 <- c(
  "under .50", ".50 to .74", ".75 to .99", "1.00 to 1.24",
  "1.25 to 1.49", "1.50 to 1.74", "1.75 to 1.84"
)
# B15002 relabelled its diploma category from "High school graduate, GED, or
# alternative" to "High school graduate (includes equivalency)" in the 2009-13
# vintage. Only one of the two ever matches, so the count stays at 16.
ATTAIN_HS_PLUS <- c(
  "high school graduate includes equivalency",
  "high school graduate ged or alternative",
  "some college less than 1 year",
  "some college 1 or more years no degree",
  "associates degree", "bachelors degree", "masters degree",
  "professional school degree", "doctorate degree"
)
ATTAIN_NO_HS <- c(
  "no schooling completed", "nursery to 4th grade", "5th and 6th grade",
  "7th and 8th grade", "9th grade", "10th grade", "11th grade",
  "12th grade no diploma"
)
ATTAIN_BA_PLUS <- c(
  "bachelors degree", "masters degree", "professional school degree",
  "doctorate degree"
)

# B14005's diploma category is "High school graduate:" up to the 2008-12
# vintage and "High school graduate (includes equivalency):" from 2009-13 on.
HS_GRAD_LEAF <- "^high school graduate( includes equivalency)?$"
HS_STATUS_LEAF <- "^(high school graduate( includes equivalency)?|not high school graduate)$"

# B11003 relabelled twice: "With own children under 18 years" gained "of the
# householder" in the 2011-15 vintage, and the lone-parent rows moved from
# "no wife present" / "no husband present" to "no spouse present" in 2015-19.
OWN_CHILDREN_LEAF <- "^with own children( of the householder)? under 18 years$"
LONE_PARENT_PATH <- "householder no (wife|husband|spouse) present"

# B27001's second age band is "6 to 17 years" up to the 2012-16 vintage and
# "6 to 18 years" from 2013-17 on, so the child insurance measure covers
# under-18 in the earlier vintages and under-19 in the later ones.
INSURANCE_CHILD_AGES <- c("under 6 years", "6 to 17 years", "6 to 18 years")

IND <- list(

  # ---- Population -----------------------------------------------------------
  nces_pop_total = list(
    table = "B01003", type = "count",
    num = sel(leaf = "^total$", n = 1)
  ),
  nces_pop_under18 = list(
    table = "B09001", type = "count",
    num = sel(leaf = "^total$", n = 1)
  ),
  nces_pop_age_0_4 = list(
    table = "B09001", type = "count",
    num = sel(leaf = one_of("under 3 years", "3 and 4 years"), n = 2)
  ),
  nces_pop_age_5_11 = list(
    table = "B09001", type = "count",
    num = sel(leaf = one_of("5 years", "6 to 8 years", "9 to 11 years"), n = 3)
  ),
  nces_pop_age_12_17 = list(
    table = "B09001", type = "count",
    num = sel(leaf = one_of("12 to 14 years", "15 to 17 years"), n = 2)
  ),

  # ---- School enrollment ----------------------------------------------------
  nces_enrolled_preschool = list(
    table = "B14001", type = "count",
    num = sel(leaf = "^enrolled in nursery school,? ?preschool$", n = 1)
  ),
  nces_enrolled_kindergarten = list(
    table = "B14001", type = "count",
    num = sel(leaf = "^enrolled in kindergarten$", n = 1)
  ),
  nces_enrolled_grade_1_4 = list(
    table = "B14001", type = "count",
    num = sel(leaf = "^enrolled in grade 1 to grade 4$", n = 1)
  ),
  nces_enrolled_grade_5_8 = list(
    table = "B14001", type = "count",
    num = sel(leaf = "^enrolled in grade 5 to grade 8$", n = 1)
  ),
  nces_enrolled_grade_9_12 = list(
    table = "B14001", type = "count",
    num = sel(leaf = "^enrolled in grade 9 to grade 12$", n = 1)
  ),
  nces_enrolled_k12 = list(
    table = "B14001", type = "count",
    num = sel(
      leaf = one_of(
        "enrolled in kindergarten", "enrolled in grade 1 to grade 4",
        "enrolled in grade 5 to grade 8", "enrolled in grade 9 to grade 12"
      ),
      n = 4
    )
  ),
  nces_enrolled_college = list(
    table = "B14001", type = "count",
    num = sel(
      leaf = "^(enrolled in college,? ?undergraduate years|graduate or professional school)$",
      n = 2
    )
  ),

  # ---- Public vs private, ages 5-17 (both sexes summed) ---------------------
  nces_enrolled_public_5_17 = list(
    table = "B14003", type = "count",
    num = sel(leaf = one_of(AGES_5_17_B14003), path = "enrolled in public school", n = 6)
  ),
  nces_enrolled_private_5_17 = list(
    table = "B14003", type = "count",
    num = sel(leaf = one_of(AGES_5_17_B14003), path = "enrolled in private school", n = 6)
  ),
  nces_pct_enrolled_private_5_17 = list(
    table = "B14003", type = "percent",
    num = sel(leaf = one_of(AGES_5_17_B14003), path = "enrolled in private school", n = 6),
    den = sel(leaf = one_of(AGES_5_17_B14003), path = "enrolled in (public|private) school", n = 12)
  ),
  nces_pct_not_enrolled_5_17 = list(
    table = "B14003", type = "percent",
    num = sel(leaf = one_of(AGES_5_17_B14003), path = "not enrolled in school", n = 6),
    den = sel(leaf = one_of(AGES_5_17_B14003), n = 18)
  ),

  # ---- High school completion, ages 16-19 -----------------------------------
  # ACS has no cohort graduation rate; B14005 gives the survey-based
  # equivalents, keyed on whether a 16-19 year old who has left school holds a
  # diploma or equivalency.
  nces_pop_age_16_19 = list(
    table = "B14005", type = "count",
    num = sel(leaf = "^total$", n = 1)
  ),
  nces_not_enrolled_hs_grad_16_19 = list(
    table = "B14005", type = "count",
    num = sel(leaf = HS_GRAD_LEAF, n = 2)
  ),
  nces_not_enrolled_no_hs_16_19 = list(
    table = "B14005", type = "count",
    num = sel(leaf = "^not high school graduate$", n = 2)
  ),
  nces_pct_hs_grad_16_19 = list(
    table = "B14005", type = "percent",
    num = sel(leaf = HS_GRAD_LEAF, n = 2),
    den = sel(leaf = HS_STATUS_LEAF, n = 4)
  ),
  nces_pct_dropout_16_19 = list(
    table = "B14005", type = "percent",
    num = sel(leaf = "^not high school graduate$", n = 2),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_enrolled_16_19 = list(
    table = "B14005", type = "percent",
    num = sel(leaf = "^enrolled in school$", n = 2),
    den = sel(leaf = "^total$", n = 1)
  ),

  # ---- Adult educational attainment, 25+ ------------------------------------
  nces_pct_hs_or_higher_25plus = list(
    table = "B15002", type = "percent",
    num = sel(leaf = one_of(ATTAIN_HS_PLUS), n = 16),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_no_hs_25plus = list(
    table = "B15002", type = "percent",
    num = sel(leaf = one_of(ATTAIN_NO_HS), n = 16),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_ba_or_higher_25plus = list(
    table = "B15002", type = "percent",
    num = sel(leaf = one_of(ATTAIN_BA_PLUS), n = 8),
    den = sel(leaf = "^total$", n = 1)
  ),

  # ---- Language, ages 5-17 --------------------------------------------------
  nces_pct_non_english_home_5_17 = list(
    table = "B16004", type = "percent",
    num = sel(
      leaf = "^speak (spanish|other indo-european languages|asian and pacific island languages|other languages)$",
      path = "^total > 5 to 17 years", n = 4
    ),
    den = sel(leaf = "^5 to 17 years$", n = 1)
  ),
  nces_pct_limited_english_5_17 = list(
    table = "B16004", type = "percent",
    num = sel(
      leaf = "^speak english (well|not well|not at all)$",
      path = "^total > 5 to 17 years", n = 12
    ),
    den = sel(leaf = "^5 to 17 years$", n = 1)
  ),

  # ---- Poverty --------------------------------------------------------------
  nces_poverty_under18 = list(
    table = "B17001", type = "count",
    num = sel(
      leaf = one_of(AGES_UNDER18_B17001),
      path = "below poverty level", n = 12
    )
  ),
  nces_pct_poverty_under18 = list(
    table = "B17001", type = "percent",
    num = sel(leaf = one_of(AGES_UNDER18_B17001), path = "below poverty level", n = 12),
    den = sel(leaf = one_of(AGES_UNDER18_B17001), n = 24)
  ),
  nces_pct_poverty_all_ages = list(
    table = "B17001", type = "percent",
    num = sel(leaf = "^income in the past 12 months below poverty level$", n = 1),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_deep_poverty_under18 = list(
    table = "B17024", type = "percent",
    num = sel(leaf = "^under .50$", path = one_of_path(AGES_UNDER18_B17024), n = 3),
    den = sel(leaf = one_of(AGES_UNDER18_B17024), n = 3)
  ),
  nces_pct_under185_fpl_under18 = list(
    table = "B17024", type = "percent",
    num = sel(
      leaf = one_of(FPL_UNDER_185),
      path = one_of_path(AGES_UNDER18_B17024), n = 21
    ),
    den = sel(leaf = one_of(AGES_UNDER18_B17024), n = 3)
  ),

  # ---- Income ---------------------------------------------------------------
  nces_median_household_income = list(
    table = "B19013", type = "median",
    num = sel(leaf = "^median household income", n = 1)
  ),

  # ---- Health insurance and disability --------------------------------------
  nces_pct_uninsured_children = list(
    table = "B27001", type = "percent",
    num = sel(
      leaf = "^no health insurance coverage$",
      path = one_of_path(INSURANCE_CHILD_AGES), n = 4
    ),
    den = sel(leaf = one_of(INSURANCE_CHILD_AGES), n = 4)
  ),
  nces_pct_uninsured_all_ages = list(
    table = "B27001", type = "percent",
    num = sel(leaf = "^no health insurance coverage$", n = 18),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_disability_5_17 = list(
    table = "B18101", type = "percent",
    num = sel(leaf = "^with a disability$", path = one_of_path("5 to 17 years"), n = 2),
    den = sel(leaf = "^5 to 17 years$", n = 2)
  ),

  # ---- Family structure -----------------------------------------------------
  nces_pct_single_parent_families = list(
    table = "B11003", type = "percent",
    num = sel(leaf = OWN_CHILDREN_LEAF, path = LONE_PARENT_PATH, n = 2),
    den = sel(leaf = OWN_CHILDREN_LEAF, n = 3)
  ),

  # ---- Economic and housing -------------------------------------------------
  nces_pct_unemployed = list(
    table = "B23025", type = "percent",
    num = sel(leaf = "^unemployed$", n = 1),
    den = sel(leaf = "^civilian labor force$", n = 1)
  ),
  nces_pct_renter_occupied = list(
    table = "B25003", type = "percent",
    num = sel(leaf = "^renter occupied$", n = 1),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_foreign_born = list(
    table = "B05002", type = "percent",
    # "Foreign born:" up to the 2018-22 vintage, "Foreign-born:" from 2019-23.
    num = sel(leaf = "^foreign[ -]born$", n = 1),
    den = sel(leaf = "^total$", n = 1)
  ),

  # ---- Internet (2017- onwards) ---------------------------------------------
  nces_pct_no_internet = list(
    table = "B28002", type = "percent",
    num = sel(
      leaf = one_of("internet access without a subscription", "no internet access"),
      n = 2
    ),
    den = sel(leaf = "^total$", n = 1)
  ),
  nces_pct_broadband = list(
    table = "B28002", type = "percent",
    num = sel(leaf = "^broadband of any type$", n = 1),
    den = sel(leaf = "^total$", n = 1)
  )
)


TABLES <- sort(unique(vapply(IND, function(x) x$table, "")))

# Resolve a selector against a table's codebook, returning cell numbers.
match_cells <- function(cb, s, ind_name, table_id, year) {
  keep <- rep(TRUE, nrow(cb))
  if (!is.null(s$leaf)) keep <- keep & grepl(s$leaf, cb$leaf_norm)
  if (!is.null(s$path)) keep <- keep & grepl(s$path, cb$path_norm)
  if (!is.null(s$not_path)) keep <- keep & !grepl(s$not_path, cb$path_norm)
  cells <- cb$cell[keep]
  if (!is.null(s$n) && length(cells) != s$n) {
    warning(
      sprintf(
        "%s (%s, %d): matched %d cells, expected %d - emitting NA",
        ind_name, table_id, year, length(cells), s$n
      ),
      call. = FALSE
    )
    return(integer())
  }
  cells
}

# -----------------------------------------------------------------------------
# 3. Download
#
# Older vintages are frozen once published, so only missing files and the most
# recent vintage are re-fetched. Full exports are large (the widest table is
# ~260 value columns over 13,400 geographies), so raw/ keeps a per-vintage
# extract holding just the cells the indicators use, alongside the codebooks.
# -----------------------------------------------------------------------------

dir.create("raw", showWarnings = FALSE)
tmp <- file.path(tempdir(), "nces_acs_ed")
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)

cells_path <- function(year) sprintf("raw/cells_%d.csv.xz", year)
codebook_path <- function(year) sprintf("raw/codebook_%d.csv.xz", year)

years_to_fetch <- YEARS[
  YEARS == max(YEARS) |
    !file.exists(vapply(YEARS, cells_path, "")) |
    !file.exists(vapply(YEARS, codebook_path, ""))
]

for (year in years_to_fetch) {
  message("=== vintage ", year)
  available <- nces_table_list(year)
  if (!length(available)) {
    warning("no table list for ", year, " - skipping vintage", call. = FALSE)
    next
  }

  codebooks <- list()
  extracts <- list()
  geo <- NULL

  for (table_id in TABLES) {
    if (!table_id %in% available) {
      message("  ", table_id, ": not published in this vintage")
      next
    }

    cb <- nces_labels(table_id, year)
    if (is.null(cb)) {
      warning(table_id, " (", year, "): no labels returned", call. = FALSE)
      next
    }

    # Cells this vintage actually needs, across every indicator on the table.
    wanted <- integer()
    for (nm in names(IND)) {
      ind <- IND[[nm]]
      if (ind$table != table_id) next
      wanted <- c(
        wanted,
        match_cells(cb, ind$num, nm, table_id, year),
        if (!is.null(ind$den)) match_cells(cb, ind$den, nm, table_id, year)
      )
    }
    wanted <- sort(unique(wanted))
    if (!length(wanted)) {
      warning(table_id, " (", year, "): no cells matched", call. = FALSE)
      next
    }

    src <- nces_export(table_id, year, tmp)
    if (is.null(src)) {
      warning(table_id, " (", year, "): export failed", call. = FALSE)
      next
    }

    raw <- vroom::vroom(
      src,
      delim = "|", col_types = vroom::cols(.default = "c"),
      progress = FALSE, altrep = FALSE
    )
    unlink(src)

    keep_cols <- c(
      paste0(table_id, "_", wanted, "est"),
      paste0(table_id, "_", wanted, "moe")
    )
    missing_cols <- setdiff(keep_cols, names(raw))
    if (length(missing_cols)) {
      warning(
        table_id, " (", year, "): export missing ", length(missing_cols),
        " expected columns", call. = FALSE
      )
      keep_cols <- intersect(keep_cols, names(raw))
    }

    # Joined on GeoId alone. Geography names are carried separately: joining on
    # the name too would split a geography into two rows if any table spelled
    # it differently.
    if (is.null(geo)) {
      geo <- raw[, c("GeoId", "Geography", "LEAID", "Year")]
    }
    extracts[[table_id]] <- raw[, c("GeoId", keep_cols)]
    codebooks[[table_id]] <- cb %>% mutate(table_id = table_id, .before = 1)
    message("  ", table_id, ": ", length(wanted), " cells, ", nrow(raw), " geographies")
    Sys.sleep(1)
  }

  if (!length(extracts)) {
    warning("nothing retrieved for ", year, call. = FALSE)
    next
  }

  combined <- Reduce(function(a, b) full_join(a, b, by = "GeoId"), extracts)
  combined <- full_join(geo, combined, by = "GeoId")
  stopifnot(!anyDuplicated(combined$GeoId))
  vroom::vroom_write(combined, cells_path(year), delim = "|", progress = FALSE)
  vroom::vroom_write(bind_rows(codebooks), codebook_path(year), delim = ",", progress = FALSE)
}

raw_files <- sort(c(
  Sys.glob("raw/cells_*.csv.xz"),
  Sys.glob("raw/codebook_*.csv.xz")
))
raw_state <- as.list(tools::md5sum(raw_files))

# -----------------------------------------------------------------------------
# 4. Transform
# -----------------------------------------------------------------------------

if (!identical(process$raw_state, raw_state)) {

  # The TableViewer renders every non-numeric cell as display text, and which
  # texts appear varies by vintage:
  #
  #   *****  **  ***   margin of error not applicable or not calculable
  #   -                estimate not applicable
  #   250,000+         median above the top published bracket (top-coded)
  #   2,500-           median below the bottom bracket (bottom-coded)
  #
  # The 2006-2010 through 2013-2017 vintages prefix currency cells with "$"
  # ("$*****", "$250,000+") where later ones do not, so the "$" and thousands
  # separators are stripped first and every vintage is then handled uniformly.
  # No ordinary value in any vintage carries a "$" or a "," - checked across
  # all 15 - so stripping them cannot corrupt a real number, and doing it
  # guards against a future vintage that formats values this way.
  #
  # Top- and bottom-coded medians become NA rather than the bracket bound,
  # because the true median is only known to lie beyond it. They are rare but
  # growing as incomes rise: 37 top-coded districts in 2019-2023, up from 2 in
  # 2006-2010.
  as_num <- function(x) {
    x <- trimws(as.character(x))
    x <- gsub("[$,]", "", x)
    not_a_number <- c("", "-", "N", "(X)", "null", "NA", "250000+", "2500-")
    x[x %in% not_a_number | grepl("^[*]+$", x)] <- NA
    v <- suppressWarnings(as.numeric(x))
    # A large negative value is the API's numeric jam value for the same
    # out-of-bracket medians.
    v[!is.na(v) & v <= -1e8] <- NA
    v
  }

  # ACS aggregation: the MOE of a sum of independent cells is the root sum of
  # squares of the cell MOEs.
  moe_sum <- function(mat) {
    if (is.null(dim(mat))) return(abs(mat))
    sqrt(rowSums(mat^2, na.rm = FALSE))
  }

  # ACS derived proportion: for p = num / den with num a subset of den,
  # MOE(p) = (1/den) * sqrt(MOE(num)^2 - p^2 * MOE(den)^2), falling back to
  # the ratio form (+) when the radicand goes negative.
  #
  # A denominator that is a population-controlled total - a whole-population
  # count at national or state level - is published with "*****" instead of a
  # margin of error, because the control makes its sampling error zero. Reading
  # that as zero rather than as unknown is what keeps percentages of the total
  # population, such as the foreign-born share, from losing their margin of
  # error at state and national level. A missing numerator margin of error
  # still yields NA, so the 2005-2009 vintage, which publishes none at all,
  # stays empty.
  moe_prop <- function(num, den, moe_num, moe_den) {
    p <- num / den
    moe_den <- ifelse(is.na(moe_den), 0, moe_den)
    rad <- moe_num^2 - p^2 * moe_den^2
    rad_alt <- moe_num^2 + p^2 * moe_den^2
    rad <- ifelse(is.na(rad) | rad < 0, rad_alt, rad)
    out <- sqrt(rad) / den
    out[!is.finite(out)] <- NA
    out
  }

  row_sum <- function(df, cols) {
    if (!length(cols)) return(NULL)
    m <- as.matrix(df[, cols, drop = FALSE])
    rowSums(m, na.rm = FALSE)
  }

  build_year <- function(year) {
    cf <- cells_path(year)
    kf <- codebook_path(year)
    if (!file.exists(cf) || !file.exists(kf)) return(NULL)

    cells <- vroom::vroom(
      cf, delim = "|", col_types = vroom::cols(.default = "c"),
      progress = FALSE, altrep = FALSE
    )
    cb_all <- vroom::vroom(kf, col_types = vroom::cols(.default = "c"), progress = FALSE)
    cb_all$cell <- as.integer(cb_all$cell)

    num_cols <- setdiff(names(cells), c("GeoId", "Geography", "LEAID", "Year", "Iteration"))
    vals <- as.data.frame(lapply(cells[num_cols], as_num))
    names(vals) <- num_cols

    out <- tibble(
      geo_id = cells$GeoId,
      geo_name = cells$Geography,
      leaid = cells$LEAID,
      period = cells$Year
    )

    for (nm in names(IND)) {
      ind <- IND[[nm]]
      cb <- cb_all[cb_all$table_id == ind$table, ]
      est <- rep(NA_real_, nrow(out))
      moe <- rep(NA_real_, nrow(out))
      bound <- rep(NA_character_, nrow(out))

      if (nrow(cb)) {
        nc <- match_cells(cb, ind$num, nm, ind$table, year)
        ne <- intersect(paste0(ind$table, "_", nc, "est"), num_cols)
        nm_ <- intersect(paste0(ind$table, "_", nc, "moe"), num_cols)

        if (length(ne) == length(nc) && length(nc)) {
          num <- row_sum(vals, ne)
          num_moe <- if (length(nm_) == length(nc)) {
            moe_sum(as.matrix(vals[, nm_, drop = FALSE]))
          } else {
            rep(NA_real_, nrow(out))
          }

          if (ind$type == "percent") {
            dc <- match_cells(cb, ind$den, nm, ind$table, year)
            de <- intersect(paste0(ind$table, "_", dc, "est"), num_cols)
            dm <- intersect(paste0(ind$table, "_", dc, "moe"), num_cols)
            if (length(de) == length(dc) && length(dc)) {
              den <- row_sum(vals, de)
              den_moe <- if (length(dm) == length(dc)) {
                moe_sum(as.matrix(vals[, dm, drop = FALSE]))
              } else {
                rep(NA_real_, nrow(out))
              }
              den[!is.na(den) & den == 0] <- NA
              est <- 100 * num / den
              moe <- 100 * moe_prop(num, den, num_moe, den_moe)
            }
          } else {
            est <- num
            moe <- num_moe
          }

          # A median that falls outside the published brackets is reported as
          # bracket text rather than a number, so `as_num` has already turned
          # it into NA. Read the raw text of the same cell to record which
          # side it fell off, so a missing median can be told apart from one
          # that is merely known to be very high or very low.
          #
          # Rows with a usable median are labelled "within" rather than left
          # empty. A column that is blank for its first several thousand rows
          # gets type-guessed as logical by readers that sample the head of the
          # file (vroom and readr both do, by default), which would silently
          # turn "top" into NA for anyone reading it without explicit types.
          if (ind$type == "median" && length(ne) == 1) {
            txt <- gsub("[$,]", "", trimws(cells[[ne]]))
            bound[!is.na(est)] <- "within"
            bound[!is.na(txt) & txt == "250000+"] <- "top"
            bound[!is.na(txt) & txt == "2500-"] <- "bottom"
          }
        }
      }

      out[[nm]] <- round(est, if (ind$type == "percent") 3 else 0)
      out[[paste0(nm, "_moe")]] <- round(moe, if (ind$type == "percent") 3 else 0)
      if (ind$type == "median") out[[paste0(nm, "_bound")]] <- bound
    }

    out
  }

  all_years <- bind_rows(lapply(YEARS, build_year))
  if (!nrow(all_years)) stop("no vintages available to transform")

  # Each measure contributes its estimate and margin of error, and a median
  # also contributes its bracket flag.
  value_cols <- unlist(lapply(names(IND), function(nm) {
    c(
      nm,
      paste0(nm, "_moe"),
      if (IND[[nm]]$type == "median") paste0(nm, "_bound")
    )
  }))
  value_cols <- intersect(value_cols, names(all_years))

  # GeoIds carry a Census summary level, then "US", then the geography's own
  # code - but the level is zero-padded to a width that varies by vintage:
  # a unified district is "97000US1700105" in some vintages and
  # "9700000US1700105" in others, and national is "01000US" or "0100000US".
  # So the level is read as "the digits before US, ignoring trailing zeros",
  # never by fixed character positions.
  all_years <- all_years %>%
    mutate(
      # Period is the ACS five-year span, e.g. "2019-2023"; the standard `time`
      # column is the last day of its final year.
      end_year = as.integer(sub("^.*-", "", period)),
      time = paste0(end_year, "-12-31"),
      sumlev = sub("US.*$", "", geo_id),
      geo_code = sub("^.*US", "", geo_id),
      level = case_when(
        grepl("^010+$", sumlev) & geo_code == "" ~ "national",
        grepl("^040+$", sumlev) & grepl("^[0-9]{2}$", geo_code) ~ "state",
        grepl("^950+$", sumlev) ~ "Elementary",
        grepl("^960+$", sumlev) ~ "Secondary",
        grepl("^970+$", sumlev) ~ "Unified",
        # The early vintages also carry regions, divisions and American
        # Indian areas, which neither output file covers.
        TRUE ~ NA_character_
      )
    ) %>%
    # A geography carried only by a later table, and so absent from the first
    # table's name/period columns, cannot be placed in time - drop it rather
    # than emit a row keyed "NA-12-31".
    filter(!is.na(end_year), !is.na(geo_id), !is.na(level))

  # --- National and state ---
  data_state <- all_years %>%
    filter(level %in% c("national", "state")) %>%
    mutate(
      geography = if_else(level == "national", "00", geo_code),
      geography_name = sub(",\\s*[A-Z]{2}$", "", geo_name)
    ) %>%
    select(geography, geography_name, time, period, all_of(value_cols)) %>%
    arrange(geography, time)

  # --- School district ---
  # geography here is the 7-digit NCES LEAID, not a FIPS code; `state` carries
  # the 2-digit state FIPS that prefixes it.
  state_names <- data_state %>%
    filter(geography != "00") %>%
    distinct(state = geography, state_name = geography_name)

  data_lea <- all_years %>%
    filter(
      level %in% c("Elementary", "Secondary", "Unified"),
      grepl("^[0-9]{7}$", leaid),
      # Census adds a "Remainder of <state>" balance area to each of the three
      # district layers to cover territory no district of that type reaches.
      # All three share the LEAID <state fips>99999, so they cannot be keyed by
      # LEAID; their population is still counted in the state file.
      !grepl("^[0-9]{2}99999$", leaid)
    ) %>%
    mutate(state = substr(leaid, 1, 2), lea_type = level) %>%
    left_join(state_names, by = "state") %>%
    mutate(
      geography = leaid,
      # District names end ", <ST>" or ", <State name>, <ST>" depending on
      # vintage.
      trimmed = sub(",\\s*[A-Z]{2}$", "", geo_name),
      geography_name = if_else(
        !is.na(state_name) & endsWith(trimmed, paste0(", ", state_name)),
        substr(trimmed, 1, nchar(trimmed) - nchar(state_name) - 2),
        trimmed
      )
    ) %>%
    select(
      geography, geography_name, state, lea_type, time, period,
      all_of(value_cols)
    ) %>%
    arrange(geography, time)

  # Every vintage must reach both files: the GeoId encoding differs between
  # vintages, and a parsing regression would otherwise silently drop years.
  stopifnot(
    !anyNA(data_state$geography),
    !anyDuplicated(paste(data_state$geography, data_state$time)),
    !anyNA(data_lea$geography),
    !anyDuplicated(paste(data_lea$geography, data_lea$time)),
    length(unique(data_state$time)) == length(unique(all_years$time)),
    length(unique(data_lea$time)) == length(unique(all_years$time))
  )

  vroom::vroom_write(data_state, "standard/data_state.csv.gz", delim = ",", progress = FALSE)
  vroom::vroom_write(data_lea, "standard/data_lea.csv.gz", delim = ",", progress = FALSE)

  message(
    "wrote ", nrow(data_state), " state rows and ", nrow(data_lea),
    " district rows over ", length(unique(all_years$time)), " vintages"
  )

  process$raw_state <- raw_state
  dcf::dcf_process_record(updated = process)
}
