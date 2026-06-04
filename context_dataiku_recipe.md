# Context: 4G KPI Recipe Migration (Dataiku / BigQuery)

## Overview
Migration of two legacy Dataiku SQL recipes (one per vendor, Ericsson and Huawei) into a single merged recipe for 4G hourly KPIs. Project is on GCP BigQuery.

Enhanced with **FULL JOIN** + **COALESCE** fallback logic to fill gaps from a secondary source (`dim_histo_kpi_hr_4g_byt`).

---

## Legacy Recipes (being replaced)

### `old_erc_4g.sql` — Ericsson
- Driver table: `btel-data-prd-pres.socle.idr_fd_kpi_eri_pdf_pmpdcvdldrtrq_1` (alias `pdcp`)
- 12 LEFT OUTER JOINs on `(dat_tstm, eutrancell_id)`: fdd_1, fdd_2, fdd_4, fdd_5, pdcch, prb, erab, abeactq, abenbq, abmactq, nenbqci
- Unit conversion logic: counters divided by 1000 for dates >= `2025-12-11` (BPerf migration from MyPerf)
- Output columns included: trafic QCI 6-9, trafic_mac_dl, taux_usage_prb (num/denom), nb_ue (num/denom), TDC PS (num/denom), charge_cce (num/denom), debit_dl_ue (num/denom), source='byt_eri'
- Known bug: `abeactq` subquery selects from `pmerrlabeactq_1` but partition filter variable references `pmerrlabmactq_1` (copy-paste mismatch)

### `old_hua_4g.sql` — Huawei
- Driver table: `btel-data-prd-pres.socle.idr_fd_kpi_hua_thruput` (alias `THR`)
- JOINs: number_of_user (NB), prb (PRB), e_rab_rel (RAB), mac (MAC)
- Unit conversion logic: counters divided by 1000000 for dates >= `2025-12-11`
- Output columns: same KPI structure as Ericsson recipe
- Output wrapped in outer `SELECT * FROM (...) WHERE trafic_pdcp_dl_mo IS NOT NULL OR trafic_mac_dl_mo IS NOT NULL`

---

## Known Bug in Legacy (April 2026)

- **Problem**: Duplicate rows in output of `old_erc_4g.sql` for dates on/after 2026-04-29, cell `LA1304C` (and likely others)
- **Root cause**: Source table `btel-data-prd-pres.socle.idr_fd_kpi_eri_pdf_pmprbutildl` contains duplicate `(dat_tstm, eutrancell_id)` keys for affected dates (likely double-loaded partition)
- **Fix applied** (Option A — minimal change to legacy recipe): deduplicate the `prb` subquery using `ROW_NUMBER()`:

```sql
LEFT OUTER JOIN (
  SELECT * EXCEPT(rn) FROM (
    SELECT *,
           ROW_NUMBER() OVER (
             PARTITION BY dat_tstm, eutrancell_id
             ORDER BY dat_tstm
           ) AS rn
      FROM btel-data-prd-pres.socle.idr_fd_kpi_eri_pdf_pmprbutildl
      WHERE ${DKU_PARTITION_FILTER_idr_fd_kpi_eri_pdf_pmprbutildl}
  )
  WHERE rn = 1
) AS prb ON pdcp.dat_tstm = prb.dat_tstm
 AND pdcp.eutrancell_id = prb.eutrancell_id
```

- Only the `prb` join block is changed; all other 11 joins are untouched
- Safe because duplicate rows are byte-for-byte identical; `ORDER BY` choice does not matter

---

## New Recipe: `compute_zlbuy_hua_erc_cell_4g_horaire.sql`

### Architecture: FULL JOIN + COALESCE

The new recipe uses a **FULL JOIN** between two sources:
- **Left**: `src` (union of BYT and SFR hourly data from `TRB_IND_data_4g_hua_erc` tables)
- **Right**: `dim` (BYT/SFR hourly KPI aggregates from `dim_histo_kpi_hr_4g_byt`)

**COALESCE** on all columns ensures:
1. Primary data from `src` is used when available
2. If `src` is NULL, fallback to `dim` equivalent (with transformations where needed)
3. If both are NULL, result is NULL
4. Unmatched rows from either side are preserved (due to FULL JOIN)

### Sources

| Alias | Table | Filter | Notes |
|---|---|---|---|
| `src` (union) | `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_4g_hua_erc` | `date_jour` partition | BYT cells, hourly |
| `src` (union) | `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_4g_sfr_hua_erc_` | `date_jour` partition | SFR cells, hourly |
| `dim` | `btel-data-lab-trb-ingeradio.prod.dim_histo_kpi_hr_4g_byt` | `date_jour` partition | BYT & SFR cells, hourly aggregates |

**Join keys**: `src.tstamp = dim.date_heure AND src.cellname = dim.cellname AND src.date_jour = dim.date_jour`

### Target Schema (v2 — with FULL JOIN enhancements)

| Column | Type (BQ / Dataiku) | Source Logic |
|---|---|---|
| `dat_tstm` | DATETIME / datetime no tz | `COALESCE(src.tstamp, dim.date_heure)` |
| `date_jour` | DATE / dateonly | `COALESCE(src.date_jour, dim.date_jour)` |
| `cellname` | STRING / string | `COALESCE(src.cellname, dim.cellname)` |
| `operateur_kalix` | STRING / string | `COALESCE(src.operateur, CASE WHEN RIGHT(dim.cellname,1) IN ('N','O','P','Q','R') THEN 'SFR' ELSE 'BYTEL' END)` |
| `frequency_band_kalix` | STRING / string | `COALESCE(src.frequency_band, CASE LEFT(dim.cellname,1) WHEN 'D' THEN 'LTE1800' WHEN 'P' THEN 'LTE2100' ... END)` |
| `vendor_kalix` | STRING / string | `COALESCE(src.vendor, CASE WHEN dim.constructeur='ERICSSON' THEN 'Ericsson' WHEN dim.constructeur='HUAWEI' THEN 'Huawei' END)` |
| `crozon_kalix` | STRING / string | `src.crozon` (src-only; note: '1' = Crozon, '0' + ransharing='false' = ZTD) |
| `ransharing_kalix` | STRING / string | `src.ransharing` (src-only) |
| `trafic_data_qci_6` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_dl_qci6, dim.trafic_pdcp_dl_qci_6)` |
| `trafic_data_qci_7` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_dl_qci7, dim.trafic_pdcp_dl_qci_7)` |
| `trafic_data_qci_8` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_dl_qci8, dim.trafic_pdcp_dl_qci_8)` |
| `trafic_data_qci_9` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_dl_qci9, dim.trafic_pdcp_dl_qci_9)` |
| `trafic_data_pdcp_dl` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_dl_drb, dim.trafic_pdcp_dl)` |
| `trafic_data_pdcp_ul` | FLOAT64 / double | `COALESCE(src._4g_trafic_data_ul_drb, dim.trafic_pdcp_ul)` |
| `trafic_mac_dl_mo` | FLOAT64 / double | `COALESCE(src._4g_trafic_mac_dl, dim.trafic_cell_dl)` |
| `trafic_mac_ul_mo` | FLOAT64 / double | `src._4g_vol_trafic_mac_ul` (src-only) |
| `taux_usage_prb_dl` | FLOAT64 / double | `dim.occupation_prb_dl` (dim-only; ratio already calculated) |
| `nb_ue_connectes` | FLOAT64 / double | `dim.nbr_ue_connected` (dim-only; ratio already calculated) |
| `nb_ue_actifs` | FLOAT64 / double | `dim.nbr_ue_actifs_dl` (dim-only; ratio already calculated) |
| `charge_cce` | FLOAT64 / double | `dim.occupation_cce` (dim-only; ratio already calculated) |
| `source` | STRING / string | Derived from coalesced vendor: `'byt_eri'` (Ericsson), `'byt_hua'` (Huawei), `NULL` otherwise |

### Dropped vs Legacy
- **Dropped**: TDC PS (numerateur/denominateur), debit_dl_ue (numerateur/denominateur)
- **Simplified**: all other KPIs were numerateur/denominateur pairs in legacy; new source provides ratios directly

### Fallback column logic (COALESCE)

#### `operateur_kalix`
- If `src.operateur` is NULL (dim-only row), infer from last character of cell name: N/O/P/Q/R → SFR, else → BYTEL

#### `frequency_band_kalix`
- If `src.frequency_band` is NULL, infer from first character of cell name: D→LTE1800, P→LTE2100, T→LTE800, K→LTE700, L→LTE2600, F→LTE1400

#### `vendor_kalix`
- If `src.vendor` is NULL, infer from `dim.constructeur`: ERICSSON→Ericsson, HUAWEI→Huawei

#### Trafic KPI COALESCEs
- Fill gaps in hourly trafic data from dim aggregates (qci_6-9, pdcp_dl/ul, mac_dl)

### Partition filter / BigQuery cost notes
- All three sources are partitioned on `date_jour`
- `dim` is filtered inside a subquery (safe partition pruning; avoids full-table scans)
- Join key includes `src.date_jour = dim.date_jour` to ensure matching date ranges
- **FULL JOIN semantics**: unmatched rows from either side survive, allowing capture of data from only `dim` (or only `src`)

---

## Key Design Decisions

### FULL JOIN vs LEFT JOIN
- **FULL JOIN** captures all rows from both sides (no data loss)
- Unmatched rows from either source are included (orphaned records or timing mismatches)
- **LEFT JOIN** (original) would silently drop unmatched `dim` rows

### COALESCE Strategy
- **src-first** (primary): ensures new hourly data takes precedence
- **dim-fallback** (secondary): only used when `src` is NULL
- **Inferred columns**: derived from cell naming conventions when source is missing

### Attributes Left src-only
- `crozon_kalix`, `ransharing_kalix`, `trafic_mac_ul_mo`: only available in `src`; no fallback from `dim`
- These will be NULL for dim-only rows (expected behavior)

---

## Open Items / Next Steps
- Validate against known test cases (April 2026 with fixed `old_erc_4g.sql`)
- Monitor FULL JOIN output for orphaned rows (unmatched src or dim)
- Rebuild April data using patched `old_erc_4g.sql` (prb dedup fix) for comparison
- Partition the target output table on `date_jour`
- Decommission `old_erc_4g.sql` and `old_hua_4g.sql` once new recipe is validated and in production
