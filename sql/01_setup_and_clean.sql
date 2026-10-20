-- ============================================================
-- 01_setup_and_clean.sql
-- 建表、匯入、清理（MySQL 8.0）
-- 資料：data/gym_2025.csv（自行生成的模擬資料）
-- ============================================================

CREATE DATABASE IF NOT EXISTS gym_ops CHARACTER SET utf8mb4;
USE gym_ops;

-- 1. 暫存表：全部欄位先以文字型態匯入，避免髒資料造成匯入失敗
DROP TABLE IF EXISTS raw_sales;
CREATE TABLE raw_sales (
  sale_date VARCHAR(20),
  store     VARCHAR(20),
  plan      VARCHAR(20),
  source    VARCHAR(20),
  promo     VARCHAR(5),
  inquiries VARCHAR(10),
  deals     VARCHAR(10),
  revenue   VARCHAR(20)
);

LOAD DATA INFILE '/var/lib/mysql-files/gym_2025.csv'
INTO TABLE raw_sales CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES;

SELECT COUNT(*) AS raw_rows FROM raw_sales;            -- 2,450

-- 2. 資料品質檢查
SELECT DISTINCT store FROM raw_sales;                    -- 門市名稱有幾種寫法？
SELECT * FROM raw_sales WHERE inquiries NOT REGEXP '^[0-9]+$';  -- 諮詢數不是數字
SELECT * FROM raw_sales WHERE deals = '' OR revenue = '';       -- 空值
SELECT sale_date, store, plan, source, COUNT(*) AS c
FROM raw_sales
GROUP BY sale_date, store, plan, source, promo, inquiries, deals, revenue
HAVING c > 1;                                            -- 完全重複的列

-- 3. 清理後寫入正式表
DROP TABLE IF EXISTS sales;
CREATE TABLE sales AS
SELECT DISTINCT
  CAST(sale_date AS DATE)            AS sale_date,
  TRIM(store)                        AS store,      -- 去除多餘空白
  plan,
  source,
  promo,
  CAST(inquiries AS UNSIGNED)        AS inquiries,
  CAST(deals AS UNSIGNED)            AS deals,
  CAST(NULLIF(revenue,'') AS UNSIGNED) AS revenue   -- 空白營收保留為 NULL
FROM raw_sales
WHERE inquiries REGEXP '^[0-9]+$'    -- 排除無法判讀的諮詢數
  AND deals <> '';                   -- 排除成交數空白（無法計算成交率）

SELECT COUNT(*) AS clean_rows FROM sales;              -- 2,446

-- 清理紀錄
-- 原始 2,450 筆 → 清理後 2,446 筆
-- ・門市名稱多出空白 1 筆（"A店 "）→ TRIM 修正，保留
-- ・諮詢數為中文「三」1 筆 → 排除（無法確認原始數值）
-- ・成交數空白 1 筆 → 排除
-- ・營收空白 1 筆 → 保留，營收設為 NULL（不影響成交率計算）
-- ・完全重複 2 筆 → DISTINCT 去除
