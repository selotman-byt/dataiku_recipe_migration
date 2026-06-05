# Context: 4G & 5G KPI Recipe Migration (Dataiku / BigQuery)

## Overview
Migration of legacy Dataiku SQL recipes (one per vendor, Ericsson and Huawei) into **single merged recipes** for **4G and 5G hourly KPIs** on GCP BigQuery.

Common pattern for both technos:
- **Primary hourly sources** (vendor feeds; BYT + SFR)
- **Secondary source** (`dim_histo_kpi_hr_*_byt`) used as fallback
- **FULL JOIN** + **COALESCE** to keep unmatched rows and fill gaps

---

## 4G

### Legacy Recipes (being replaced)

#### `old_erc_4g.sql` — Ericsson
- Driver table: `btel-data-prd-pres.socle.idr_fd_kpi_eri_pdf_pmpdcvdldrtrq_1` (alias `pdcp`)
- 12 LEFT OUTER JOINs on `(dat_tstm, eutrancell_id)`: fdd_1, fdd_2, fdd_4, fdd_5, pdcch, prb, erab, abeactq, abenbq, abmactq, nenbqci
- Unit conversion logic: counters divided by 1000 for dates >= `2025-12-11` (BPerf migration from MyPerf)
- Output columns included: trafic QCI 6-9, trafic_mac_dl, taux_usage_prb (num/denom), nb_ue (num/denom), TDC PS (num/denom), charge_cce (num/denom), debit_dl_ue (num/denom), source='byt_eri'
- Known bug: `abeactq` subquery selects from `pmerrlabeactq_1` but partition filter variable references `pmerrlabmactq_1` (copy-paste mismatch)

#### `old_hua_4g.sql` — Huawei
- Driver table: `btel-data-prd-pres.socle.idr_fd_kpi_hua_thruput` (alias `THR`)
- JOINs: number_of_user (NB), prb (PRB), e_rab_rel (RAB), mac (MAC)
- Unit conversion logic: counters divided by 1000000 for dates >= `2025-12-11`
- Output columns: same KPI structure as Ericsson recipe
- Output wrapped in outer `SELECT * FROM (...) WHERE trafic_pdcp_dl_mo IS NOT NULL OR trafic_mac_dl_mo IS NOT NULL`

### Known Bug in Legacy (April 2026)

- **Problem**: Duplicate rows in output of `old_erc_4g.sql` for dates on/after 2026-04-29, cell `LA1304C` (and likely others)
- **Root cause**: Source table `btel-data-prd-pres.socle.idr_fd_kpi_eri_pdf_pmprbutildl` contains duplicate `(dat_tstm, eutrancell_id)` keys (likely double-loaded partition)
- **Fix applied** (minimal change to legacy): deduplicate the `prb` subquery using `ROW_NUMBER()`:

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

### Final merged recipe
- File: `compute_zlbyt_hua_erc_cell_4g_horaire.sql`

#### Sources
| Alias | Table(s) | Notes |
|---|---|---|
| `src` | `TRB_IND_data_4g_hua_erc` UNION ALL `TRB_IND_data_4g_sfr_hua_erc_` | primary hourly (BYT + SFR) |
| `dim` | `dim_histo_kpi_hr_4g_byt` | secondary fallback |

**Join keys**: `src.tstamp = dim.date_heure AND src.cellname = dim.cellname AND src.date_jour = dim.date_jour`

#### Key derived columns
- `operateur_kalix`: `COALESCE(src.operateur, RIGHT(dim.cellname,1) IN (N,O,P,Q,R) → 'SFR' ELSE 'BYTEL')`
- `vendor_kalix`: `COALESCE(src.vendor, dim.constructeur ERICSSON→Ericsson, HUAWEI→Huawei)`
- `frequency_band_kalix`: `COALESCE(src.frequency_band, LEFT(dim.cellname,1) mapping D/P/T/K/L/F → LTE...)`
- `source`: derived from coalesced vendor (`byt_eri` / `byt_hua`)

---

## 5G

### Final merged recipe
- File: `compute_zlbyt_hua_erc_cell_5g_horaire.sql`

### Architecture: CTE per vendor + secondary fallback
Unlike 4G, the 5G primary sources differ by vendor schema (Ericsson vs Huawei). To keep the code lean and readable:
- `main_ericsson`: UNION ALL BYT + SFR Ericsson tables, projected to a unified column set
- `main_huawei`: UNION ALL BYT + SFR Huawei tables, projected to the same unified column set (QCI computed as NSA + SA)
- `src = main_ericsson UNION ALL main_huawei`
- `dim`: secondary fallback (`dim_histo_kpi_hr_5g_byt`)
- final query: `FULL JOIN` + `COALESCE`

### Sources
| Alias | Table(s) | Notes |
|---|---|---|
| `main_ericsson` | `TRB_IND_data_5g_erc` UNION ALL `TRB_IND_data_5g_sfr_erc` | primary hourly Ericsson (BYT + SFR) |
| `main_huawei` | `TRB_IND_data_5g_hua` UNION ALL `TRB_IND_data_5g_sfr_hua` | primary hourly Huawei (BYT + SFR) |
| `dim` | `dim_histo_kpi_hr_5g_byt` | secondary fallback |

**Join keys**: `src.tstamp = dim.date_heure AND src.cellname = dim.cellname AND src.date_jour = dim.date_jour`

### Key derived columns
- `operateur_kalix`: same rule as 4G
- `vendor_kalix`: same rule as 4G
- `frequency_band_kalix`: `COALESCE(src.frequency_band, LEFT(dim.cellname,1) mapping Y→NR2100, Q→NR3500, J→NR26000)`
- `trafic_pdcp_ul_mo`: coalesced with `COALESCE(dim.trafic_pdcp_ul_5g_nsa,0)+COALESCE(dim.trafic_pdcp_ul_5g_sa,0)`
- `trafic_pdcp_dl_mo`: coalesced with `COALESCE(dim.trafic_pdcp_dl_5g_nsa,0)+COALESCE(dim.trafic_pdcp_dl_5g_sa,0)`
- `trafic_pdcp_dl_mo_x2_lte`: coalesced with `dim.trafic_pdcp_dl_4g`

### QCI logic (vendor specific)
- Ericsson primary:
  - `trafic_data_qci_6..9` from `_5g_trafic_pdcp_dl_cell_erc_nr_6..9`
- Huawei primary:
  - `trafic_data_qci_X = COALESCE(rlc_nsa_dl_qciX_mo,0) + COALESCE(rlc_sa_dl_5qi_X,0)`
- Secondary fallback for QCI (dim-only rows):
  - If `dim.constructeur='HUAWEI'` → use `dim.trafic_5g_ca_dl_qci_X`
  - For `qci_9` only: if `dim.constructeur='ERICSSON'` → `0.97 * dim.trafic_5g_ca_dl_qci_9` (dim is MAC; estimate PDCP)

### Secondary-only KPIs
- `taux_usage_prb_dl` = `dim.occupation_prb_dl`
- `nb_ue_connectes_nsa` = `dim.nbr_ue_connected_nsa`
- `nb_ue_connectes_sa` = `dim.nbr_ue_connected_sa`
- `nb_ue_actifs` = `dim.nbr_ue_actifs_dl`
- `charge_cce` = `dim.occupation_cce`

---

## Open Items / Next Steps
- Validate 4G and 5G merged recipes against legacy outputs on a controlled date range
- Monitor FULL JOIN output for orphaned rows (unmatched src or dim)
- Partition target output tables on `date_jour`
- Decommission legacy recipes once validated in production
