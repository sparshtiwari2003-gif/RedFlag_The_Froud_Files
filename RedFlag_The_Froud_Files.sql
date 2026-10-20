USE redflag;

CREATE INDEX idx_user_status_amount
    ON transactions (user_id, status, amount);

SELECT
    user_id,
    DATE(txn_time) AS attack_date,
    COUNT(*)       AS daily_txn_count
FROM transactions
GROUP BY user_id, DATE(txn_time)
HAVING COUNT(*) >= 30
ORDER BY daily_txn_count DESC, user_id;
SELECT
    user_id,
    COUNT(*)    AS round_txn_count,
    SUM(amount) AS round_amount_total
FROM transactions
WHERE amount IN (100, 200, 500, 1000, 2000, 5000, 10000)
GROUP BY user_id
HAVING COUNT(*) >= 15
ORDER BY round_txn_count DESC, user_id;

SELECT
    user_id,
    DATE(txn_time) AS test_date,
    COUNT(*)       AS tiny_txn_count
FROM transactions
WHERE amount < 10
GROUP BY user_id, DATE(txn_time)
HAVING COUNT(*) >= 30
ORDER BY tiny_txn_count DESC, user_id;

SELECT
    f.user_id,
    COUNT(*) AS failed_then_success_pairs
FROM transactions AS f
JOIN transactions AS s
      ON  s.user_id  = f.user_id
      AND s.status   = 'SUCCESS'
      AND s.amount   = f.amount
      AND s.txn_time > f.txn_time
      AND TIMESTAMPDIFF(SECOND, f.txn_time, s.txn_time) <= 120
WHERE f.status = 'FAILED'
GROUP BY f.user_id
HAVING COUNT(*) >= 20
ORDER BY failed_then_success_pairs DESC, f.user_id;
SELECT
    user_id,
    COUNT(*) AS total_txns,
    SUM(CASE WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1 ELSE 0 END) AS odd_hour_txns,
    ROUND(100 * SUM(CASE WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS odd_hour_pct
FROM transactions
GROUP BY user_id
HAVING COUNT(*) >= 30
   AND SUM(CASE WHEN HOUR(txn_time) BETWEEN 2 AND 4 THEN 1 ELSE 0 END)
       / COUNT(*) >= 0.8
ORDER BY odd_hour_pct DESC, total_txns DESC;

SELECT
    c.user_id,
    COUNT(*)      AS quick_passthrough_credits,
    SUM(c.amount) AS total_credited
FROM transactions AS c
WHERE c.txn_type = 'CREDIT'
  AND EXISTS (
        SELECT 1
        FROM transactions AS d
        WHERE d.user_id  = c.user_id
          AND d.txn_type = 'DEBIT'
          AND d.txn_time >  c.txn_time
          AND d.txn_time <= c.txn_time + INTERVAL 30 MINUTE
          AND d.amount   >= 0.7 * c.amount
  )
GROUP BY c.user_id
HAVING COUNT(*) >= 5
ORDER BY quick_passthrough_credits DESC, c.user_id;

SELECT
    user_id,
    COUNT(*) AS total_txns,
    SUM(CASE WHEN txn_type = 'REFUND' THEN 1 ELSE 0 END) AS refund_txns,
    ROUND(100 * SUM(CASE WHEN txn_type = 'REFUND' THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS refund_pct
FROM transactions
GROUP BY user_id
HAVING COUNT(*) >= 20
   AND SUM(CASE WHEN txn_type = 'REFUND' THEN 1 ELSE 0 END) / COUNT(*) > 0.4
ORDER BY refund_pct DESC, total_txns DESC;

WITH merchant_user_value AS (
    SELECT
        merchant_id,
        user_id,
        SUM(amount) AS user_value
    FROM transactions
    GROUP BY merchant_id, user_id
),
ranked AS (
    SELECT
        merchant_id,
        user_id,
        user_value,
        ROW_NUMBER() OVER (PARTITION BY merchant_id ORDER BY user_value DESC) AS user_rank,
        SUM(user_value) OVER (PARTITION BY merchant_id)                       AS merchant_total
    FROM merchant_user_value
)
SELECT
    merchant_id,
    ROUND(merchant_total, 2)                      AS merchant_total,
    ROUND(SUM(user_value), 2)                     AS top5_value,
    ROUND(100 * SUM(user_value) / merchant_total, 1) AS top5_share_pct
FROM ranked
WHERE user_rank <= 5
GROUP BY merchant_id, merchant_total
HAVING SUM(user_value) / merchant_total > 0.6
ORDER BY top5_share_pct DESC, merchant_id;

SELECT
    user_id,
    COUNT(*)    AS structuring_txns,
    SUM(amount) AS total_structured
FROM transactions
WHERE amount = 9999.00
GROUP BY user_id
HAVING COUNT(*) >= 10
ORDER BY structuring_txns DESC, user_id;

WITH gaps AS (
    SELECT
        user_id,
        txn_time AS resume_time,
        TIMESTAMPDIFF(
            DAY,
            LAG(txn_time) OVER (PARTITION BY user_id ORDER BY txn_time),
            txn_time
        ) AS dormant_days
    FROM transactions
)
SELECT
    g.user_id,
    g.resume_time,
    g.dormant_days,
    COUNT(DISTINCT t.txn_id) AS post_gap_txns
FROM gaps AS g
JOIN transactions AS t
      ON  t.user_id  = g.user_id
      AND t.txn_time >= g.resume_time
WHERE g.dormant_days >= 90
GROUP BY g.user_id, g.resume_time, g.dormant_days
HAVING COUNT(DISTINCT t.txn_id) >= 15
ORDER BY post_gap_txns DESC, g.user_id;

WITH monthly AS (
    SELECT
        user_id,
        DATE_FORMAT(txn_time, '%Y-%m') AS txn_month,
        COUNT(*) AS month_txns
    FROM transactions
    GROUP BY user_id, DATE_FORMAT(txn_time, '%Y-%m')
),
user_stats AS (
    SELECT
        user_id,
        MAX(month_txns)                          AS peak_month_txns,
        CAST(SUM(month_txns) AS DECIMAL(10,2)) / 6 AS avg_month_txns
    FROM monthly
    GROUP BY user_id
)
SELECT
    user_id,
    peak_month_txns,
    ROUND(avg_month_txns, 2)                    AS avg_month_txns,
    ROUND(peak_month_txns / avg_month_txns, 2)  AS spike_ratio
FROM user_stats
WHERE peak_month_txns >= 20
  AND peak_month_txns / avg_month_txns >= 5
ORDER BY spike_ratio DESC, peak_month_txns DESC, user_id;

WITH sequenced AS (
    SELECT
        user_id,
        txn_id,
        city,
        txn_time,
        LAG(city)     OVER w AS prev_city,
        LAG(txn_time) OVER w AS prev_time
    FROM transactions
    WINDOW w AS (PARTITION BY user_id ORDER BY txn_time)
)
SELECT
    user_id,
    COUNT(*)      AS impossible_hops,
    MIN(txn_time) AS first_hop_time
FROM sequenced
WHERE prev_city IS NOT NULL
  AND city <> prev_city
  AND TIMESTAMPDIFF(MINUTE, prev_time, txn_time) <= 60
GROUP BY user_id
HAVING COUNT(*) >= 5
ORDER BY impossible_hops DESC, user_id;