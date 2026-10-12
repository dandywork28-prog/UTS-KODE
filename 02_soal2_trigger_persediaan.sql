-- =====================================================================
-- UTS Pemrograman / Coding - Dandy Rizkiansah (12030124130135)
-- SOAL 2: Trigger persediaan perpetual + jurnal otomatis
-- Prasyarat: 01_soal1_skema_gl.sql sudah dijalankan
-- =====================================================================

-- 1. Struktur tabel sesuai naskah soal ---------------------------------
CREATE TABLE inventory_items (
    item_id    VARCHAR(10)   PRIMARY KEY,
    item_name  VARCHAR(100),
    stock_qty  INT           NOT NULL DEFAULT 0,
    unit_cost  NUMERIC(15,2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id    SERIAL PRIMARY KEY,
    item_id   VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type  VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Pengaman tambahan (defense in depth) ------------------------------
ALTER TABLE inventory_items
    ADD CONSTRAINT chk_stock_nonnegative CHECK (stock_qty >= 0);

-- kolom penaut ke jurnal yang dibentuk otomatis
ALTER TABLE inventory_transactions
    ADD COLUMN journal_id INTEGER REFERENCES journal_headers(id) ON DELETE RESTRICT;

-- 3. Trigger function --------------------------------------------------
-- Aturan qty:
--   PURCHASE & SALE : qty harus > 0
--   ADJUSTMENT      : qty bertanda (+ menambah stok, - mengurangi stok), tidak boleh 0
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock     INT;
    v_cost      NUMERIC(15,2);
    v_delta     INT;
    v_amount    NUMERIC(15,2);
    v_header_id INTEGER;
    v_acc_inv   INTEGER;
    v_acc_cash  INTEGER;
    v_acc_cogs  INTEGER;
    v_acc_diff  INTEGER;
    v_dr        INTEGER;
    v_cr        INTEGER;
BEGIN
    -- (a) validasi kuantitas
    IF NEW.trx_type IN ('PURCHASE', 'SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty % untuk transaksi % harus lebih besar dari 0.', NEW.qty, NEW.trx_type;
    END IF;
    IF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'Qty ADJUSTMENT tidak boleh 0.';
    END IF;

    -- (b) kunci baris barang: transaksi lain pada item sama harus antre
    SELECT stock_qty, unit_cost
      INTO v_stock, v_cost
      FROM inventory_items
     WHERE item_id = NEW.item_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % tidak ditemukan.', NEW.item_id;
    END IF;

    -- (c) hitung perubahan stok
    v_delta := CASE NEW.trx_type
                   WHEN 'PURCHASE' THEN  NEW.qty
                   WHEN 'SALE'     THEN -NEW.qty
                   ELSE                  NEW.qty      -- ADJUSTMENT (bertanda)
               END;

    -- (d) anti-negative inventory
    IF v_stock + v_delta < 0 THEN
        RAISE EXCEPTION
            'Stok % tidak cukup: tersedia %, diminta keluar %.',
            NEW.item_id, v_stock, ABS(v_delta)
            USING ERRCODE = '23514';
    END IF;

    -- (e) mutakhirkan stok
    UPDATE inventory_items
       SET stock_qty = stock_qty + v_delta
     WHERE item_id = NEW.item_id;

    -- (f) jurnal otomatis ke buku besar (nilai = qty x unit_cost)
    v_amount := ABS(v_delta) * v_cost;

    IF v_amount > 0 THEN
        SELECT account_id INTO v_acc_inv  FROM chart_of_accounts WHERE account_code = '1-1300';
        SELECT account_id INTO v_acc_cash FROM chart_of_accounts WHERE account_code = '1-1100';
        SELECT account_id INTO v_acc_cogs FROM chart_of_accounts WHERE account_code = '5-1000';
        SELECT account_id INTO v_acc_diff FROM chart_of_accounts WHERE account_code = '5-2000';

        IF v_acc_inv IS NULL OR v_acc_cash IS NULL OR v_acc_cogs IS NULL OR v_acc_diff IS NULL THEN
            RAISE EXCEPTION 'Akun persediaan/kas/HPP/selisih belum ada di chart_of_accounts.';
        END IF;

        IF NEW.trx_type = 'PURCHASE' THEN          -- Dr Persediaan  / Cr Kas
            v_dr := v_acc_inv;  v_cr := v_acc_cash;
        ELSIF NEW.trx_type = 'SALE' THEN           -- Dr HPP         / Cr Persediaan
            v_dr := v_acc_cogs; v_cr := v_acc_inv;
        ELSIF v_delta > 0 THEN                     -- Dr Persediaan  / Cr Selisih
            v_dr := v_acc_inv;  v_cr := v_acc_diff;
        ELSE                                       -- Dr Selisih     / Cr Persediaan
            v_dr := v_acc_diff; v_cr := v_acc_inv;
        END IF;

        INSERT INTO journal_headers (transaction_date, reference_number, description)
        VALUES (NEW.trx_date::date,
                'INV-' || NEW.trx_id,
                format('Mutasi persediaan %s item %s qty %s', NEW.trx_type, NEW.item_id, NEW.qty))
        RETURNING id INTO v_header_id;

        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        VALUES (v_header_id, v_dr, v_amount, 0),
               (v_header_id, v_cr, 0, v_amount);

        UPDATE journal_headers SET status_posting = 'POSTED' WHERE id = v_header_id;

        NEW.journal_id := v_header_id;
    END IF;

    RETURN NEW;
END;
$$;

-- 4. Pasang trigger ----------------------------------------------------
DROP TRIGGER IF EXISTS trg_update_stock_and_journal ON inventory_transactions;

CREATE TRIGGER trg_update_stock_and_journal
BEFORE INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION trg_update_stock_and_journal();

-- 5. Data master barang ------------------------------------------------
INSERT INTO inventory_items (item_id, item_name, stock_qty, unit_cost) VALUES
 ('ITM-001', 'Kertas A4 80gsm (rim)', 0,  45000),
 ('ITM-002', 'Tinta Printer Hitam',   0, 120000);
