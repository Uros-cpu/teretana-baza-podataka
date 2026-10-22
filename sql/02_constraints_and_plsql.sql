-- =====================================================================
-- SportAgora – foreign keys, triggers, procedure and function
-- Run after 01_schema.sql.
-- Source: project documentation (docs/SportAgora_dokumentacija.pdf).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Foreign keys
-- ---------------------------------------------------------------------
ALTER TABLE TRENER      ADD CONSTRAINT FK_TRENER_PROGRAM    FOREIGN KEY (ID_programa)  REFERENCES PROGRAM (ID_programa);
ALTER TABLE TERMIN      ADD CONSTRAINT FK_TERMIN_PROGRAM    FOREIGN KEY (ID_programa)  REFERENCES PROGRAM (ID_programa);
ALTER TABLE TERMIN      ADD CONSTRAINT FK_TERMIN_TRENER     FOREIGN KEY (ID_trenera)   REFERENCES TRENER (ID_trenera);
ALTER TABLE ZAKAZIVANJE ADD CONSTRAINT FK_ZAKAZ_CLAN        FOREIGN KEY (ID_clana)     REFERENCES CLAN (ID_clana);
ALTER TABLE ZAKAZIVANJE ADD CONSTRAINT FK_ZAKAZ_TERMIN      FOREIGN KEY (ID_termina)   REFERENCES TERMIN (ID_termina);
ALTER TABLE UPLATA      ADD CONSTRAINT FK_UPLATA_CLAN       FOREIGN KEY (ID_clana)     REFERENCES CLAN (ID_clana);
ALTER TABLE CLANARINA   ADD CONSTRAINT FK_CLANARINA_CLAN    FOREIGN KEY (ID_clana)     REFERENCES CLAN (ID_clana);
ALTER TABLE CLANARINA   ADD CONSTRAINT FK_CLANARINA_USLUGA  FOREIGN KEY (ID_usluge)    REFERENCES USLUGA (ID_usluge);
ALTER TABLE PRISUSTVO   ADD CONSTRAINT FK_PRISUSTVO_CLAN    FOREIGN KEY (ID_clana)     REFERENCES CLAN (ID_clana);

-- ---------------------------------------------------------------------
-- Denormalization 1: ZAKAZIVANJE.Naziv_programa (copied attribute)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_zakazivanje_insert
BEFORE INSERT ON ZAKAZIVANJE
FOR EACH ROW
DECLARE
    v_naziv PROGRAM.Naziv_programa%TYPE;
BEGIN
    SELECT p.Naziv_programa
    INTO v_naziv
    FROM TERMIN t
    JOIN PROGRAM p ON t.ID_programa = p.ID_programa
    WHERE t.ID_termina = :NEW.ID_termina;
    :NEW.Naziv_programa := v_naziv;
END;
/

CREATE OR REPLACE TRIGGER trg_zakazivanje_update
BEFORE UPDATE OF ID_termina ON ZAKAZIVANJE
FOR EACH ROW
DECLARE
    v_naziv PROGRAM.Naziv_programa%TYPE;
BEGIN
    SELECT p.Naziv_programa
    INTO v_naziv
    FROM TERMIN t
    JOIN PROGRAM p ON t.ID_programa = p.ID_programa
    WHERE t.ID_termina = :NEW.ID_termina;
    :NEW.Naziv_programa := v_naziv;
END;
/

CREATE OR REPLACE TRIGGER trg_termin_update_program
AFTER UPDATE OF ID_programa ON TERMIN
FOR EACH ROW
DECLARE
    v_naziv PROGRAM.Naziv_programa%TYPE;
BEGIN
    SELECT Naziv_programa INTO v_naziv
    FROM PROGRAM
    WHERE ID_programa = :NEW.ID_programa;
    UPDATE ZAKAZIVANJE
    SET Naziv_programa = v_naziv
    WHERE ID_termina = :NEW.ID_termina;
END;
/

-- ---------------------------------------------------------------------
-- Denormalization 2: TERMIN.Broj_zakazanih (stored aggregate)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_zakaz_insert_brojac
AFTER INSERT ON ZAKAZIVANJE
FOR EACH ROW
BEGIN
    UPDATE TERMIN
    SET Broj_zakazanih = Broj_zakazanih + 1
    WHERE ID_termina = :NEW.ID_termina;
END;
/

CREATE OR REPLACE TRIGGER trg_zakaz_update_brojac
AFTER UPDATE OF ID_termina ON ZAKAZIVANJE
FOR EACH ROW
BEGIN
    UPDATE TERMIN
    SET Broj_zakazanih = Broj_zakazanih - 1
    WHERE ID_termina = :OLD.ID_termina;
    UPDATE TERMIN
    SET Broj_zakazanih = Broj_zakazanih + 1
    WHERE ID_termina = :NEW.ID_termina;
END;
/

CREATE OR REPLACE TRIGGER trg_zakaz_delete_brojac
AFTER DELETE ON ZAKAZIVANJE
FOR EACH ROW
BEGIN
    UPDATE TERMIN
    SET Broj_zakazanih = Broj_zakazanih - 1
    WHERE ID_termina = :OLD.ID_termina;
END;
/

-- ---------------------------------------------------------------------
-- Optimization: CLAN.Saldo (materialized balance)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TRIGGER trg_uplata_saldo
AFTER INSERT ON UPLATA
FOR EACH ROW
BEGIN
    UPDATE CLAN
    SET Saldo = Saldo + :NEW.Iznos
    WHERE ID_clana = :NEW.ID_clana;
END;
/

CREATE OR REPLACE TRIGGER trg_clanarina_saldo
BEFORE INSERT ON CLANARINA
FOR EACH ROW
DECLARE
    v_trenutni_saldo CLAN.Saldo%TYPE;
BEGIN
    SELECT Saldo INTO v_trenutni_saldo
    FROM CLAN
    WHERE ID_clana = :NEW.ID_clana;
    IF v_trenutni_saldo < :NEW.Cena_placena THEN
        RAISE_APPLICATION_ERROR(-20001, 'Nedovoljno sredstava na saldu clana.');
    END IF;
    UPDATE CLAN
    SET Saldo = Saldo - :NEW.Cena_placena
    WHERE ID_clana = :NEW.ID_clana;
END;
/

-- ---------------------------------------------------------------------
-- Procedure: activate a membership
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE aktiviraj_clanarinu (
    p_id_clana  IN NUMBER,
    p_id_usluge IN NUMBER
) IS
    v_cena     USLUGA.Cena%TYPE;
    v_trajanje USLUGA.Trajanje_dana%TYPE;
    v_novi_id  NUMBER;
BEGIN
    SELECT Cena, Trajanje_dana
    INTO v_cena, v_trajanje
    FROM USLUGA
    WHERE ID_usluge = p_id_usluge;

    SELECT NVL(MAX(ID_clanarine), 0) + 1
    INTO v_novi_id
    FROM CLANARINA;

    INSERT INTO CLANARINA (
        ID_clanarine, ID_clana, ID_usluge,
        Datum_pocetka, Datum_isteka, Cena_placena, Status
    ) VALUES (
        v_novi_id, p_id_clana, p_id_usluge,
        SYSDATE, SYSDATE + v_trajanje, v_cena, 'Aktivna'
    );

    DBMS_OUTPUT.PUT_LINE('Clanarina uspesno aktivirana. ID: ' || v_novi_id ||
                         ', istice: ' || TO_CHAR(SYSDATE + v_trajanje, 'DD.MM.YYYY'));
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20002, 'Usluga sa datim ID-jem ne postoji.');
END aktiviraj_clanarinu;
/

-- ---------------------------------------------------------------------
-- Function: days left on the member's active membership
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION preostalo_dana_clanarine (
    p_id_clana IN NUMBER
) RETURN NUMBER IS
    v_datum_isteka CLANARINA.Datum_isteka%TYPE;
    v_preostalo    NUMBER;
BEGIN
    SELECT MAX(Datum_isteka)
    INTO v_datum_isteka
    FROM CLANARINA
    WHERE ID_clana = p_id_clana
      AND Status = 'Aktivna';

    IF v_datum_isteka IS NULL THEN
        RETURN 0;
    END IF;

    v_preostalo := TRUNC(v_datum_isteka) - TRUNC(SYSDATE);

    IF v_preostalo < 0 THEN
        RETURN 0;
    END IF;

    RETURN v_preostalo;
END preostalo_dana_clanarine;
/
