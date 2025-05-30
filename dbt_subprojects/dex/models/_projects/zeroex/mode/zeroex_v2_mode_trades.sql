{{  config(
    schema = 'zeroex_v2_mode',
    alias = 'trades',
    materialized='incremental',
    partition_by = ['block_month'],
    unique_key = ['block_month', 'block_date', 'tx_hash', 'evt_index'],
    on_schema_change='sync_all_columns',
    file_format ='delta',
    incremental_strategy='merge',
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')]
)}}

{% set zeroex_settler_start_date = '2024-07-15' %}
{% set blockchain = 'mode' %}

WITH zeroex_tx AS (
    {{
        zeroex_settler_txs_cte(
            blockchain = blockchain,
            start_date = zeroex_settler_start_date
        )
    }}
),
zeroex_v2_trades AS (
    {{
        zeroex_v2_trades(
            blockchain = blockchain,
            start_date = zeroex_settler_start_date
            
        )
    }}
),

trade_details as (
    {{
        zeroex_v2_trades_detail(
            blockchain = blockchain,
            start_date = zeroex_settler_start_date
            
        )
    }}

)
select 
    *
 from trade_details 
