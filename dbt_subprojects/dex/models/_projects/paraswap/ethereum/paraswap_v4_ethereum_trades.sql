{{ config(
    schema = 'paraswap_v4_ethereum',
    alias = 'trades',

    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
    unique_key = ['block_date', 'blockchain', 'project', 'version', 'tx_hash', 'evt_index', 'trace_address'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "paraswap_v4",
                                \'["springzh"]\') }}'
    )
}}

{% set project_start_date = '2021-04-04' %}
{% set trade_event_tables = [
    source('paraswap_ethereum', 'AugustusSwapper5_0_evt_Bought')
    ,source('paraswap_ethereum', 'AugustusSwapper5_0_evt_Swapped')
] %}
{% set trade_call_start_block_number = 12180078 %}
{% set trade_call_tables = [
    source('paraswap_ethereum', 'AugustusSwapper5_0_call_buyOnUniswap')
    ,source('paraswap_ethereum', 'AugustusSwapper5_0_call_buyOnUniswapFork')
    ,source('paraswap_ethereum', 'AugustusSwapper5_0_call_swapOnUniswap')
    ,source('paraswap_ethereum', 'AugustusSwapper5_0_call_swapOnUniswapFork')
] %}

/**
    Note: Used try_cast instead of cast to avoid throwing an overflow error on the special transaction.
    Example: https://etherscan.io/tx/0x2db75d6401a39cb72a0a38e0a0cfd46117def1a6dae7d411c9ed5e5e211ab8cf
**/
WITH dex_swap AS (
    {% for trade_table in trade_event_tables %}
        SELECT
            evt_block_time AS block_time,
            evt_block_number AS block_number,
            beneficiary AS taker,
            initiator AS maker,
            receivedAmount AS token_bought_amount_raw,
            srcAmount AS token_sold_amount_raw,
            CAST(NULL AS double) AS amount_usd,
            CASE
                WHEN destToken = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
                THEN 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 -- WETH
                ELSE destToken
            END AS token_bought_address,
            CASE
                WHEN srcToken = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
                THEN 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 -- WETH
                ELSE srcToken
            END AS token_sold_address,
            contract_address AS project_contract_address,
            evt_tx_hash AS tx_hash,
            CAST(ARRAY[-1] as array<bigint>) AS trace_address,
            evt_index
        FROM {{ trade_table }} p
        {% if is_incremental() %}
        WHERE {{ incremental_predicate('p.evt_block_time') }}
        {% endif %}
        {% if not loop.last %}
        UNION ALL
        {% endif %}
    {% endfor %}
),

call_swap_without_event AS (
    WITH no_event_call_transaction AS (
        {% for call_table in trade_call_tables %}
            SELECT c.call_tx_hash,
            c.call_block_number,
            (case when tx.value > 0 then true else false end) as is_eth,
            tx."from"
            FROM {{ call_table }} c
            INNER JOIN {{ source('ethereum', 'transactions') }} tx ON c.call_block_number = tx.block_number
                AND c.call_tx_hash = tx.hash
                AND tx.block_number >= {{ trade_call_start_block_number }}
                {% if is_incremental() %}
                AND {{ incremental_predicate('tx.block_time') }}
                {% endif %}
                {% if not is_incremental() %}
                AND tx.block_time >= TIMESTAMP '{{project_start_date}}'
                {% endif %}
            WHERE c.call_success = true
            {% if is_incremental() %}
            AND {{ incremental_predicate('c.call_block_time') }}
            {% endif %}
            {% if not loop.last %}
            UNION -- There may be multiple calls in same tx
            {% endif %}
        {% endfor %}
    ),

    swap_detail_in AS (
        SELECT tx_hash,
            block_number,
            block_time,
            user_address,
            tokenIn,
            amountIn,
            trace_address,
            evt_index
        FROM (
            SELECT t.evt_tx_hash AS tx_hash,
                t.evt_block_number AS block_number,
                t.evt_block_time AS block_time,
                t."from" AS user_address,
                t.contract_address AS tokenIn,
                try_cast(t.value AS int256) AS amountIn,
                CAST(ARRAY[-1] as array<bigint>) AS trace_address,
                t.evt_index,
                row_number() over (partition by t.evt_tx_hash order by t.evt_index) as row_num
            FROM no_event_call_transaction c
            INNER JOIN {{ source('erc20_ethereum','evt_Transfer') }} t ON c.call_block_number = t.evt_block_number
                AND c.call_tx_hash = t.evt_tx_hash
                AND t."from" = c."from"
                AND t.evt_block_number >= {{ trade_call_start_block_number }}
                {% if is_incremental() %}
                AND {{ incremental_predicate('t.evt_block_time') }}
                {% endif %}
                {% if not is_incremental() %}
                AND t.evt_block_time >= TIMESTAMP '{{project_start_date}}'
                {% endif %}
            where c.is_eth = false -- Swap ERC20 to other token
        ) t
        WHERE row_num = 1 -- Only use the first input row

        UNION ALL

        -- There can be some transferred in ETH return back to user after swap. Positive Slippage
        SELECT t.tx_hash,
            t.block_number,
            t.block_time,
            c."from" AS user_address,
            0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 AS tokenIn, -- WETH
            SUM(case
                when t."from" = c."from" then try_cast(t.value AS int256)
                else -1 * try_cast(t.value AS int256)
            end) AS amountIn,
            MAX(t.trace_address) AS trace_address,
            CAST(-1 as integer) AS evt_index
        FROM no_event_call_transaction c
        INNER JOIN {{ source('ethereum', 'traces') }} t ON c.call_block_number = t.block_number
            AND c.call_tx_hash = t.tx_hash
            AND (t."from" = c."from" or t."to" = c."from")
            AND t.block_number >= {{ trade_call_start_block_number }}
            AND t.call_type = 'call'
            AND t.value > uint256 '0'
            {% if is_incremental() %}
            AND {{ incremental_predicate('t.block_time') }}
            {% endif %}
            {% if not is_incremental() %}
            AND t.block_time >= TIMESTAMP '{{project_start_date}}'
            {% endif %}
        where c.is_eth -- Swap ETH to other token
        GROUP BY 1, 2, 3, 4
    ),

    swap_detail_out AS (
        SELECT tx_hash,
            block_number,
            block_time,
            user_address,
            tokenOut,
            amountOut,
            trace_address,
            evt_index
        FROM (
            SELECT t.evt_tx_hash AS tx_hash,
                t.evt_block_number AS block_number,
                t.evt_block_time AS block_time,
                t."to" AS user_address,
                t.contract_address AS tokenOut,
                try_cast(t.value AS int256) AS amountOut,
                CAST(ARRAY[-1] as array<bigint>) AS trace_address,
                t.evt_index,
                row_number() over (partition by t.evt_tx_hash order by t.evt_index) AS row_num
            FROM no_event_call_transaction c
            INNER JOIN {{ source('erc20_ethereum','evt_Transfer') }} t ON c.call_block_number = t.evt_block_number
                AND c.call_tx_hash = t.evt_tx_hash
                AND t."to" = c."from"
                AND t.evt_block_number >= {{ trade_call_start_block_number }}
                {% if is_incremental() %}
                AND {{ incremental_predicate('t.evt_block_time') }}
                {% endif %}
                {% if not is_incremental() %}
                AND t.evt_block_time >= TIMESTAMP '{{project_start_date}}'
                {% endif %}
            where c.is_eth = false -- Swap ERC20 to other token
        ) t
        WHERE row_num = 1

        UNION ALL

        SELECT t.tx_hash,
            t.block_number,
            t.block_time,
            t."to" AS user_address,
            0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 AS tokenOut, -- WETH
            try_cast(t.value AS int256) AS amountOut,
            t.trace_address,
            CAST(-1 as integer) AS evt_index
        FROM no_event_call_transaction c
        INNER JOIN {{ source('ethereum', 'traces') }} t ON c.call_block_number = t.block_number
            AND c.call_tx_hash = t.tx_hash
            AND t."to" = c."from"
            AND t.block_number >= {{ trade_call_start_block_number }}
            AND t.call_type = 'call'
            AND t.value > uint256 '0'
            {% if is_incremental() %}
            AND {{ incremental_predicate('t.block_time') }}
            {% endif %}
            {% if not is_incremental() %}
            AND t.block_time >= TIMESTAMP '{{project_start_date}}'
            {% endif %}
        where c.is_eth = false -- Swap ERC20 to ETH
    )

    SELECT i.block_time,
        i.block_number,
        i.user_address AS taker,
        i.user_address AS maker,
        CAST(o.amountOut as uint256) AS token_bought_amount_raw,
        CAST(i.amountIn as uint256) AS token_sold_amount_raw,
        CAST(NULL AS double) AS amount_usd,
        o.tokenOut AS token_bought_address,
        i.tokenIn AS token_sold_address,
        0x1bd435f3c054b6e901b7b108a0ab7617c808677b AS project_contract_address,
        i.tx_hash,
        greatest(i.trace_address, o.trace_address) AS trace_address,
        greatest(i.evt_index, o.evt_index) AS evt_index
    FROM swap_detail_in i
    INNER JOIN swap_detail_out o ON i.block_number = o.block_number AND i.tx_hash = o.tx_hash
),

dexs AS (
    SELECT block_time,
        block_number,
        taker,
        maker,
        token_bought_amount_raw,
        token_sold_amount_raw,
        amount_usd,
        token_bought_address,
        token_sold_address,
        project_contract_address,
        tx_hash,
        trace_address,
        evt_index
    FROM dex_swap

    UNION ALL

    SELECT c.block_time,
        c.block_number,
        c.taker,
        c.maker,
        c.token_bought_amount_raw,
        c.token_sold_amount_raw,
        c.amount_usd,
        c.token_bought_address,
        c.token_sold_address,
        c.project_contract_address,
        c.tx_hash,
        c.trace_address,
        c.evt_index
    FROM call_swap_without_event c
    LEFT JOIN dex_swap d ON c.block_number = d.block_number AND c.tx_hash = d.tx_hash
    WHERE d.tx_hash IS NULL
)

SELECT 'ethereum' AS blockchain,
    'paraswap' AS project,
    '4' AS version,
    cast(date_trunc('day', d.block_time) as date) as block_date,
    cast(date_trunc('month', d.block_time) as date) as block_month,
    d.block_time,
    e1.symbol AS token_bought_symbol,
    e2.symbol AS token_sold_symbol,
    CASE
        WHEN lower(e1.symbol) > lower(e2.symbol) THEN concat(e2.symbol, '-', e1.symbol)
        ELSE concat(e1.symbol, '-', e2.symbol)
    END AS token_pair,
    d.token_bought_amount_raw / power(10, e1.decimals) AS token_bought_amount,
    d.token_sold_amount_raw / power(10, e2.decimals) AS token_sold_amount,
    d.token_bought_amount_raw,
    d.token_sold_amount_raw,
    coalesce(
        d.amount_usd
        ,(d.token_bought_amount_raw / power(10, p1.decimals)) * p1.price
        ,(d.token_sold_amount_raw / power(10, p2.decimals)) * p2.price
    ) AS amount_usd,
    d.token_bought_address,
    d.token_sold_address,
    coalesce(d.taker, tx."from") AS taker,
    d.maker,
    d.project_contract_address,
    d.tx_hash,
    tx."from" AS tx_from,
    tx.to AS tx_to,
    d.trace_address,
    d.evt_index
FROM dexs d
INNER JOIN {{ source('ethereum', 'transactions') }} tx ON d.tx_hash = tx.hash
    AND d.block_number = tx.block_number
    {% if not is_incremental() %}
    AND tx.block_time >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('tx.block_time') }}
    {% endif %}
LEFT JOIN {{ source('tokens', 'erc20') }} e1 ON e1.contract_address = d.token_bought_address
    AND e1.blockchain = 'ethereum'
LEFT JOIN {{ source('tokens', 'erc20') }} e2 on e2.contract_address = d.token_sold_address
    AND e2.blockchain = 'ethereum'
LEFT JOIN {{ source('prices', 'usd') }} p1 ON p1.minute = date_trunc('minute', d.block_time)
    AND p1.contract_address = d.token_bought_address
    AND p1.blockchain = 'ethereum'
    {% if not is_incremental() %}
    AND p1.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('p1.minute') }}
    {% endif %}
LEFT JOIN {{ source('prices', 'usd') }} p2 ON p2.minute = date_trunc('minute', d.block_time)
    AND p2.contract_address = d.token_sold_address
    AND p2.blockchain = 'ethereum'
    {% if not is_incremental() %}
    AND p2.minute >= TIMESTAMP '{{project_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND {{ incremental_predicate('p2.minute') }}
    {% endif %}
