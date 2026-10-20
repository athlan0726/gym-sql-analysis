-- ============================================================
-- 02_analysis.sql
-- 找異常 → 定位 → 排除干擾 → 驗證假設 → 估算影響
-- KPI：成交率 = 成交數 / 諮詢數（以加總後相除，避免小樣本日權重失真）
-- ============================================================
USE gym_ops;

-- ---------- A. 發現問題 ----------

-- A1. 每店每月成交率
SELECT store,
       DATE_FORMAT(sale_date,'%Y-%m')     AS ym,
       SUM(inquiries)                     AS inquiries,
       SUM(deals)                         AS deals,
       ROUND(SUM(deals)/SUM(inquiries),2) AS close_rate
FROM sales
GROUP BY store, ym
ORDER BY store, ym;

-- A2. 自動偵測異常：成交率低於「該店無活動月份平均」30% 以上
--     基準只用無活動月份，避免活動月份把平均拉高、造成誤判
WITH m AS (
  SELECT store, DATE_FORMAT(sale_date,'%Y-%m') AS ym, MAX(promo) AS promo,
         SUM(deals)/SUM(inquiries) AS rate
  FROM sales GROUP BY store, ym
), base AS (
  SELECT store, AVG(rate) AS base_rate FROM m WHERE promo = 'N' GROUP BY store
)
SELECT m.store, m.ym, ROUND(m.rate,2) AS rate, ROUND(base.base_rate,2) AS base_rate
FROM m JOIN base USING (store)
WHERE m.rate < base.base_rate * 0.7;
-- 結果：B店 2025-08、2025-09

-- ---------- B. 定位問題 ----------

-- B1. 異常月份依方案 × 來源拆解
SELECT plan, source,
       SUM(inquiries)                     AS inquiries,
       ROUND(SUM(deals)/SUM(inquiries),2) AS close_rate
FROM sales
WHERE store LIKE 'B%'
  AND DATE_FORMAT(sale_date,'%Y-%m') IN ('2025-08','2025-09')
GROUP BY plan, source
ORDER BY close_rate;
-- 結果：教練課 10 堂、30 堂都大跌；陌生客（FB私訊、路過）0.02–0.08；月費會員正常

-- B2. 對照組：同期間 A店的教練課是否也下跌？
--     若兩店都跌 → 公司層級問題（價格、政策）；只有 B店 → 門市層級問題
SELECT store,
       DATE_FORMAT(sale_date,'%Y-%m')     AS ym,
       ROUND(SUM(deals)/SUM(inquiries),2) AS coach_close_rate
FROM sales
WHERE plan LIKE '%0%'                       -- 教練課10堂／30堂（方案名稱含數字 0）
GROUP BY store, ym
ORDER BY ym, store;
-- 結果：A店 8–9 月 0.41、0.42 正常 → 問題只在 B店

-- ---------- C. 排除干擾 ----------

-- C1. 活動對成交率的影響
SELECT promo, ROUND(SUM(deals)/SUM(inquiries),2) AS close_rate
FROM sales GROUP BY promo;
-- 結果：有活動 0.52、無活動 0.39

-- C2. 公平比較：只看無活動期間，並排除異常月份
SELECT store,
       ROUND(SUM(deals)/SUM(inquiries),2) AS close_rate_no_promo,
       ROUND(SUM(CASE WHEN DATE_FORMAT(sale_date,'%Y-%m') NOT IN ('2025-08','2025-09')
                      THEN deals END)
           / SUM(CASE WHEN DATE_FORMAT(sale_date,'%Y-%m') NOT IN ('2025-08','2025-09')
                      THEN inquiries END),2) AS excl_anomaly
FROM sales
WHERE promo = 'N'
GROUP BY store;
-- 結果：A店 0.40 → 排除 8–9 月 0.39；B店 0.38 → 排除 8–9 月 0.42 → B店平常並不比 A店差

-- ---------- D. 驗證假設 ----------

-- D1. 假設：7 月活動提前消化需求 → 若成立，8–9 月諮詢數應明顯下降
SELECT DATE_FORMAT(sale_date,'%Y-%m') AS ym,
       SUM(inquiries)                 AS inquiries,
       SUM(deals)                     AS deals
FROM sales
WHERE store LIKE 'B%' AND plan LIKE '%0%'
GROUP BY ym
ORDER BY ym;
-- 結果：8 月諮詢 372，高於 3–6 月（212–283）→ 假設不成立
--       問題是「來了卻沒成交」，指向教練人力、排班或時段媒合

-- ---------- E. 估算影響 ----------

-- E1. 若 8–9 月維持 B店無活動月份的正常成交率，少了多少成交與營收？
WITH base AS (               -- B店教練課正常成交率（無活動、排除異常月份）
  SELECT plan, SUM(deals)/SUM(inquiries) AS base_rate
  FROM sales
  WHERE store LIKE 'B%' AND plan LIKE '%0%' AND promo = 'N'
    AND DATE_FORMAT(sale_date,'%Y-%m') NOT IN ('2025-08','2025-09')
  GROUP BY plan
), price AS (                -- 每筆成交平均金額
  SELECT plan, SUM(revenue)/SUM(deals) AS avg_price
  FROM sales
  WHERE plan LIKE '%0%' AND revenue IS NOT NULL AND deals > 0
  GROUP BY plan
), anomaly AS (
  SELECT plan, SUM(inquiries) AS inquiries, SUM(deals) AS deals
  FROM sales
  WHERE store LIKE 'B%' AND plan LIKE '%0%'
    AND DATE_FORMAT(sale_date,'%Y-%m') IN ('2025-08','2025-09')
  GROUP BY plan
)
SELECT a.plan,
       a.inquiries,
       a.deals                                         AS actual_deals,
       ROUND(a.inquiries * b.base_rate)                AS expected_deals,
       ROUND(a.inquiries * b.base_rate) - a.deals      AS lost_deals,
       (ROUND(a.inquiries * b.base_rate) - a.deals) * ROUND(p.avg_price) AS est_lost_revenue
FROM anomaly a
JOIN base  b USING (plan)
JOIN price p USING (plan);
-- 結果：少成交約 164 筆，估計營收損失約 326 萬（模擬資料）
