-- Fictional "acme" store used for the App Store screenshots and as the App Review test server.
-- Runs in any existing database and can be re-run to reset it:
--   createdb acme   (or create it in your hosting provider's dashboard)
--   psql "postgres://user:password@host:5432/acme" -f appstore/demo-db.sql

DROP SCHEMA IF EXISTS billing CASCADE;
DROP SCHEMA IF EXISTS analytics CASCADE;
DROP VIEW IF EXISTS public.customer_lifetime_value;
DROP TABLE IF EXISTS public.reviews, public.order_items, public.orders, public.products, public.categories,
  public.customers CASCADE;
DROP FUNCTION IF EXISTS public.order_total(integer);
DROP PROCEDURE IF EXISTS public.refund_order(integer);
DROP TYPE IF EXISTS public.order_status, public.plan_tier;

SELECT setseed(0.42);

CREATE SCHEMA billing;
CREATE SCHEMA analytics;

CREATE TYPE order_status AS ENUM ('pending', 'paid', 'shipped', 'delivered', 'refunded');
CREATE TYPE plan_tier AS ENUM ('starter', 'team', 'business', 'enterprise');

CREATE TABLE public.customers (
  id serial PRIMARY KEY,
  full_name text NOT NULL,
  email text NOT NULL UNIQUE,
  company text,
  city text NOT NULL,
  country char(2) NOT NULL,
  is_verified boolean NOT NULL DEFAULT false,
  signed_up_at timestamptz NOT NULL DEFAULT now(),
  preferences jsonb
);
COMMENT ON TABLE public.customers IS 'Everyone who has bought from the store';

CREATE TABLE public.categories (
  id serial PRIMARY KEY,
  name text NOT NULL UNIQUE,
  slug text NOT NULL UNIQUE
);

CREATE TABLE public.products (
  id serial PRIMARY KEY,
  category_id integer NOT NULL REFERENCES public.categories(id),
  sku text NOT NULL UNIQUE,
  name text NOT NULL,
  price numeric(10,2) NOT NULL CHECK (price >= 0),
  stock integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  tags text[]
);

CREATE TABLE public.orders (
  id serial PRIMARY KEY,
  customer_id integer NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  status order_status NOT NULL DEFAULT 'pending',
  placed_at timestamptz NOT NULL DEFAULT now(),
  shipping_city text,
  total numeric(10,2) NOT NULL DEFAULT 0
);
CREATE INDEX orders_customer_idx ON public.orders (customer_id);
CREATE INDEX orders_status_placed_idx ON public.orders (status, placed_at DESC);

CREATE TABLE public.order_items (
  order_id integer NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id integer NOT NULL REFERENCES public.products(id),
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price numeric(10,2) NOT NULL,
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE public.reviews (
  id serial PRIMARY KEY,
  product_id integer NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  customer_id integer NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE billing.plans (
  id serial PRIMARY KEY,
  tier plan_tier NOT NULL UNIQUE,
  monthly_price numeric(10,2) NOT NULL,
  seats integer NOT NULL
);

CREATE TABLE billing.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id integer NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  plan_id integer NOT NULL REFERENCES billing.plans(id),
  started_at date NOT NULL,
  cancelled_at date
);

CREATE TABLE billing.invoices (
  id serial PRIMARY KEY,
  subscription_id uuid NOT NULL REFERENCES billing.subscriptions(id) ON DELETE CASCADE,
  number text NOT NULL UNIQUE,
  amount numeric(10,2) NOT NULL,
  issued_on date NOT NULL,
  paid_on date
);

CREATE TABLE analytics.page_views (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id integer REFERENCES public.customers(id) ON DELETE SET NULL,
  path text NOT NULL,
  referrer text,
  viewed_at timestamptz NOT NULL
);

-- Names, cities and products ---------------------------------------------------------------

CREATE TEMP TABLE first_names(n) AS SELECT unnest(ARRAY[
  'Olivia','Liam','Emma','Noah','Amelia','Oliver','Sophia','Lucas','Mia','Mateo','Isabella','Hugo',
  'Chloé','Léa','Jonas','Sofía','Valentina','Santiago','Yuki','Haruto','Aiko','Priya','Arjun','Zara',
  'Ingrid','Lars','Freya','Matteo','Giulia','Elena','Ana','Diego','Camila','Nina','Theo','Ava','Leo',
  'Maya','Ethan','Grace','Jack','Ruby','Felix','Clara','Oscar','Alice','Iris','Max','Lena','Tomás']);
CREATE TEMP TABLE last_names(n) AS SELECT unnest(ARRAY[
  'Smith','Garcia','Müller','Rossi','Tanaka','Martin','Silva','Johansson','Dubois','Kowalski','Nguyen',
  'Patel','Fernández','Bianchi','Schmidt','Moreau','Sato','Hansen','Costa','López','Novak','Walker',
  'Kim','Okafor','Larsen','Ricci','Weber','Andersen','Romero','Clarke','Fischer','Laurent','Ito',
  'Herrera','Brennan','Vargas','Lindqvist','Russo','Becker','Ortiz']);
CREATE TEMP TABLE cities(city, country) AS VALUES
  ('San Francisco','US'),('New York','US'),('Austin','US'),('Seattle','US'),('Chicago','US'),
  ('London','GB'),('Manchester','GB'),('Berlin','DE'),('Munich','DE'),('Paris','FR'),('Lyon','FR'),
  ('Buenos Aires','AR'),('Córdoba','AR'),('Tokyo','JP'),('Osaka','JP'),('Madrid','ES'),('Barcelona','ES'),
  ('Milan','IT'),('Stockholm','SE'),('Amsterdam','NL'),('Toronto','CA'),('Sydney','AU'),('São Paulo','BR'),
  ('Mexico City','MX'),('Lisbon','PT');
CREATE TEMP TABLE companies(n) AS SELECT unnest(ARRAY[
  'Northwind Labs','Bluefin Studio','Lumen & Co','Paper Plane','Brightside','Orbital','Fieldwork',
  'Cedar Analytics','Kite Mobility','Harbor Health','Tidal Commerce','Quartz Systems','Maple Finance',
  'Pinecone Apps','Vela Robotics','Atlas Freight','Juniper Design','Copperleaf','Nimbus Cloud','Sable Media']);

INSERT INTO public.customers (full_name, email, company, city, country, is_verified, signed_up_at, preferences)
SELECT f.n || ' ' || l.n,
       lower(translate(f.n || '.' || l.n, 'éóáíúüöñ', 'eoaiuuon')) || g || '@'
         || (ARRAY['example.com','example.org','example.net','mail.example','acme.example'])[1 + g % 5],
       CASE WHEN g % 3 = 0 THEN NULL ELSE (SELECT n FROM companies OFFSET (g * 7) % 20 LIMIT 1) END,
       c.city, c.country,
       g % 4 <> 0,
       date_trunc('second', now() - ((g * 37) % 900 || ' days')::interval - random() * interval '1 day'),
       jsonb_build_object('newsletter', g % 2 = 0, 'theme', (ARRAY['light','dark','system'])[1 + g % 3],
                          'language', (ARRAY['en','es','de','fr','ja'])[1 + g % 5])
FROM generate_series(1, 2400) g
CROSS JOIN LATERAL (SELECT n FROM first_names OFFSET (g * 11) % 50 LIMIT 1) f
CROSS JOIN LATERAL (SELECT n FROM last_names OFFSET (g * 17) % 40 LIMIT 1) l
CROSS JOIN LATERAL (SELECT city, country FROM cities OFFSET (g * 3) % 25 LIMIT 1) c;

INSERT INTO public.categories (name, slug) VALUES
  ('Coffee', 'coffee'), ('Brewing gear', 'brewing-gear'), ('Grinders', 'grinders'),
  ('Mugs & cups', 'mugs-cups'), ('Tea', 'tea'), ('Accessories', 'accessories');

INSERT INTO public.products (category_id, sku, name, price, stock, is_active, tags) VALUES
  (1, 'CF-ETH-250', 'Ethiopia Yirgacheffe, 250 g', 18.50, 140, true, '{single-origin,light-roast}'),
  (1, 'CF-COL-250', 'Colombia Huila, 250 g', 16.00, 210, true, '{single-origin,medium-roast}'),
  (1, 'CF-KEN-250', 'Kenya Nyeri AA, 250 g', 21.00, 64, true, '{single-origin,light-roast}'),
  (1, 'CF-BRA-1K', 'Brazil Cerrado, 1 kg', 42.00, 38, true, '{espresso,medium-roast}'),
  (1, 'CF-HSE-500', 'House Espresso Blend, 500 g', 24.00, 320, true, '{espresso,blend}'),
  (1, 'CF-DEC-250', 'Swiss Water Decaf, 250 g', 17.00, 75, true, '{decaf}'),
  (2, 'BG-V60-02', 'Ceramic Dripper 02', 29.00, 88, true, '{pour-over}'),
  (2, 'BG-CHX-6', 'Glass Pour-Over Carafe, 6 cup', 49.00, 41, true, '{pour-over,glass}'),
  (2, 'BG-AERO', 'Travel Press', 39.95, 120, true, '{immersion,travel}'),
  (2, 'BG-KTL-GN', 'Gooseneck Kettle 0.9 L', 89.00, 27, true, '{kettle}'),
  (2, 'BG-SCL-01', 'Brew Scale with Timer', 59.00, 53, true, '{scale}'),
  (2, 'BG-FLT-100', 'Paper Filters, 100 pack', 7.50, 900, true, '{filters}'),
  (3, 'GR-HND-C40', 'Hand Grinder C40', 249.00, 12, true, '{hand-grinder}'),
  (3, 'GR-ELC-OD', 'Flat Burr Grinder', 349.00, 9, true, '{electric}'),
  (3, 'GR-ELC-ENC', 'Conical Burr Grinder', 149.00, 31, true, '{electric}'),
  (4, 'MG-STN-350', 'Stoneware Mug, 350 ml', 22.00, 160, true, '{ceramic}'),
  (4, 'MG-DBL-250', 'Double-Wall Glass, 250 ml', 14.00, 240, true, '{glass}'),
  (4, 'MG-TRV-450', 'Insulated Travel Mug', 34.00, 95, true, '{travel,steel}'),
  (4, 'MG-CRT-90', 'Cortado Glass Set of 4', 26.00, 0, false, '{glass,set}'),
  (5, 'TE-SEN-100', 'Japanese Sencha, 100 g', 15.00, 70, true, '{green-tea}'),
  (5, 'TE-EGY-100', 'Earl Grey Supreme, 100 g', 12.00, 110, true, '{black-tea}'),
  (5, 'TE-MAT-30', 'Ceremonial Matcha, 30 g', 28.00, 44, true, '{green-tea,matcha}'),
  (6, 'AC-TMP-58', 'Espresso Tamper 58 mm', 45.00, 36, true, '{espresso}'),
  (6, 'AC-KNK-BX', 'Knock Box', 32.00, 48, true, '{espresso}'),
  (6, 'AC-CNS-1K', 'Airtight Canister', 27.00, 130, true, '{storage}'),
  (6, 'AC-CLN-TB', 'Cleaning Tablets, 60 pack', 11.00, 410, true, '{cleaning}');

INSERT INTO public.orders (customer_id, status, placed_at, shipping_city)
SELECT 1 + floor(random() * 2400)::int,
       CASE WHEN g > 11800 THEN (ARRAY['pending','paid'])[1 + g % 2]::order_status
            WHEN g % 41 = 0 THEN 'refunded'
            WHEN g > 11500 THEN 'shipped'
            ELSE 'delivered' END,
       date_trunc('second', now() - ((12000 - g) * interval '53 minutes') - random() * interval '40 minutes'),
       (SELECT city FROM cities OFFSET (g * 5) % 25 LIMIT 1)
FROM generate_series(1, 12000) g;

INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
SELECT o.id, p.id, (ARRAY[1,1,1,2,2,3])[1 + floor(random() * 6)::int], p.price
FROM public.orders o
CROSS JOIN LATERAL (SELECT 1 + floor(random() * 3)::int + 0 * o.id AS n) c
CROSS JOIN LATERAL generate_series(1, c.n) k
CROSS JOIN LATERAL (SELECT 1 + floor(random() * 26)::int + 0 * k AS id) pick
JOIN public.products p ON p.id = pick.id
ON CONFLICT DO NOTHING;

UPDATE public.orders o SET total = s.total
FROM (SELECT order_id, sum(quantity * unit_price) AS total FROM public.order_items GROUP BY 1) s
WHERE s.order_id = o.id;

INSERT INTO public.reviews (product_id, customer_id, rating, title, created_at)
SELECT 1 + (g * 11) % 26, 1 + (g * 31) % 2400,
       (ARRAY[5,5,4,5,4,3,5,4,2,5])[1 + g % 10],
       (ARRAY['Best beans I''ve had this year','Great value','Exactly as described','Fast shipping',
              'Bright and fruity','A bit too dark for me','Beautiful build quality','Would buy again',
              'Arrived damaged, quickly replaced','My daily driver now'])[1 + g % 10],
       date_trunc('second', now() - (g * interval '7 hours'))
FROM generate_series(1, 1800) g;

INSERT INTO billing.plans (tier, monthly_price, seats) VALUES
  ('starter', 0, 1), ('team', 12, 10), ('business', 29, 50), ('enterprise', 99, 500);

INSERT INTO billing.subscriptions (customer_id, plan_id, started_at, cancelled_at)
SELECT g * 3, 1 + g % 4, current_date - (g * 2 % 700), CASE WHEN g % 9 = 0 THEN current_date - (g % 60) END
FROM generate_series(1, 700) g;

INSERT INTO billing.invoices (subscription_id, number, amount, issued_on, paid_on)
SELECT s.id, 'INV-' || to_char(m, 'YYYYMM') || '-' || lpad(row_number() OVER ()::text, 5, '0'),
       p.monthly_price, m::date, CASE WHEN m < date_trunc('month', current_date) THEN m::date + 3 END
FROM billing.subscriptions s
JOIN billing.plans p ON p.id = s.plan_id AND p.monthly_price > 0
CROSS JOIN LATERAL generate_series(date_trunc('month', s.started_at), coalesce(s.cancelled_at, current_date), interval '1 month') m;

INSERT INTO analytics.page_views (customer_id, path, referrer, viewed_at)
SELECT CASE WHEN g % 4 = 0 THEN NULL ELSE 1 + (g * 13) % 2400 END,
       (ARRAY['/','/shop','/shop/coffee','/shop/brewing-gear','/products/CF-ETH-250','/products/GR-HND-C40',
              '/cart','/checkout','/blog/how-to-brew-pour-over','/account'])[1 + g % 10],
       (ARRAY[NULL,'google.com','instagram.com','newsletter','reddit.com'])[1 + g % 5],
       date_trunc('second', now() - g * interval '2 minutes')
FROM generate_series(1, 50000) g;

CREATE VIEW public.customer_lifetime_value AS
SELECT c.id, c.full_name, c.country, count(o.id) AS orders, coalesce(sum(o.total), 0) AS lifetime_value
FROM public.customers c
LEFT JOIN public.orders o ON o.customer_id = c.id AND o.status <> 'refunded'
GROUP BY c.id;

CREATE MATERIALIZED VIEW analytics.daily_revenue AS
SELECT date_trunc('day', placed_at)::date AS day, count(*) AS orders, sum(total) AS revenue
FROM public.orders WHERE status <> 'refunded' GROUP BY 1;

CREATE FUNCTION public.order_total(p_order_id integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(quantity * unit_price), 0) FROM public.order_items WHERE order_id = p_order_id;
$$;

CREATE PROCEDURE public.refund_order(p_order_id integer)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.orders SET status = 'refunded' WHERE id = p_order_id;
  RAISE NOTICE 'Order % refunded', p_order_id;
END;
$$;

ANALYZE;
