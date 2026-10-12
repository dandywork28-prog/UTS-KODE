-- =====================================================================
-- UTS Pemrograman / Coding - Dandy Rizkiansah (12030124130135)
-- SOAL 3.2: Audit trail, immutability jurnal POSTED, storno, RPC
-- Prasyarat: 01 dan 02 sudah dijalankan
-- =====================================================================

-- 1. Kolom audit trail -------------------------------------------------
ALTER TABLE journal_headers
    ADD COLUMN IF NOT EXISTS created_by    TEXT        NOT NULL DEFAULT 'system',
    ADD COLUMN IF NOT EXISTS created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS hash_checksum TEXT,
    ADD COLUMN IF NOT EXISTS reversal_of   INTEGER REFERENCES journal_headers(id) ON DELETE RESTRICT;

-- satu jurnal hanya boleh di-storno satu kali
CREATE UNIQUE INDEX IF NOT EXISTS uq_jh_reversal_of
    ON journal_headers (reversal_of) WHERE reversal_of IS NOT NULL;

-- 2. Hash SHA-256 dari data penting jurnal -----------------------------
CREATE OR REPLACE FUNCTION fn_compute_journal_hash(p_header_id INTEGER)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        sha256(convert_to(
            h.reference_number || '|' || h.transaction_date::text || '|' ||
            COALESCE((
                SELECT string_agg(c.account_code || ':' || l.debit::text || ':' || l.credit::text,
                                  ';' ORDER BY l.id)
                  FROM journal_lines l
                  JOIN chart_of_accounts c ON c.account_id = l.account_id
                 WHERE l.header_id = h.id
            ), ''),
            'UTF8')),
        'hex')
    FROM journal_headers h
    WHERE h.id = p_header_id;
$$;

-- 3. Gerbang posting: jurnal baru harus DRAFT; POSTED wajib seimbang ----
CREATE OR REPLACE FUNCTION fn_enforce_balance_on_post()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_debit  NUMERIC;
    v_credit NUMERIC;
    v_lines  INT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status_posting <> 'DRAFT' THEN
            RAISE EXCEPTION 'Jurnal baru harus berstatus DRAFT, lalu di-posting setelah barisnya lengkap.';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status_posting = 'POSTED' AND OLD.status_posting <> 'POSTED' THEN
        SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0), COUNT(*)
          INTO v_debit, v_credit, v_lines
          FROM journal_lines
         WHERE header_id = NEW.id;

        IF v_lines < 2 THEN
            RAISE EXCEPTION 'Jurnal % tidak bisa di-posting: minimal 2 baris.', NEW.reference_number;
        END IF;
        IF v_debit = 0 OR v_debit <> v_credit THEN
            RAISE EXCEPTION 'Jurnal % tidak seimbang: total debit % <> total kredit %.',
                NEW.reference_number, v_debit, v_credit
                USING ERRCODE = '23514';
        END IF;

        NEW.hash_checksum := fn_compute_journal_hash(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_jh_enforce_balance ON journal_headers;
CREATE TRIGGER trg_jh_enforce_balance
BEFORE INSERT OR UPDATE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_enforce_balance_on_post();

-- 4. Immutability header POSTED (tolak UPDATE & DELETE) ----------------
CREATE OR REPLACE FUNCTION fn_prevent_posted_header_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status_posting = 'POSTED' THEN
        RAISE EXCEPTION
            'Jurnal % sudah POSTED dan tidak boleh di-%. Gunakan jurnal pembalik (storno).',
            OLD.reference_number, lower(TG_OP)
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_jh_lock_posted ON journal_headers;
CREATE TRIGGER trg_jh_lock_posted
BEFORE UPDATE OR DELETE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_prevent_posted_header_change();

-- 5. Immutability baris jurnal milik header POSTED ---------------------
CREATE OR REPLACE FUNCTION fn_prevent_posted_line_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT status_posting INTO v_status FROM journal_headers WHERE id = OLD.header_id;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Baris jurnal milik header POSTED tidak boleh di-% (header id %).',
                lower(TG_OP), OLD.header_id USING ERRCODE = '55000';
        END IF;
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT status_posting INTO v_status FROM journal_headers WHERE id = NEW.header_id;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak boleh menambah/mengubah baris pada jurnal POSTED (header id %).',
                NEW.header_id USING ERRCODE = '55000';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_jl_lock_posted ON journal_lines;
CREATE TRIGGER trg_jl_lock_posted
BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
FOR EACH ROW EXECUTE FUNCTION fn_prevent_posted_line_change();

-- 6. Audit log (append-only) -------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT        NOT NULL,
    record_id  TEXT,
    action     TEXT        NOT NULL,
    old_data   JSONB,
    new_data   JSONB,
    changed_by TEXT        NOT NULL DEFAULT current_user,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION fn_write_audit_log()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, new_data)
        VALUES (TG_TABLE_NAME, NEW.id::text, TG_OP, to_jsonb(NEW));
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
        VALUES (TG_TABLE_NAME, NEW.id::text, TG_OP, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSE
        INSERT INTO audit_log (table_name, record_id, action, old_data)
        VALUES (TG_TABLE_NAME, OLD.id::text, TG_OP, to_jsonb(OLD));
        RETURN OLD;
    END IF;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_jh ON journal_headers;
CREATE TRIGGER trg_audit_jh
AFTER INSERT OR UPDATE OR DELETE ON journal_headers
FOR EACH ROW EXECUTE FUNCTION fn_write_audit_log();

DROP TRIGGER IF EXISTS trg_audit_jl ON journal_lines;
CREATE TRIGGER trg_audit_jl
AFTER INSERT OR UPDATE OR DELETE ON journal_lines
FOR EACH ROW EXECUTE FUNCTION fn_write_audit_log();

-- audit_log sendiri tidak boleh diubah / dihapus
CREATE OR REPLACE FUNCTION fn_audit_log_readonly()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit_log bersifat append-only (% ditolak).', TG_OP USING ERRCODE = '55000';
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_log_readonly ON audit_log;
CREATE TRIGGER trg_audit_log_readonly
BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION fn_audit_log_readonly();

-- 7. RPC: posting voucher (atomik: header + lines + posting) -----------
CREATE OR REPLACE FUNCTION post_journal(
    p_date        DATE,
    p_reference   TEXT,
    p_description TEXT,
    p_created_by  TEXT,
    p_lines       JSONB      -- [{"account_id":1,"debit":1000,"credit":0}, ...]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id   INTEGER;
    v_line JSONB;
    v_hash TEXT;
BEGIN
    INSERT INTO journal_headers (transaction_date, reference_number, description, created_by)
    VALUES (p_date, p_reference, p_description, COALESCE(NULLIF(trim(p_created_by), ''), 'anon'))
    RETURNING id INTO v_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        VALUES (v_id,
                (v_line->>'account_id')::int,
                COALESCE((v_line->>'debit')::numeric, 0),
                COALESCE((v_line->>'credit')::numeric, 0));
    END LOOP;

    -- gerbang keseimbangan dijalankan trigger saat status -> POSTED
    UPDATE journal_headers SET status_posting = 'POSTED' WHERE id = v_id;

    SELECT hash_checksum INTO v_hash FROM journal_headers WHERE id = v_id;
    RETURN jsonb_build_object('id', v_id, 'reference_number', p_reference, 'hash_checksum', v_hash);
END;
$$;

-- 8. RPC: jurnal pembalik (storno) -------------------------------------
CREATE OR REPLACE FUNCTION reverse_journal(p_header_id INTEGER, p_created_by TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_orig   journal_headers%ROWTYPE;
    v_new_id INTEGER;
    v_hash   TEXT;
BEGIN
    SELECT * INTO v_orig FROM journal_headers WHERE id = p_header_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Jurnal id % tidak ditemukan.', p_header_id;
    END IF;
    IF v_orig.status_posting <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang perlu di-storno.';
    END IF;

    INSERT INTO journal_headers (transaction_date, reference_number, description, created_by, reversal_of)
    VALUES (CURRENT_DATE,
            'REV-' || v_orig.reference_number,
            'Storno atas ' || v_orig.reference_number,
            COALESCE(NULLIF(trim(p_created_by), ''), 'anon'),
            v_orig.id)
    RETURNING id INTO v_new_id;

    -- debit dan kredit ditukar
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_new_id, account_id, credit, debit
      FROM journal_lines
     WHERE header_id = v_orig.id
     ORDER BY id;

    UPDATE journal_headers SET status_posting = 'POSTED' WHERE id = v_new_id;

    SELECT hash_checksum INTO v_hash FROM journal_headers WHERE id = v_new_id;
    RETURN jsonb_build_object('id', v_new_id, 'reference_number', 'REV-' || v_orig.reference_number,
                              'hash_checksum', v_hash);
END;
$$;

-- 9. Verifikasi integritas hash ----------------------------------------
CREATE OR REPLACE FUNCTION verify_journal_integrity(p_header_id INTEGER)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'id',         h.id,
        'stored',     h.hash_checksum,
        'recomputed', fn_compute_journal_hash(h.id),
        'valid',      h.hash_checksum IS NOT DISTINCT FROM fn_compute_journal_hash(h.id)
    )
    FROM journal_headers h
    WHERE h.id = p_header_id;
$$;

-- 10. Row Level Security (untuk akses lewat API publishable key) --------
-- Frontend hanya boleh MEMBACA tabel; menulis hanya lewat RPC di atas.
ALTER TABLE chart_of_accounts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_headers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines          ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_read_coa ON chart_of_accounts;
DROP POLICY IF EXISTS p_read_jh  ON journal_headers;
DROP POLICY IF EXISTS p_read_jl  ON journal_lines;
DROP POLICY IF EXISTS p_read_al  ON audit_log;
CREATE POLICY p_read_coa ON chart_of_accounts FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY p_read_jh  ON journal_headers   FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY p_read_jl  ON journal_lines     FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY p_read_al  ON audit_log         FOR SELECT TO anon, authenticated USING (true);

GRANT EXECUTE ON FUNCTION post_journal(DATE, TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reverse_journal(INTEGER, TEXT)              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION verify_journal_integrity(INTEGER)           TO anon, authenticated;
