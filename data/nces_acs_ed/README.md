# nces_acs_ed

NCES ACS-ED Tables: American Community Survey five-year estimates retabulated
onto school district boundaries, for national, state and school district
geographies.

- Source page: <https://nces.ed.gov/programs/edge/Demographic/acsedtables>
- Vintages: 15, from 2005-2009 through 2019-2023
- Run with `dcf::dcf_process("nces_acs_ed")` from the project root

## Outputs

| File | Rows | `geography` holds |
|---|---|---|
| `standard/data_state.csv.gz` | 795 — 15 vintages x 53 (national, 50 states, DC, PR) | `"00"` for national, otherwise a 2-digit state FIPS |
| `standard/data_lea.csv.gz` | 202,075 — 15 vintages x 13,273-13,824 districts | a 7-digit **NCES LEAID**, not a FIPS code |

Both files carry the same 42 indicators, each with a paired `_moe` column, plus:

- `time` — last day of the vintage's final year, e.g. `2023-12-31`
- `period` — the ACS five-year span as published, e.g. `2019-2023`
- `geography_name` — state or district name
- `state` (district file only) — 2-digit state FIPS, which also prefixes the LEAID
- `lea_type` (district file only) — `Elementary`, `Secondary` or `Unified`

The district file departs from the usual PopHIVE convention that `geography` is a
FIPS code, because school districts have no FIPS equivalent. A district is
identified by its LEAID; the containing state is in `state`.

## Where the data comes from

The ACS-ED Tables page is a single-page app whose API requires a bearer token and
returns HTTP 406 to scripted clients. The legacy EDGE TableViewer JSON API behind
it is open and serves the same tabulations, so `ingest.R` uses that:

| Endpoint (POST, under `/programs/edge/`) | Returns |
|---|---|
| `TableViewer/tableListGetAll` | every ACS table published in a vintage (1,038-1,193 of them) |
| `TableViewer/TableGet` | one table's cell labels, read off the national preview |
| `TableViewer/TableExportToCSV` | a pipe-delimited export, written to `/tempfiles/sdds/` |

One export call per table returns every geography at once: national, 52
states/DC/PR, and roughly 13,400 districts. Requesting several tables in one call
does not work — only the last is returned — so it is one call per table per
vintage.

Attribute sets are `tableId-universe-gradeAge-enrollmentType-geoType-geoId`. The
2005-2009 through 2007-2011 vintages store an ACS-ED population group in the
`enrollmentType` slot and their stored procedures fail without one; `ingest.R`
supplies the whole-population code, which is `301` for 2005-2009 and `001` for the
other two.

## How indicators are built

The 42 indicators are derived from 17 ACS tables. Rather than mirroring every
cell (the 17 tables run to 583 cells, and the full 1,193-table set is far wider),
`ingest.R` names the cells behind each indicator and sums them.

Cells are selected by matching **normalised label text and ancestor path**, not
cell position, because Census renumbers and relabels tables between vintages.
Each selector declares how many cells it should match, and that count is checked
against every vintage; a mismatch produces a warning and an `NA` for that vintage
rather than a silently wrong number. Label changes already handled this way:

| Table | Change | First vintage with the new wording |
|---|---|---|
| `B14005` | `High school graduate:` -> `High school graduate (includes equivalency):` | 2009-2013 |
| `B15002` | `High school graduate, GED, or alternative` -> `... (includes equivalency)` | 2009-2013 |
| `B11003` | `With own children under 18 years` -> `With own children of the householder under 18 years` | 2011-2015 |
| `B27001` | second child age band `6 to 17 years` -> `6 to 18 years` | 2013-2017 |
| `B11003` | `no wife present` / `no husband present` -> `no spouse present` | 2015-2019 |
| `B05002` | `Foreign born:` -> `Foreign-born:` | 2019-2023 |

The `B27001` change is the only one that moves a universe rather than just
wording, so `nces_pct_uninsured_children` covers under-18 up to the 2012-2016
vintage and under-19 from 2013-2017 on.

Tables enter the series at different points, so early vintages have missing
columns: `B23025` (unemployment) from 2007-2011, `B15003`/`B18101`/`B27001` from
2008-2012, `B28002` (internet) from 2013-2017.

Margins of error are recomputed, not copied: sums of cells use the Census
Bureau's root-sum-of-squares rule, and percentages use its derived-proportion
formula, falling back to the ratio form where the radicand goes negative. The
2005-2009 vintage publishes no margins of error, so those columns are `NA`.

### Special values

The TableViewer returns non-numeric cells as display text, all of which becomes
`NA`:

| Text | Meaning | Roughly per vintage |
|---|---|---|
| `*****`, `**`, `***` | margin of error not applicable or not calculable | ~2,250 cells |
| `-` | estimate not applicable | tens of cells |
| `250,000+` | median above the top published bracket | 0-37 districts |
| `2,500-` | median below the bottom bracket | 0-5 districts |

The 2006-2010 through 2013-2017 vintages prefix currency cells with `$`
(`$*****`, `$250,000+`) where the others do not, so `$` and thousands separators
are stripped before parsing and every vintage is then handled the same way. No
ordinary value in any of the 15 vintages carries a `$` or a `,`, so this cannot
corrupt a real number.

Top- and bottom-coded medians become `NA` rather than the bracket bound, since
the true median is only known to lie beyond it. Because that would otherwise
make the highest-income districts silently vanish from any ranking,
`nces_median_household_income_bound` records which rows those are:

| Value | Meaning | Rows |
|---|---|---|
| `within` | estimate is a usable number | 201,175 |
| `top` | ACS reported `$250,000+`; estimate is `NA`, true median >= $250,000 | 109 |
| `bottom` | ACS reported `$2,500-`; estimate is `NA`, true median <= $2,500 | 8 |
| *(empty)* | median missing for some other reason | 783 |

Top-coded rows grow as incomes rise — 1 district in 2006-2010, 37 in 2019-2023 —
and are exactly who you would expect (Hillsborough, Los Altos, Orinda, Piedmont
and Woodside in California; Darien and New Canaan in Connecticut; all with
74-87% of adults holding a bachelor's degree). Bottom-coded rows are tiny
Montana elementary districts of 55-211 people.

To use the bounds as numbers rather than dropping them:

```r
income <- if_else(bound == "top", 250000,
          if_else(bound == "bottom", 2500, nces_median_household_income))
```

Rows with a usable median are labelled `within` rather than left blank on
purpose: a column that is empty for its first few thousand rows gets
type-guessed as logical by readers that sample the head of the file — `vroom`
and `readr` both do by default — which would silently turn `top` into `NA`.

## `raw/`

`raw/` holds, per vintage:

- `cells_<year>.csv.xz` — the downloaded export reduced to the ~180 cells the
  indicators use. Full exports of all 17 tables would run to hundreds of
  megabytes; the reduction keeps the cache manageable while still letting the
  transform re-run without re-downloading. **Gitignored** (77 MB, and rewritten
  whenever a vintage is refreshed) — a fresh clone rebuilds them by running the
  ingest, at the cost of roughly 50 minutes of API calls.
- `codebook_<year>.csv.xz` — every cell's label, indent, and full ancestor path,
  which is what the selectors match against and what to read when an indicator
  goes `NA` for a vintage. **Committed**: 85 KB in total, and the record of what
  each vintage actually contained.

Published vintages are frozen, so `ingest.R` re-downloads only the most recent
vintage plus anything missing.

`raw/` totals 77 MB. Parquet was measured as an alternative and is **worse** on
this data — xz/LZMA beats parquet's compression here:

| Layout | Size |
|---|---|
| 15 x `cells_*.csv.xz` (current) | **76.7 MB** |
| one combined `csv.xz` | 76.8 MB |
| combined parquet, typed, zstd | 89.1 MB |
| combined parquet, typed, gzip | 89.2 MB |
| combined parquet, long form, gzip | 100 MB |
| combined parquet, typed, snappy | 103.6 MB |

Combining the 15 files into one saves nothing either: each is already large
enough for xz to build a good dictionary. So the format is left as is. If `raw/`
needs to stop costing repo space, gitignore it and accept that a fresh clone
re-downloads it (roughly 50 minutes of API calls).

## Caveats

- **Small-area uncertainty is the big one.** For many measures, most districts'
  margins of error are larger than the estimate itself. Share of districts in
  the 2019-2023 vintage where `_moe` exceeds the estimate:

  | Measure | MOE > estimate |
  |---|---|
  | `nces_pct_limited_english_5_17` | 80.6% |
  | `nces_pct_dropout_16_19` | 75.0% |
  | `nces_pct_uninsured_children` | 41.2% |
  | `nces_pct_disability_5_17` | 28.0% |
  | `nces_pct_poverty_under18` | 23.2% |
  | `nces_pct_unemployed` | 13.3% |
  | `nces_pct_no_internet` | 3.2% |
  | `nces_pct_ba_or_higher_25plus` | 1.5% |

  Rates built on small numerators — dropout, limited English, uninsured — are
  not usable for a single small district. They are usable in aggregate, for
  large districts, and for ranking with the uncertainty carried along. Never
  read a district-level dropout rate without its MOE.

- **Five-year averages.** Consecutive vintages share four years of sample, so
  year-over-year movement is heavily autocorrelated and is not annual change.
- **District layers overlap.** Elementary, Secondary and Unified districts are
  three separate layers that cover the same ground in dual-district states, so
  rows must not be summed across `lea_type`. Use `data_state.csv.gz` for totals.
- **Moving boundaries.** District boundaries, names and LEAIDs are refreshed
  annually. 14,241 distinct LEAIDs appear across the 15 vintages, against
  13,273-13,824 in any single one, so a district's geography and its very
  presence are not constant.
- **Median income is nominal to each vintage.** `B19013` is inflation-adjusted to
  the final year of its own five-year period, so deflate to a common year before
  comparing vintages.
- **`nces_pop_total_moe` is empty far more often than the other margins.** ACS
  publishes `*****` instead of a margin of error wherever a population total is
  *controlled* to an independent estimate rather than sampled, which makes its
  sampling error zero by construction. That covers every national and state row
  — so the column is entirely empty in `data_state.csv.gz` — and districts
  coextensive with a controlled geography, which is why New York City and Puerto
  Rico are empty too. Elsewhere it is populated for 175,676 of 202,075 district
  rows, with a median margin of 344 people, about 6% of the estimate.
  Percentages whose denominator is such a total treat it as exact.
- **No cohort graduation rate.** See below.

## Graduation

The ACS-ED tables contain no Adjusted Cohort Graduation Rate. ACS is a household
survey, and the ACGR comes from the separate NCES EDFacts and Common Core of Data
collections. What this source does carry, from table `B14005`, is the
survey-based equivalent for 16-19 year olds:

| Measure | Definition |
|---|---|
| `nces_pct_hs_grad_16_19` | of 16-19 year olds who have left school, the share holding a diploma or equivalency |
| `nces_pct_dropout_16_19` | of all 16-19 year olds, the share neither enrolled nor holding a credential |
| `nces_pct_enrolled_16_19` | of all 16-19 year olds, the share still enrolled |
| `nces_pct_hs_or_higher_25plus` | of adults 25+, the share with at least a diploma (table `B15002`) |

These differ from the ACGR in three ways that matter: equivalency credentials
count as completion, it is a five-year average across a four-year age range
rather than one cohort followed to graduation, and it is tabulated by where a
teenager **lives** rather than by the school they attended.

Nationally the series behaves as expected — `nces_pct_dropout_16_19` falls from
6.4% (2005-2009) to 3.9% (2019-2023) — but see the uncertainty table above
before using it for an individual district.
