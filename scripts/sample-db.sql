-- Sample schema for trying DBJoy and for integration tests.
-- Usage: psql "postgres://postgres:secret@localhost:55432/postgres" -f scripts/sample-db.sql

DROP DATABASE IF EXISTS dbjoy_sample;
CREATE DATABASE dbjoy_sample;
\connect dbjoy_sample

CREATE SCHEMA sales;

CREATE TABLE public.customers (
  id serial PRIMARY KEY,
  name text NOT NULL,
  email text UNIQUE,
  country char(2) DEFAULT 'US',
  created_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb
);
COMMENT ON TABLE public.customers IS 'People who buy things';
COMMENT ON COLUMN public.customers.email IS 'Primary contact email';

CREATE TABLE public.products (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku text NOT NULL UNIQUE,
  title text NOT NULL,
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  active boolean NOT NULL DEFAULT true,
  tags text[]
);

CREATE TABLE public.orders (
  id serial PRIMARY KEY,
  customer_id integer NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  placed_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'pending',
  note text
);
CREATE INDEX orders_customer_idx ON public.orders (customer_id);
CREATE INDEX orders_status_placed_idx ON public.orders (status, placed_at DESC);

CREATE TABLE public.order_items (
  order_id integer REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id bigint REFERENCES public.products(id),
  quantity integer NOT NULL DEFAULT 1,
  unit_price numeric(10,2) NOT NULL,
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE public.audit_log (
  happened_at timestamptz DEFAULT now(),
  message text
);

CREATE TABLE sales.regions (
  code text PRIMARY KEY,
  name text NOT NULL
);

INSERT INTO public.customers (name, email, country, metadata)
SELECT 'Customer ' || g, 'customer' || g || '@example.com',
       (ARRAY['US','GB','DE','FR','AR','JP'])[1 + g % 6],
       jsonb_build_object('tier', CASE WHEN g % 10 = 0 THEN 'gold' ELSE 'standard' END)
FROM generate_series(1, 1000) g;

INSERT INTO public.products (sku, title, price, tags)
SELECT 'SKU-' || lpad(g::text, 4, '0'), 'Product ' || g, (g * 3.17)::numeric(10,2),
       ARRAY['tag' || (g % 3), 'tag' || (g % 5)]
FROM generate_series(1, 200) g;

INSERT INTO public.orders (customer_id, placed_at, status, note)
SELECT 1 + g % 1000, now() - (g || ' hours')::interval,
       (ARRAY['pending','paid','shipped','cancelled'])[1 + g % 4],
       CASE WHEN g % 7 = 0 THEN 'Leave at the door' END
FROM generate_series(1, 5000) g;

INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
SELECT o, 1 + (o * 7 + k) % 200, 1 + k, 9.99
FROM generate_series(1, 5000) o, generate_series(0, 2) k
ON CONFLICT DO NOTHING;

INSERT INTO public.audit_log (message) VALUES ('created'), ('seeded');
INSERT INTO sales.regions VALUES ('emea', 'Europe, Middle East & Africa'), ('amer', 'Americas');

CREATE VIEW public.customer_order_totals AS
SELECT c.id, c.name, count(o.id) AS orders, coalesce(sum(i.quantity * i.unit_price), 0) AS total
FROM public.customers c
LEFT JOIN public.orders o ON o.customer_id = c.id
LEFT JOIN public.order_items i ON i.order_id = o.id
GROUP BY c.id, c.name;

CREATE MATERIALIZED VIEW public.daily_sales AS
SELECT date_trunc('day', placed_at) AS day, count(*) AS orders
FROM public.orders GROUP BY 1;

CREATE FUNCTION public.order_total(p_order_id integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(quantity * unit_price), 0) FROM public.order_items WHERE order_id = p_order_id;
$$;

CREATE PROCEDURE public.cancel_order(p_order_id integer)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.orders SET status = 'cancelled' WHERE id = p_order_id;
  RAISE NOTICE 'Order % cancelled', p_order_id;
END;
$$;

-- Type showcase table (one column per type).
\ir type-showcase.sql

ANALYZE;
