# nces-data

NCES education data standardized for the PopHIVE platform, as a
[Data Collection Framework](https://dissc-yale.github.io/dcf/) project.

This repository is separate from [PopHIVE/Ingest](https://github.com/PopHIVE/Ingest)
because its natural geography is the **school district**, identified by a 7-digit
NCES LEAID, which has no place in the FIPS-keyed standard format that `Ingest`
uses.

## Sources

| Source | What it covers | Geographies | Vintages |
|---|---|---|---|
| [`nces_acs_ed`](data/nces_acs_ed) | ACS-ED Tables: ACS five-year estimates retabulated onto school district boundaries — enrollment, child poverty, language, health insurance, high school completion | national, state, ~13,400 school districts | 2005-2009 through 2019-2023 |

## Usage

```r
# check every source
dcf::dcf_check()

# process one source
dcf::dcf_process("nces_acs_ed")

# process everything
dcf::dcf_process()
```

## Conventions

Standardized outputs follow the PopHIVE format — `geography` and `time` index
columns, `time` as `YYYY-mm-dd`, gzip-compressed CSV in each source's
`standard/` directory — with one documented departure: in district-level files
`geography` holds an NCES LEAID rather than a FIPS code, and the containing
state's 2-digit FIPS is in a separate `state` column. Each source's README states
which of its files this applies to.

Annual data uses the last day of the year for `time`. For ACS five-year periods
that is the last day of the period's final year, and the period as published is
kept alongside it in a `period` column.
