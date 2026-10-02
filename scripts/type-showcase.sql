-- One column per common PostgreSQL type, for testing display and editing.
-- Re-runnable: psql "postgres://postgres:secret@localhost:55432/dbjoy_sample" -f scripts/type-showcase.sql

DROP TABLE IF EXISTS public.type_showcase;
DROP TYPE IF EXISTS public.mood;
DROP DOMAIN IF EXISTS public.positive_int;

CREATE TYPE public.mood AS ENUM ('happy', 'ok', 'sad');
CREATE DOMAIN public.positive_int AS integer CHECK (VALUE > 0);

CREATE TABLE public.type_showcase (
  id                serial PRIMARY KEY,
  -- Closed sets: edited with a dropdown
  c_boolean         boolean,
  c_boolean_strict  boolean NOT NULL DEFAULT false,
  c_enum            public.mood,
  c_check_list      text CHECK (c_check_list IN ('draft', 'published', 'archived')),
  c_check_numbers   integer CHECK (c_check_numbers IN (1, 2, 3)),
  -- Numbers
  c_smallint        smallint,
  c_integer         integer,
  c_bigint          bigint,
  c_numeric         numeric(12, 3),
  c_real            real,
  c_double          double precision,
  c_money           money,
  c_domain          public.positive_int,
  -- Text
  c_text            text,
  c_varchar         varchar(50),
  c_char            char(3),
  c_not_null        text NOT NULL DEFAULT 'hello',
  -- Date / time
  c_date            date,
  c_time            time,
  c_timetz          time with time zone,
  c_timestamp       timestamp,
  c_timestamptz     timestamptz,
  c_interval        interval,
  -- Structured
  c_json            json,
  c_jsonb           jsonb,
  c_xml             xml,
  c_int_array       integer[],
  c_text_array      text[],
  c_int4range       int4range,
  c_point           point,
  -- Identifiers / network / binary
  c_uuid            uuid,
  c_inet            inet,
  c_cidr            cidr,
  c_macaddr         macaddr,
  c_bytea           bytea,
  c_bit             bit(4),
  c_varbit          bit varying(8),
  c_tsvector        tsvector,
  -- Read-only: computed by the server
  c_generated       integer GENERATED ALWAYS AS (c_integer * 2) STORED
);
COMMENT ON TABLE public.type_showcase IS 'One column per type, for testing editors';

INSERT INTO public.type_showcase (
  c_boolean, c_boolean_strict, c_enum, c_check_list, c_check_numbers,
  c_smallint, c_integer, c_bigint, c_numeric, c_real, c_double, c_money, c_domain,
  c_text, c_varchar, c_char, c_not_null,
  c_date, c_time, c_timetz, c_timestamp, c_timestamptz, c_interval,
  c_json, c_jsonb, c_xml, c_int_array, c_text_array, c_int4range, c_point,
  c_uuid, c_inet, c_cidr, c_macaddr, c_bytea, c_bit, c_varbit, c_tsvector
) VALUES
  (true, true, 'happy', 'draft', 1,
   1, 42, 9007199254740993, 1234.567, 3.14, 2.718281828459045, 19.99, 7,
   'Hello, world', 'short text', 'abc', 'hello',
   '2026-10-02', '13:45:00', '13:45:00+02', '2026-10-02 13:45:00', '2026-10-02 13:45:00+00', '1 day 2 hours',
   '{"a": 1}', '{"tags": ["x", "y"], "nested": {"ok": true}}', '<note>hi</note>', '{1,2,3}', '{"a","b c"}', '[1,10)', '(1.5,2.5)',
   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '192.168.1.10', '10.0.0.0/8', '08:00:2b:01:02:03', '\xdeadbeef', '1010', '110', 'quick brown fox'),
  (false, false, 'sad', 'published', 3,
   -32768, -1, -9223372036854775808, -0.001, -1.5e-10, 1e300, -5.00, 1,
   E'Multi\nline\ntext', 'O''Reilly', 'x', 'world',
   '1999-12-31', '00:00:00', '23:59:59-05', '2000-01-01 00:00:00', '2000-01-01 00:00:00+00', '-3 mons',
   '[]', '{}', '<a/>', '{}', '{NULL,"quoted \"value\""}', 'empty', '(0,0)',
   '00000000-0000-0000-0000-000000000000', '::1', '2001:db8::/32', 'ff:ff:ff:ff:ff:ff', '\x', '0000', '', ''),
  -- Every nullable column NULL.
  (NULL, false, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, 'only required values',
   NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL,
   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
