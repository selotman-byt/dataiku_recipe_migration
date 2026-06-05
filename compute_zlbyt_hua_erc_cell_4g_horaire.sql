-- =====================================================================
-- 4G hourly KPIs — merged vendor recipe (Huawei + Ericsson) + secondary fallback
-- Structure:
--   src           : union BYT+SFR 4G hourly sources (same schema)
--   dim           : secondary (dim_histo_kpi_hr_4g_byt), partition-filtered
--   final SELECT  : FULL JOIN src/dim + COALESCE fallbacks (src primary, dim secondary)
-- Notes:
--   - operateur_kalix inferred from RIGHT(cellname,1) when src.operateur is NULL
--   - vendor_kalix normalised from dim.constructeur when src.vendor is NULL
--   - frequency_band_kalix inferred from LEFT(cellname,1) when src.frequency_band is NULL
-- =====================================================================

SELECT
    COALESCE(src.`tstamp`, dim.`date_heure`) AS `dat_tstm`,
    COALESCE(src.`date_jour`, dim.`date_jour`) AS `date_jour`,
    COALESCE(src.`cellname`, dim.`cellname`) AS `cellname`,
    COALESCE(
        src.`operateur`,
        CASE
            WHEN RIGHT(dim.`cellname`, 1) IN ('N','O','P','Q','R') THEN 'SFR'
            ELSE 'BYTEL'
        END
    ) AS `operateur_kalix`,
    COALESCE(src.`frequency_band`,
        CASE LEFT(dim.`cellname`, 1)
            WHEN 'D' THEN 'LTE1800' WHEN 'P' THEN 'LTE2100' WHEN 'T' THEN 'LTE800'
            WHEN 'K' THEN 'LTE700' WHEN 'L' THEN 'LTE2600' WHEN 'F' THEN 'LTE1400'
        END
    ) AS `frequency_band_kalix`,
    COALESCE(
        src.`vendor`,
        CASE
            WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
            WHEN dim.`constructeur` = 'HUAWEI' THEN 'Huawei'
            ELSE NULL
        END
    ) AS `vendor_kalix`,
    src.`crozon` AS `crozon_kalix`, -- '1' = Crozon, ('0' and 'ransharing'='false') = ZTD 
    src.`ransharing` AS `ransharing_kalix`,

    -- Trafic data PDCP par QCI
    COALESCE(src.`_4g_trafic_data_dl_qci6`, dim.`trafic_pdcp_dl_qci_6`) AS `trafic_data_qci_6`,
    COALESCE(src.`_4g_trafic_data_dl_qci7`, dim.`trafic_pdcp_dl_qci_7`) AS `trafic_data_qci_7`,
    COALESCE(src.`_4g_trafic_data_dl_qci8`, dim.`trafic_pdcp_dl_qci_8`) AS `trafic_data_qci_8`,
    COALESCE(src.`_4g_trafic_data_dl_qci9`, dim.`trafic_pdcp_dl_qci_9`) AS `trafic_data_qci_9`,

    -- Trafic data PDCP DL/UL (DRB)
    COALESCE(src.`_4g_trafic_data_dl_drb`, dim.`trafic_pdcp_dl`) AS `trafic_data_pdcp_dl`,
    COALESCE(src.`_4g_trafic_data_ul_drb`, dim.`trafic_pdcp_ul`) AS `trafic_data_pdcp_ul`,

    -- Trafic MAC DL/UL
    COALESCE(src.`_4g_trafic_mac_dl`, dim.`trafic_cell_dl`) AS `trafic_mac_dl_mo`,
    src.`_4g_vol_trafic_mac_ul` AS `trafic_mac_ul_mo`,

    -- KPIs complémentaires (ratios déjà calculés dans la source dim)
    dim.`occupation_prb_dl` AS `taux_usage_prb_dl`,
    dim.`nbr_ue_connected` AS `nb_ue_connectes`,
    dim.`nbr_ue_actifs_dl` AS `nb_ue_actifs`,
    dim.`occupation_cce` AS `charge_cce`,

    -- Origine des données
    CASE
        WHEN COALESCE(src.`vendor`,
                 CASE WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
                      WHEN dim.`constructeur` = 'HUAWEI' THEN 'Huawei' END) = 'Ericsson' THEN 'byt_eri'
        WHEN COALESCE(src.`vendor`,
                 CASE WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
                      WHEN dim.`constructeur` = 'HUAWEI' THEN 'Huawei' END) = 'Huawei' THEN 'byt_hua'
        ELSE NULL
    END AS `source`

FROM  
    --collecte horaire dédiée projections de trafic 3YP/6YP
    (
        SELECT *
        FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_4g_hua_erc`
        WHERE ${DKU_PARTITION_FILTER_data_4G_hua_erc}

        UNION ALL

        SELECT *
        FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_4g_sfr_hua_erc_`
        WHERE ${DKU_PARTITION_FILTER_data_4G_sfr_hua_erc_}
    ) AS src
    --collecte horaire TBPx globale 
    FULL JOIN (
        SELECT *
        FROM `btel-data-lab-trb-ingeradio.prod.dim_histo_kpi_hr_4g_byt`
        WHERE ${DKU_PARTITION_FILTER_dim_histo_kpi_hr_4g_byt}
    ) AS dim
        ON src.`tstamp` = dim.`date_heure`
        AND src.`cellname` = dim.`cellname`
        AND src.`date_jour` = dim.`date_jour`;
