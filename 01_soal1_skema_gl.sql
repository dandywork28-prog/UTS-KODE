-- =====================================================================
-- UTS Pemrograman / Coding - Dandy Rizkiansah (12030124130135)
-- SOAL 1: Skema General Ledger (COA, Header Jurnal, Line Jurnal)
-- Jalankan di Supabase > SQL Editor
-- =====================================================================

-- 1. Chart of Accounts ------------------------------------------------
CREATE TABLE chart_of_accounts (
    account_id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_code          VARCHAR(10)  NOT NULL UNIQUE,          -- kode akun, mis. 1-1100
    account_name          VARCHAR(100) NOT NULL,
    normal_balance        VARCHAR(6)   NOT NULL,
    report_classification VARCHAR(10)  NOT NULL,
    CONSTRAINT chk_coa_normal_balance
        CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    CONSTRAINT chk_coa_report_class
        CHECK (report_classification IN ('NERACA', 'LABA_RUGI'))
);

-- 2. Header jurnal (dokumen sumber / bukti) ---------------------------
CREATE TABLE journal_headers (
    id               INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_date DATE         NOT NULL,
    reference_number VARCHAR(50)  NOT NULL UNIQUE,               -- no. bukti
    description      TEXT,
    status_posting   VARCHAR(10)  NOT NULL DEFAULT 'DRAFT',
    CONSTRAINT chk_jh_status
        CHECK (status_posting IN ('DRAFT', 'POSTED'))
);

-- 3. Line jurnal (rincian debit / kredit) -----------------------------
CREATE TABLE journal_lines (
    id         INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    header_id  INTEGER       NOT NULL,
    account_id INTEGER       NOT NULL,
    debit      NUMERIC(15,2) NOT NULL DEFAULT 0,
    credit     NUMERIC(15,2) NOT NULL DEFAULT 0,

    CONSTRAINT fk_jl_header
        FOREIGN KEY (header_id)  REFERENCES journal_headers (id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_jl_account
        FOREIGN KEY (account_id) REFERENCES chart_of_accounts (account_id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_jl_debit_nonneg   CHECK (debit  >= 0),
    CONSTRAINT chk_jl_credit_nonneg  CHECK (credit >= 0),
    -- tidak boleh debit = 0 DAN credit = 0 sekaligus
    CONSTRAINT chk_jl_not_both_zero  CHECK (debit > 0 OR credit > 0),
    -- tambahan: satu baris hanya boleh satu sisi (debit ATAU kredit)
    CONSTRAINT chk_jl_one_side_only  CHECK (debit = 0 OR credit = 0)
);

CREATE INDEX idx_jl_header  ON journal_lines (header_id);
CREATE INDEX idx_jl_account ON journal_lines (account_id);

-- 4. Data awal COA ----------------------------------------------------
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_classification) VALUES
 ('1-1100', 'Kas',                              'DEBIT',  'NERACA'),
 ('1-1200', 'Bank',                             'DEBIT',  'NERACA'),
 ('1-1300', 'Persediaan Barang Dagang',         'DEBIT',  'NERACA'),
 ('2-1100', 'Utang Usaha',                      'CREDIT', 'NERACA'),
 ('3-1000', 'Modal Saham',                      'CREDIT', 'NERACA'),
 ('4-1000', 'Penjualan',                        'CREDIT', 'LABA_RUGI'),
 ('5-1000', 'Beban Pokok Pendapatan (HPP)',     'DEBIT',  'LABA_RUGI'),
 ('5-2000', 'Beban Selisih Persediaan',         'DEBIT',  'LABA_RUGI'),
 ('6-1000', 'Beban Operasional',                'DEBIT',  'LABA_RUGI'),
 ('6-2000', 'Beban Listrik, Air, dan Telepon',  'DEBIT',  'LABA_RUGI'),
 ('6-3000', 'Beban Gaji',                       'DEBIT',  'LABA_RUGI');
