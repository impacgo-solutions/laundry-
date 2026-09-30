-- ============================================================================
-- IroningBoy backend - reconstructed schema
--
-- There is no schema/migration file anywhere in the original repo. This was
-- rebuilt by scanning every pool.query(...) call in `server` (~14000 lines)
-- and inferring table/column shapes from how they're used. Treat this as
-- best-effort, not a guaranteed match to the original production database.
--
-- KEY DECISIONS / AMBIGUITIES RESOLVED (read before relying on this):
--
-- 1. customers.id / driver.driver_id / laundrymanager.user_id / administration_logins.user_id
--    Older code (roughly first half of the file) treats these as opaque IDs
--    with no type-revealing operations. Newer code (roughly second half -
--    driver/manager CRUD, quick-booking) explicitly validates them with a
--    UUID regex and casts `::uuid`, and one insert has an inline comment
--    confirming customers.id is uuid. That's much stronger evidence, so
--    these 4 "identity" tables use UUID primary keys here, and every FK-like
--    column pointing at them (orders.user_id/manager_id/driver_id,
--    invoice.customer_id/manager_id, driver_approvals.driver_id/customer_id,
--    referrals.*_customer_id, addresses.user_id, feedback.user_id,
--    order_videos.customer_id, driver_notes.driver_id,
--    customer_manager_mapping.*, commission_config.manager_id,
--    ringcentral_call_sessions.driver_id/customer_id) is UUID too.
--    orders.id itself stays INTEGER - that one has unanimous, unambiguous
--    parseInt()/formatting evidence across the whole file.
--
-- 2. `postcodeareas` vs `postcode_areas`: the admin CRUD endpoints
--    (/admin/create-area, /admin/areas) and the slot_rules/daily_time_windows
--    foreign keys all point at `postcodeareas` (no underscore) - that's the
--    real, actively-maintained table. One older GET endpoint
--    (`/postcode-areas`) queries `postcode_areas` (with underscore) instead.
--    Rather than guess which is "right" and break the other route, both
--    names exist: `postcodeareas` is the real table, `postcode_areas` is a
--    view over it.
--
-- 3. Two confirmed-dead code paths were intentionally NOT given tables,
--    since creating them would just be schema clutter for code that can
--    never run:
--      - a second `/call-customer` handler using a `drivers`/`phone` shape
--        (Express registers routes in order; the first `/call-customer`
--        handler always wins, so this one is unreachable).
--      - `GET /driver/order-images/:orderId` referencing `driver_order_images`
--        via a MySQL-style `?` placeholder against an undefined `db` object
--        (throws before ever reaching the database). The working table for
--        this feature is `order_driver_images`, which is included below.
--
-- 4. Foreign keys are documented in comments but NOT enforced with
--    `REFERENCES` constraints. This is a reverse-engineered schema being
--    used for local dev with ad-hoc test data - a hard FK constraint on a
--    relationship we guessed slightly wrong would block the whole app
--    instead of just that one feature. UNIQUE constraints that the code
--    actually depends on (via `ON CONFLICT`) ARE included, since without
--    them those queries fail outright regardless of data.
--
-- 5. Money/percentage columns use plain `numeric` (no fixed precision) to
--    avoid rounding/overflow errors from guessing the wrong scale.
--
-- 6. `global_settings` and `user_types` are singleton/lookup tables the app
--    expects to already contain rows (e.g. `WHERE id = 1`) - seed data is
--    included at the bottom, not just structure.
--
-- Columns/tables marked "UNCERTAIN" in comments are genuine guesses - if you
-- hit a "column does not exist" error on one of those, that's why.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ============================================================================
-- Identity tables (UUID primary keys - see decision #1 above)
-- ============================================================================

CREATE TABLE IF NOT EXISTS customers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text,
  email               text,
  phone               text,
  password            text,                          -- nullable: Google/Apple sign-in has no password
  customer_number     text,
  wallet_balance      numeric NOT NULL DEFAULT 0,
  referral_code       text,
  stripe_customer_id  text,
  fcm_token           text,
  user_type_id        integer,                        -- FK -> user_types.id, nullable (not always set on insert)
  assigned_manager_id uuid,                            -- FK -> laundrymanager.user_id
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS customers_email_lower_idx ON customers (lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS customers_phone_idx ON customers (phone) WHERE phone IS NOT NULL;

CREATE TABLE IF NOT EXISTS laundrymanager (
  user_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  username          text NOT NULL,
  password          text NOT NULL,                    -- bcrypt hash
  laundryservicename text,
  phone_number      text,
  fcm_token         text,
  created_at        timestamptz DEFAULT now()          -- UNCERTAIN: one code comment says this column doesn't exist, another endpoint selects it
);
CREATE UNIQUE INDEX IF NOT EXISTS laundrymanager_username_lower_idx ON laundrymanager (lower(username));

CREATE TABLE IF NOT EXISTS driver (
  driver_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  username    text NOT NULL,
  password    text NOT NULL,                          -- bcrypt hash
  phone_number text,
  manager_id  uuid,                                    -- FK -> laundrymanager.user_id
  assigned    boolean DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS driver_username_lower_idx ON driver (lower(username));
CREATE UNIQUE INDEX IF NOT EXISTS driver_name_lower_idx ON driver (lower(name));

CREATE TABLE IF NOT EXISTS administration_logins (
  user_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text,
  email       text,
  password_hash text,
  phone       text,
  role        text DEFAULT 'support',
  is_active   boolean DEFAULT true,
  fcm_token   text,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS administration_logins_email_idx ON administration_logins (lower(email)) WHERE email IS NOT NULL;

-- ============================================================================
-- Lookup tables
-- ============================================================================

CREATE TABLE IF NOT EXISTS user_types (
  id   integer PRIMARY KEY,
  name text
);

-- ============================================================================
-- Catalog: categories / sub_categories / products / product_user_types
-- ============================================================================

CREATE TABLE IF NOT EXISTS categories (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  description text,
  emoji       text
);

CREATE TABLE IF NOT EXISTS sub_categories (
  id          serial PRIMARY KEY,
  name        text NOT NULL,
  description text,
  category_id integer NOT NULL           -- FK -> categories.id
);

CREATE TABLE IF NOT EXISTS products (
  id              serial PRIMARY KEY,
  name            text NOT NULL,
  emoji           text,
  category_id     integer NOT NULL,      -- FK -> categories.id
  sub_category_id integer,               -- FK -> sub_categories.id
  size            text,
  material        text,
  treatment       text,
  packing         text
);

CREATE TABLE IF NOT EXISTS product_user_types (
  product_id     integer NOT NULL,       -- FK -> products.id
  user_type_id   integer NOT NULL,       -- FK -> user_types.id
  standard_price numeric,
  offer_price    numeric,
  PRIMARY KEY (product_id, user_type_id)
);

-- ============================================================================
-- Addresses
-- ============================================================================

CREATE TABLE IF NOT EXISTS addresses (
  address_id         serial PRIMARY KEY,
  user_id            uuid,                -- FK -> customers.id
  address_type       text,                -- 'home' | 'pickup' | 'delivery'
  full_address       text,
  additional_details text,
  house_number       text,
  street_name        text,
  postcode           text,
  pincode            text,                -- legacy duplicate of postcode, kept in sync by app code
  city                text,
  latitude           double precision,
  longitude          double precision,
  is_selected        boolean DEFAULT false,
  created_at         timestamptz DEFAULT now()
);

-- ============================================================================
-- Orders and everything hanging off an order
-- ============================================================================

CREATE TABLE IF NOT EXISTS orders (
  id                     serial PRIMARY KEY,
  user_id                uuid NOT NULL,        -- FK -> customers.id
  manager_id             uuid,                 -- FK -> laundrymanager.user_id
  driver_id              uuid,                 -- FK -> driver.driver_id
  address_id             integer,              -- FK -> addresses.address_id (delivery)
  pickup_address_id      integer,              -- FK -> addresses.address_id
  use_same_address       boolean,
  subtotal               numeric,
  tip                    numeric,
  total                  numeric,
  discount_percent       numeric DEFAULT 0,
  discount_amount        numeric DEFAULT 0,
  has_discount           boolean DEFAULT false,
  wallet_applied         boolean DEFAULT false,
  wallet_used_amount     numeric DEFAULT 0,
  topup_amount           numeric DEFAULT 0,
  is_student             boolean DEFAULT false,
  student_id_image       text,
  collect_slot           text,
  delivery_slot          text,
  previous_collect_slot  text,
  previous_delivery_slot text,
  notes                  text,
  images                 text[] DEFAULT '{}',  -- UNCERTAIN: could be jsonb, see notes
  status                 text,                 -- e.g. 'NEW','COLLECT','PROCESSING','DELIVERED','REJECTED'
  statusbar              text,                 -- separate "display" status, e.g. 'PENDING','PICKED','EXPRESS','Dropped'
  more_time_keeping      text,                 -- UNCERTAIN type - only ever read/set as a passthrough value
  change_manager_requested boolean DEFAULT false,
  feedback_submitted     boolean DEFAULT false,
  reschedule_reason      text,
  rescheduled_at         timestamptz,
  driver_accepted_at     timestamptz,
  picked_time            timestamptz,
  prelaundry_time        timestamptz,
  postlaundry_time       timestamptz,
  delivery_time          timestamptz,
  dropped_time           timestamptz,
  delivered_to           text,
  created_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_created_at_idx ON orders (created_at);

CREATE TABLE IF NOT EXISTS order_items (
  order_item_id      serial PRIMARY KEY,
  order_id           integer NOT NULL,     -- FK -> orders.id
  product_id         integer NOT NULL,     -- FK -> products.id
  quantity           integer,
  price_at_purchase  numeric,
  received_quantity  integer,
  pass               boolean,              -- UNCERTAIN: could be text/enum instead of boolean
  post_pass          boolean               -- UNCERTAIN: same as above
);

CREATE TABLE IF NOT EXISTS order_logs (
  id         serial PRIMARY KEY,
  order_id   integer NOT NULL,             -- FK -> orders.id
  action     text NOT NULL,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_videos (
  id          serial PRIMARY KEY,
  order_id    integer NOT NULL,            -- FK -> orders.id
  customer_id uuid,                        -- FK -> customers.id
  video_type  text NOT NULL,
  s3_url      text NOT NULL,
  file_name   text,
  file_size   bigint,
  mime_type   text DEFAULT 'video/mp4',
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_videos_uploaded_at_idx ON order_videos (uploaded_at);

CREATE TABLE IF NOT EXISTS order_driver_images (
  id          serial PRIMARY KEY,
  order_id    integer NOT NULL,            -- FK -> orders.id
  image_data  text NOT NULL,               -- base64
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS driver_notes (
  id            serial PRIMARY KEY,
  order_id      integer NOT NULL,          -- FK -> orders.id
  driver_id     uuid NOT NULL,             -- FK -> driver.driver_id
  notes         text,
  ib_bags       integer DEFAULT 0,
  non_ib_bags   integer DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, driver_id)             -- required: app uses ON CONFLICT (order_id, driver_id)
);

CREATE TABLE IF NOT EXISTS driver_logs (
  id         serial PRIMARY KEY,
  driver_id  uuid,                         -- FK -> driver.driver_id
  order_id   integer,                      -- FK -> orders.id
  action     text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS driver_approvals (
  id          serial PRIMARY KEY,
  order_id    integer NOT NULL,            -- FK -> orders.id
  driver_id   uuid,                        -- FK -> driver.driver_id
  customer_id uuid,                        -- FK -> customers.id
  request_type text,
  status      text DEFAULT 'pending',      -- 'pending' | 'approved' | 'declined'
  token       text NOT NULL,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS driver_approvals_token_idx ON driver_approvals (token);

CREATE TABLE IF NOT EXISTS approval_requests (
  id             serial PRIMARY KEY,
  order_id       integer NOT NULL,         -- FK -> orders.id
  manager_id     uuid,                     -- FK -> laundrymanager.user_id
  type           text NOT NULL,            -- 'price' | 'time' | 'damage'
  note           text,
  requested_time numeric,                  -- minutes
  image_name     text,
  image_base64   text,
  status         text DEFAULT 'pending',   -- 'pending' | 'approved' | 'declined'
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS feedback (
  id                  serial PRIMARY KEY,
  order_id            integer,             -- FK -> orders.id; null for general app feedback (not tied to an order)
  user_id             uuid NOT NULL,       -- FK -> customers.id
  rating              numeric NOT NULL,
  comments            text,
  additional_feedback text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- Billing
-- ============================================================================

CREATE TABLE IF NOT EXISTS invoice (
  invoice_id             serial PRIMARY KEY,
  order_id               integer NOT NULL, -- FK -> orders.id
  customer_id            uuid,             -- FK -> customers.id
  manager_id             uuid,             -- FK -> laundrymanager.user_id
  subtotal               numeric,
  service_fee            numeric DEFAULT 0,
  tax                    numeric DEFAULT 0,
  delivery_fee           numeric DEFAULT 0,
  driver_tip             numeric DEFAULT 0,
  discount_percent       numeric DEFAULT 0,
  discount_amount        numeric DEFAULT 0,
  commission_percentage  numeric,
  commission_amount      numeric,
  total_amount           numeric NOT NULL,
  status                 text DEFAULT 'unpaid',  -- 'unpaid' | 'paid' | 'failed' | 'sent' (used inconsistently across endpoints)
  payment_method         text,
  stripe_payment_intent_id text,
  payment_link           text,
  invoice_date           timestamptz DEFAULT now(),
  created_at             timestamptz DEFAULT now(),
  updated_at             timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS invoice_order_id_idx ON invoice (order_id);  -- required: app uses ON CONFLICT (order_id)

CREATE TABLE IF NOT EXISTS commission_config (
  manager_id              uuid PRIMARY KEY,   -- FK -> laundrymanager.user_id
  first_order_percent     numeric NOT NULL DEFAULT 0.00,
  remaining_order_percent numeric NOT NULL DEFAULT 0.00,
  created_at              timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS customer_manager_mapping (
  customer_id uuid PRIMARY KEY,   -- FK -> customers.id
  manager_id  uuid NOT NULL       -- FK -> laundrymanager.user_id
);

CREATE TABLE IF NOT EXISTS discount_settings (
  id                    serial PRIMARY KEY,
  min_amount            numeric,
  max_amount            numeric,
  discount_percent      numeric,
  order_limit           integer,
  student_extra_percent numeric,
  is_active             boolean DEFAULT true
);

CREATE TABLE IF NOT EXISTS global_settings (
  id             integer PRIMARY KEY,   -- singleton row, id = 1
  service_charge numeric DEFAULT 0,
  minimum_amount numeric DEFAULT 0,
  updated_at     timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS referrals (
  id                   serial PRIMARY KEY,
  referrer_customer_id uuid NOT NULL,     -- FK -> customers.id
  referred_customer_id uuid NOT NULL,     -- FK -> customers.id
  referral_code_used   text,
  status               text DEFAULT 'pending',   -- 'pending' | 'successful'
  reward_granted       boolean DEFAULT false,
  order_id             integer,                  -- FK -> orders.id
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS referrals_referred_customer_idx ON referrals (referred_customer_id);

-- ============================================================================
-- Areas, slots, branches (delivery zone / scheduling config)
-- ============================================================================

CREATE TABLE IF NOT EXISTS postcodeareas (
  id              serial PRIMARY KEY,
  area_name       text,
  postcode_prefix text,
  delivery_type   text DEFAULT 'NORMAL'
);

-- Compatibility view: one older endpoint queries `postcode_areas` (underscore).
-- See decision #2 at the top of this file.
CREATE OR REPLACE VIEW postcode_areas AS SELECT * FROM postcodeareas;

CREATE TABLE IF NOT EXISTS slot_rules (
  id                     serial PRIMARY KEY,
  postcode_area_id       integer,     -- FK -> postcodeareas.id
  is_active              boolean DEFAULT true,
  slot_duration_hours    integer,
  min_delivery_days      integer DEFAULT 0,
  same_day_cutoff_hours  integer DEFAULT 0,
  pickup_window_start    text,        -- stored as "HH:MM" text, not native time (app does string.split(':'))
  pickup_window_end      text,
  delivery_window_start  text,
  delivery_window_end    text
);

CREATE TABLE IF NOT EXISTS daily_time_windows (
  id               serial PRIMARY KEY,
  postcode_area_id integer,     -- FK -> postcodeareas.id
  weekday          integer,     -- 1 (Mon) .. 7 (Sun)
  is_active        boolean DEFAULT true,
  start_time       text,        -- "HH:MM" text, see slot_rules note
  end_time         text
);

CREATE TABLE IF NOT EXISTS branches (
  id         serial PRIMARY KEY,
  name       text,
  postcodes  text[],
  -- NOTE: original code used a geography(Point,4326) column with
  -- ST_Distance/ST_DWithin/ST_MakePoint for proximity search, but this
  -- Postgres server doesn't have the postgis extension installed. Using
  -- plain lat/lng instead; the branch-proximity-search endpoint's SQL will
  -- need rewriting (e.g. haversine formula) to work against these columns,
  -- or ask your DB admin to install postgis and switch back.
  latitude   double precision,
  longitude  double precision,
  radius_km  numeric
);

-- ============================================================================
-- RingCentral calling
-- ============================================================================

CREATE TABLE IF NOT EXISTS ringcentral_numbers (
  phone_number text PRIMARY KEY,
  status       text DEFAULT 'available'   -- 'available' | 'busy'
);

CREATE TABLE IF NOT EXISTS ringcentral_call_sessions (
  id                 serial PRIMARY KEY,
  order_id           integer,            -- FK -> orders.id
  driver_id          uuid,               -- FK -> driver.driver_id
  customer_id        uuid,               -- FK -> customers.id
  ringcentral_number text,
  status             text,               -- e.g. 'initiated'
  external_call_id   text,               -- UNCERTAIN: code comment says "if you added column"
  started_at         timestamptz DEFAULT now()
);

-- ============================================================================
-- Misc
-- ============================================================================

CREATE TABLE IF NOT EXISTS notification_logs (
  id           serial PRIMARY KEY,
  target_token text,
  title        text,
  body         text,
  data         jsonb,
  message_id   text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app_settings (
  key         text PRIMARY KEY,   -- confirmed by code comment: this table has no created_at column
  value       text NOT NULL,
  description text,
  updated_at  timestamptz
);

-- ============================================================================
-- Seed data the app expects to already exist
-- ============================================================================

INSERT INTO global_settings (id, service_charge, minimum_amount)
VALUES (1, 0, 0)
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_types (id, name) VALUES
  (1, 'Standard'),
  (2, 'Premium')
ON CONFLICT (id) DO NOTHING;
