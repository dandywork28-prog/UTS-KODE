-- =====================================================================
-- UTS Pemrograman / Coding - Dandy Rizkiansah (12030124130135)
-- SKRIP UJI untuk bahan screenshot laporan.
-- PENTING: jalankan PER BLOK (blok yang diharapkan ERROR dijalankan sendiri-sendiri).
-- =====================================================================

-- ---------- [UJI 1] Constraint Soal 1 (harus ERROR, jalankan sendiri) ----------
-- 1a. Baris dengan debit = 0 dan kredit = 0  -> ditolak chk_jl_not_both_zero
-- (buat header DRAFT dulu)
INSERT INTO journal_headers (transaction_date, reference_number, description)
VALUES (CURRENT_DATE, 'TEST-001', 'Uji constraint');

INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT id, 1, 0, 0 FROM journal_headers WHERE reference_number = 'TEST-001';
-- ERROR: violates check constraint "chk_jl_not_both_zero"

-- 1b. Nominal negatif -> ditolak chk_jl_debit_nonneg
INSERT INTO journal_lines (header_id, account_id, debit, credit)
SELECT id, 1, -500, 0 FROM journal_headers WHERE reference_number = 'TEST-001';

-- 1c. Hapus akun yang sudah dipakai -> ditolak ON DELETE RESTRICT (jalankan setelah UJI 4)
-- DELETE FROM chart_of_accounts WHERE account_code = '1-1100';

-- ---------- [UJI 2] Trigger persediaan (Soal 2) ----------
-- 2a. Pembelian 5 unit (sukses, stok 0 -> 5, jurnal Dr Persediaan / Cr Kas otomatis)
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('ITM-001', 'PURCHASE', 5);

-- 2b. Penjualan 2 unit (sukses, stok 5 -> 3, jurnal Dr HPP / Cr Persediaan)
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('ITM-001', 'SALE', 2);

-- 2c. Cek hasil
SELECT item_id, item_name, stock_qty, unit_cost FROM inventory_items;
SELECT t.trx_id, t.item_id, t.trx_type, t.qty, h.reference_number, h.status_posting, h.hash_checksum
  FROM inventory_transactions t
  LEFT JOIN journal_headers h ON h.id = t.journal_id
 ORDER BY t.trx_id;
SELECT h.reference_number, c.account_code, c.account_name, l.debit, l.credit
  FROM journal_lines l
  JOIN journal_headers h ON h.id = l.header_id
  JOIN chart_of_accounts c ON c.account_id = l.account_id
 WHERE h.reference_number LIKE 'INV-%'
 ORDER BY h.id, l.id;

-- 2d. Overselling (harus ERROR, jalankan sendiri): stok tersisa 3, minta keluar 10
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('ITM-001', 'SALE', 10);
-- ERROR: Stok ITM-001 tidak cukup: tersedia 3, diminta keluar 10.

-- ---------- [UJI 3] Concurrency (Soal 2.2) ----------
-- Siapkan stok tersisa 1:
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('ITM-002', 'PURCHASE', 1);

-- Buka DUA tab SQL Editor (Kasir A dan Kasir B). Lihat file cuplikan di laporan.
-- Kasir A (tab 1):  BEGIN; INSERT ... SALE 1;   -- JANGAN COMMIT dulu
-- Kasir B (tab 2):  BEGIN; INSERT ... SALE 1;   -- menunggu (blocking)
-- Kasir A: COMMIT;  -> Kasir B lanjut, membaca stok 0 -> ERROR stok tidak cukup.
-- Catatan: SQL Editor Supabase tidak selalu mendukung sesi manual BEGIN/COMMIT lintas run.
-- Jika tidak bisa, cukup tampilkan kode + penjelasan, atau uji dengan dua koneksi psql.

-- ---------- [UJI 4] Jurnal manual lewat RPC + immutability (Soal 3.2) ----------
-- 4a. Posting voucher seimbang (Kas keluar Rp 1.500.000 untuk beban listrik)
SELECT post_journal(
    CURRENT_DATE, 'BKK-TEST-001', 'Bayar listrik Oktober', 'Dandy',
    '[{"account_id":10,"debit":1500000,"credit":0},
      {"account_id":1,"debit":0,"credit":1500000}]'::jsonb);
-- (account_id 10 = 6-2000 dan 1 = 1-1100 jika seed COA urut dari 1; cek dulu:
--  SELECT account_id, account_code, account_name FROM chart_of_accounts ORDER BY 1;)

-- 4b. Posting tidak seimbang (harus ERROR, jalankan sendiri)
SELECT post_journal(
    CURRENT_DATE, 'BKK-TEST-002', 'Tidak seimbang', 'Dandy',
    '[{"account_id":10,"debit":1500000,"credit":0},
      {"account_id":1,"debit":0,"credit":1000000}]'::jsonb);
-- ERROR: Jurnal BKK-TEST-002 tidak seimbang: total debit ... <> total kredit ...

-- 4c. UPDATE jurnal POSTED (harus ERROR, jalankan sendiri)
UPDATE journal_headers SET description = 'diubah diam-diam' WHERE reference_number = 'BKK-TEST-001';
-- ERROR: Jurnal BKK-TEST-001 sudah POSTED dan tidak boleh di-update. Gunakan jurnal pembalik (storno).

-- 4d. DELETE jurnal POSTED (harus ERROR, jalankan sendiri)
DELETE FROM journal_headers WHERE reference_number = 'BKK-TEST-001';

-- 4e. UPDATE baris jurnal POSTED (harus ERROR, jalankan sendiri)
UPDATE journal_lines SET debit = 1, credit = 0
 WHERE header_id = (SELECT id FROM journal_headers WHERE reference_number = 'BKK-TEST-001')
   AND debit > 0;

-- 4f. Storno yang sah
SELECT reverse_journal((SELECT id FROM journal_headers WHERE reference_number = 'BKK-TEST-001'), 'Dandy');

-- 4g. Verifikasi hash
SELECT verify_journal_integrity(id) FROM journal_headers ORDER BY id;

-- 4h. Audit log
SELECT id, table_name, record_id, action, changed_by, changed_at
  FROM audit_log ORDER BY id DESC LIMIT 20;

-- 4i. (Opsional) simulasi pembobolan: ubah nominal lewat jalur belakang lalu verifikasi hash
-- Sebagai pemilik tabel, nonaktifkan trigger sementara, ubah, verifikasi, lalu aktifkan lagi.
-- Jalankan SEBAGAI SATU BLOK:
--   ALTER TABLE journal_lines DISABLE TRIGGER trg_jl_lock_posted;
--   UPDATE journal_lines SET debit = 9999999
--    WHERE header_id = (SELECT id FROM journal_headers WHERE reference_number='BKK-TEST-001') AND debit > 0;
--   SELECT verify_journal_integrity(id) FROM journal_headers WHERE reference_number='BKK-TEST-001';  -- valid: false
--   ALTER TABLE journal_lines ENABLE TRIGGER trg_jl_lock_posted;
-- Setelah itu pulihkan nilai aslinya (1500000) sebelum lanjut.
