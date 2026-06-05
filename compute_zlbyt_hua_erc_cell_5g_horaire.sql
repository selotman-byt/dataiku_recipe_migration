-- =====================================================================
-- Structure:
--   main_ericsson : union BYT+SFR Ericsson, collecte horaire dédiée 3YP/6YP
--   main_huawei   : union BYT+SFR Huawei, collecte horaire dédiée 3YP/6YP
--   src           : main_ericsson UNION ALL main_huawei
--   dim           : secondary (dim_histo_kpi_hr_5g_byt)
--   final SELECT  : FULL JOIN src/dim + COALESCE fallbacks (src primary, dim secondary)
-- =====================================================================

WITH
main_ericsson AS (
    SELECT
        `tstamp`,
        `date_jour`,
        `cellname`,
        `operateur`,
        `frequency_band`,
        `vendor`,
        `crozon`,
        `_5g_trafic_pdcp_ul_cell`            AS `trafic_pdcp_ul_mo`,
        `_5g_trafic_pdcp_dl_cell_erc_nr`     AS `trafic_pdcp_dl_mo`,
        `_5g_trafic_pdcp_dl_cell_erc_x2_lte` AS `trafic_pdcp_dl_mo_x2_lte`,
        `_5g_trafic_pdcp_dl_cell_erc_nr_6`   AS `trafic_data_qci_6`,
        `_5g_trafic_pdcp_dl_cell_erc_nr_7`   AS `trafic_data_qci_7`,
        `_5g_trafic_pdcp_dl_cell_erc_nr_8`   AS `trafic_data_qci_8`,
        `_5g_trafic_pdcp_dl_cell_erc_nr_9`   AS `trafic_data_qci_9`,
        `_5g_trafic_dl_mac_sdu`              AS `trafic_mac_dl_mo`,
        `_5g_trafic_ul_cell_mac_sdu_mb_`     AS `trafic_mac_ul_mo`
    FROM (
        SELECT * FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_5g_erc`
        WHERE ${DKU_PARTITION_FILTER_data_5G_erc}
        UNION ALL
        SELECT * FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_5g_sfr_erc`
        WHERE ${DKU_PARTITION_FILTER_data_5G_sfr_erc}
    )
),

main_huawei AS (
    SELECT
        `tstamp`,
        `date_jour`,
        `cellname`,
        `operateur`,
        `frequency_band`,
        `vendor`,
        `crozon`,
        `_5g_trafic_pdcp_ul_cell`            AS `trafic_pdcp_ul_mo`,
        `_5g_trafic_pdcp_dl_cell_hua_nr`     AS `trafic_pdcp_dl_mo`,
        `_5g_trafic_pdcp_dl_cell_hua_x2_lte` AS `trafic_pdcp_dl_mo_x2_lte`,
        COALESCE(`rlc_nsa_dl_qci6_mo`, 0) + COALESCE(`rlc_sa_dl_5qi_6`, 0) AS `trafic_data_qci_6`,
        COALESCE(`rlc_nsa_dl_qci7_mo`, 0) + COALESCE(`rlc_sa_dl_5qi_7`, 0) AS `trafic_data_qci_7`,
        COALESCE(`rlc_nsa_dl_qci8_mo`, 0) + COALESCE(`rlc_sa_dl_5qi_8`, 0) AS `trafic_data_qci_8`,
        COALESCE(`rlc_nsa_dl_qci9_mo`, 0) + COALESCE(`rlc_sa_dl_5qi_9`, 0) AS `trafic_data_qci_9`,
        `_5g_trafic_dl_mac_sdu`              AS `trafic_mac_dl_mo`,
        `_5g_trafic_ul_cell_mac_sdu_mb_`     AS `trafic_mac_ul_mo`
    FROM (
        SELECT * FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_5g_hua`
        WHERE ${DKU_PARTITION_FILTER_data_5G_hua}
        UNION ALL
        SELECT * FROM `btel-data-lab-trb-ingeradio.datalab.TRB_IND_data_5g_sfr_hua`
        WHERE ${DKU_PARTITION_FILTER_data_5G_sfr_hua}
    )
),

src AS (
    SELECT * FROM main_ericsson
    UNION ALL
    SELECT * FROM main_huawei
),

dim AS (
    SELECT *
    FROM `btel-data-lab-trb-ingeradio.prod.dim_histo_kpi_hr_5g_byt`
    WHERE ${DKU_PARTITION_FILTER_dim_histo_kpi_hr_5g_byt}
)

--end of CTE's definition
--main query beginning

SELECT
    COALESCE(src.`tstamp`,dim.`date_heure`) AS `dat_tstm`,
    COALESCE(src.`date_jour`,dim.`date_jour`)  AS `date_jour`,
    COALESCE(src.`cellname`,dim.`cellname`)   AS `cellname`,

    COALESCE(
        src.`operateur`,
        CASE WHEN RIGHT(dim.`cellname`, 1) IN ('N','O','P','Q','R') THEN 'SFR' ELSE 'BYTEL' END
    ) AS `operateur_kalix`,

    COALESCE(
        src.`frequency_band`,
        CASE LEFT(dim.`cellname`, 1)
            WHEN 'Y' THEN 'NR2100'
            WHEN 'Q' THEN 'NR3500'
            WHEN 'J' THEN 'NR26000'
        END
    ) AS `frequency_band_kalix`,

    COALESCE(
        src.`vendor`,
        CASE
            WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
            WHEN dim.`constructeur` = 'HUAWEI'   THEN 'Huawei'
        END
    ) AS `vendor_kalix`,

    src.`crozon` AS `crozon_kalix`, -- '1' = Crozon, ('0' and 'ransharing'='false') = ZTD

    -- Trafic PDCP DL/UL
    COALESCE(src.`trafic_pdcp_ul_mo`,
             COALESCE(dim.`trafic_pdcp_ul_5g_nsa`, 0) + COALESCE(dim.`trafic_pdcp_ul_5g_sa`, 0)) AS `trafic_pdcp_ul_mo`,
    COALESCE(src.`trafic_pdcp_dl_mo`,
             COALESCE(dim.`trafic_pdcp_dl_5g_nsa`, 0) + COALESCE(dim.`trafic_pdcp_dl_5g_sa`, 0)) AS `trafic_pdcp_dl_mo`,
    COALESCE(src.`trafic_pdcp_dl_mo_x2_lte`, dim.`trafic_pdcp_dl_4g`) AS `trafic_pdcp_dl_mo_x2_lte`,

    -- Trafic data par QCI (fallback dim conditionné au constructeur)
    COALESCE(src.`trafic_data_qci_6`,
             CASE WHEN dim.`constructeur` = 'HUAWEI' THEN dim.`trafic_5g_ca_dl_qci_6` END) AS `trafic_data_qci_6`,
    COALESCE(src.`trafic_data_qci_7`,
             CASE WHEN dim.`constructeur` = 'HUAWEI' THEN dim.`trafic_5g_ca_dl_qci_7` END) AS `trafic_data_qci_7`,
    COALESCE(src.`trafic_data_qci_8`,
             CASE WHEN dim.`constructeur` = 'HUAWEI' THEN dim.`trafic_5g_ca_dl_qci_8` END) AS `trafic_data_qci_8`,
    COALESCE(src.`trafic_data_qci_9`,
             CASE
                 WHEN dim.`constructeur` = 'HUAWEI'   THEN dim.`trafic_5g_ca_dl_qci_9`
                 WHEN dim.`constructeur` = 'ERICSSON' THEN 0.97 * dim.`trafic_5g_ca_dl_qci_9` -- dim.trafic_5g_ca_dl_qci_9 is MAC, we estimate PDCP
             END) AS `trafic_data_qci_9`,

    -- Trafic MAC DL/UL
    COALESCE(src.`trafic_mac_dl_mo`, dim.`trafic_5g_ca_dl`) AS `trafic_mac_dl_mo`,
    COALESCE(src.`trafic_mac_ul_mo`, dim.`trafic_cell_ul`)  AS `trafic_mac_ul_mo`,

    -- KPIs complémentaires (secondary uniquement)
    dim.`occupation_prb_dl`     AS `taux_usage_prb_dl`,
    dim.`nbr_ue_connected_nsa`  AS `nb_ue_connectes_nsa`,
    dim.`nbr_ue_connected_sa`   AS `nb_ue_connectes_sa`,
    dim.`nbr_ue_actifs_dl`      AS `nb_ue_actifs`,
    dim.`occupation_cce`        AS `charge_cce`,

    -- Origine des données
    CASE
        WHEN COALESCE(src.`vendor`,
                 CASE WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
                      WHEN dim.`constructeur` = 'HUAWEI'   THEN 'Huawei' END) = 'Ericsson' THEN 'byt_eri'
        WHEN COALESCE(src.`vendor`,
                 CASE WHEN dim.`constructeur` = 'ERICSSON' THEN 'Ericsson'
                      WHEN dim.`constructeur` = 'HUAWEI'   THEN 'Huawei' END) = 'Huawei'   THEN 'byt_hua'
        ELSE NULL
    END AS `source`

FROM src
FULL JOIN dim
    ON  src.`tstamp`    = dim.`date_heure`
    AND src.`cellname`  = dim.`cellname`
    AND src.`date_jour` = dim.`date_jour`
;
