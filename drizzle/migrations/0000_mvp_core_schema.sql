
-- ===== ENUMS =====
CREATE TYPE public.app_role AS ENUM ('admin', 'producer');
CREATE TYPE public.order_status AS ENUM ('awaiting_contact','received','accepted','rejected','completed','cancelled');

-- ===== GENERIC updated_at =====
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;

-- ===== TABLES =====
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text CHECK (full_name IS NULL OR char_length(full_name) <= 120),
  phone text CHECK (phone IS NULL OR phone ~ '^[0-9]{10,15}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 80),
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.properties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(slug) <= 120),
  description text CHECK (description IS NULL OR char_length(description) <= 4000),
  city text CHECK (city IS NULL OR char_length(city) <= 120),
  state text CHECK (state IS NULL OR char_length(state) <= 60),
  whatsapp text NOT NULL CHECK (whatsapp ~ '^[0-9]{10,15}$'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX properties_owner_idx ON public.properties(owner_id);

CREATE TABLE public.property_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  storage_path text NOT NULL CHECK (char_length(storage_path) BETWEEN 1 AND 500),
  sort_order integer NOT NULL DEFAULT 0,
  is_cover boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX property_images_property_idx ON public.property_images(property_id);
CREATE UNIQUE INDEX property_images_one_cover ON public.property_images(property_id) WHERE is_cover;

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE RESTRICT,
  category_id uuid NOT NULL REFERENCES public.categories(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  description text CHECK (description IS NULL OR char_length(description) <= 4000),
  unit text NOT NULL CHECK (char_length(unit) BETWEEN 1 AND 30),
  price numeric(12,2) NOT NULL CHECK (price >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX products_property_active_idx ON public.products(property_id, is_active);
CREATE INDEX products_category_idx ON public.products(category_id);

CREATE TABLE public.product_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  storage_path text NOT NULL CHECK (char_length(storage_path) BETWEEN 1 AND 500),
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX product_images_product_idx ON public.product_images(product_id);

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  phone text NOT NULL CHECK (phone ~ '^[0-9]{10,15}$'),
  address text CHECK (address IS NULL OR char_length(address) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (property_id, phone),
  UNIQUE (id, property_id)
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL,
  code text NOT NULL UNIQUE,
  idempotency_key uuid NOT NULL UNIQUE,
  request_hash text NOT NULL,
  status public.order_status NOT NULL DEFAULT 'awaiting_contact',
  subtotal numeric(12,2) NOT NULL CHECK (subtotal >= 0),
  total numeric(12,2) NOT NULL CHECK (total >= 0 AND total = subtotal),
  notes text CHECK (notes IS NULL OR char_length(notes) <= 1000),
  customer_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (customer_id, property_id) REFERENCES public.customers(id, property_id) ON DELETE RESTRICT
);
CREATE INDEX orders_property_status_created_idx ON public.orders(property_id, status, created_at DESC);
CREATE INDEX orders_customer_idx ON public.orders(customer_id);

CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name text NOT NULL,
  unit text NOT NULL,
  unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  quantity integer NOT NULL CHECK (quantity > 0),
  line_total numeric(12,2) NOT NULL CHECK (line_total = unit_price * quantity),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, product_id)
);
CREATE INDEX order_items_product_idx ON public.order_items(product_id);

CREATE TABLE public.order_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  from_status public.order_status,
  to_status public.order_status NOT NULL,
  changed_by uuid,
  note text CHECK (note IS NULL OR char_length(note) <= 500),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_status_history_order_idx ON public.order_status_history(order_id, created_at);

CREATE TABLE public.app_settings (
  key text PRIMARY KEY CHECK (key IN (
    'rate_limit_phone_window_seconds','rate_limit_phone_max',
    'rate_limit_property_window_seconds','rate_limit_property_max',
    'max_items_per_order','max_quantity_per_item')),
  value integer CHECK (value IS NULL OR value > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.order_rate_limits (
  bucket_key text NOT NULL,
  window_start timestamptz NOT NULL,
  hits integer NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket_key, window_start)
);

-- ===== GRANTS =====
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT SELECT ON public.categories TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.categories TO authenticated;
GRANT SELECT ON public.properties, public.property_images, public.products, public.product_images TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.properties, public.property_images, public.products, public.product_images TO authenticated;
GRANT SELECT ON public.customers, public.orders, public.order_items, public.order_status_history TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.app_settings TO authenticated;
GRANT ALL ON public.profiles, public.user_roles, public.categories, public.properties, public.property_images,
  public.products, public.product_images, public.customers, public.orders, public.order_items,
  public.order_status_history, public.app_settings, public.order_rate_limits TO service_role;

-- ===== RLS ON =====
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_rate_limits ENABLE ROW LEVEL SECURITY;

-- ===== HELPERS =====
CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE OR REPLACE FUNCTION public.owns_property(_user_id uuid, _property_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.properties WHERE id = _property_id AND owner_id = _user_id)
$$;

CREATE OR REPLACE FUNCTION public.is_public_property(_property_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.properties WHERE id = _property_id AND is_active)
$$;

CREATE OR REPLACE FUNCTION public.can_manage_property_folder(_user_id uuid, _folder text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  IF _user_id IS NULL THEN RETURN false; END IF;
  IF public.has_role(_user_id, 'admin') THEN RETURN true; END IF;
  BEGIN pid := _folder::uuid; EXCEPTION WHEN others THEN RETURN false; END;
  RETURN public.owns_property(_user_id, pid);
END; $$;

-- ===== POLICIES =====
-- profiles
CREATE POLICY "own profile read" ON public.profiles FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "own profile update" ON public.profiles FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- user_roles
CREATE POLICY "read own roles" ON public.user_roles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin insert roles" ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete roles" ON public.user_roles FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

-- categories
CREATE POLICY "public read active categories" ON public.categories FOR SELECT TO anon, authenticated
  USING (is_active OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin insert categories" ON public.categories FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin update categories" ON public.categories FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete categories" ON public.categories FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

-- properties
CREATE POLICY "read properties" ON public.properties FOR SELECT TO anon, authenticated
  USING (is_active OR owner_id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "producer insert own property" ON public.properties FOR INSERT TO authenticated
  WITH CHECK ((owner_id = auth.uid() AND public.has_role(auth.uid(),'producer')) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "owner update property" ON public.properties FOR UPDATE TO authenticated
  USING (owner_id = auth.uid() OR public.has_role(auth.uid(),'admin'))
  WITH CHECK (owner_id = auth.uid() OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete property" ON public.properties FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

-- property_images
CREATE POLICY "read property images" ON public.property_images FOR SELECT TO anon, authenticated
  USING (public.is_public_property(property_id) OR public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "manage property images ins" ON public.property_images FOR INSERT TO authenticated
  WITH CHECK (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "manage property images upd" ON public.property_images FOR UPDATE TO authenticated
  USING (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'))
  WITH CHECK (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "manage property images del" ON public.property_images FOR DELETE TO authenticated
  USING (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));

-- products
CREATE POLICY "read products" ON public.products FOR SELECT TO anon, authenticated
  USING ((is_active AND public.is_public_property(property_id)) OR public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "owner insert products" ON public.products FOR INSERT TO authenticated
  WITH CHECK (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "owner update products" ON public.products FOR UPDATE TO authenticated
  USING (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'))
  WITH CHECK (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete products" ON public.products FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

-- product_images
CREATE POLICY "read product images" ON public.product_images FOR SELECT TO anon, authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND (
    (p.is_active AND public.is_public_property(p.property_id)) OR public.owns_property(auth.uid(), p.property_id) OR public.has_role(auth.uid(),'admin'))));
CREATE POLICY "manage product images ins" ON public.product_images FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND (public.owns_property(auth.uid(), p.property_id) OR public.has_role(auth.uid(),'admin'))));
CREATE POLICY "manage product images upd" ON public.product_images FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND (public.owns_property(auth.uid(), p.property_id) OR public.has_role(auth.uid(),'admin'))))
  WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND (public.owns_property(auth.uid(), p.property_id) OR public.has_role(auth.uid(),'admin'))));
CREATE POLICY "manage product images del" ON public.product_images FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_id AND (public.owns_property(auth.uid(), p.property_id) OR public.has_role(auth.uid(),'admin'))));

-- customers / orders / items / history: read-only
CREATE POLICY "read customers" ON public.customers FOR SELECT TO authenticated
  USING (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "read orders" ON public.orders FOR SELECT TO authenticated
  USING (public.owns_property(auth.uid(), property_id) OR public.has_role(auth.uid(),'admin'));
CREATE POLICY "read order items" ON public.order_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (public.owns_property(auth.uid(), o.property_id) OR public.has_role(auth.uid(),'admin'))));
CREATE POLICY "read order history" ON public.order_status_history FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND (public.owns_property(auth.uid(), o.property_id) OR public.has_role(auth.uid(),'admin'))));

-- app_settings: admin only
CREATE POLICY "admin read settings" ON public.app_settings FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin insert settings" ON public.app_settings FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin update settings" ON public.app_settings FOR UPDATE TO authenticated USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete settings" ON public.app_settings FOR DELETE TO authenticated USING (public.has_role(auth.uid(),'admin'));
-- order_rate_limits: no policies (functions only)

-- ===== TRIGGERS =====
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_categories_updated BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_properties_updated BEFORE UPDATE ON public.properties FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_products_updated BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_settings_updated BEFORE UPDATE ON public.app_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.guard_property_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.owner_id <> OLD.owner_id AND NOT public.has_role(auth.uid(),'admin')
     AND current_user NOT IN ('postgres','service_role','supabase_admin') THEN
    RAISE EXCEPTION 'Only an admin can change the property owner';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_property BEFORE UPDATE ON public.properties FOR EACH ROW EXECUTE FUNCTION public.guard_property_update();

CREATE OR REPLACE FUNCTION public.guard_product_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.property_id <> OLD.property_id THEN RAISE EXCEPTION 'A product cannot move to another property'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_product BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.guard_product_update();

CREATE OR REPLACE FUNCTION public.guard_product_image_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.product_id <> OLD.product_id THEN RAISE EXCEPTION 'An image cannot move to another product'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_product_image BEFORE UPDATE ON public.product_images FOR EACH ROW EXECUTE FUNCTION public.guard_product_image_update();

CREATE OR REPLACE FUNCTION public.guard_property_image_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.property_id <> OLD.property_id THEN RAISE EXCEPTION 'An image cannot move to another property'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_property_image BEFORE UPDATE ON public.property_images FOR EACH ROW EXECUTE FUNCTION public.guard_property_image_update();

CREATE OR REPLACE FUNCTION public.guard_order_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Orders cannot be deleted'; END IF;
  IF NEW.id <> OLD.id OR NEW.property_id <> OLD.property_id OR NEW.customer_id <> OLD.customer_id
     OR NEW.code <> OLD.code OR NEW.idempotency_key <> OLD.idempotency_key OR NEW.request_hash <> OLD.request_hash
     OR NEW.subtotal <> OLD.subtotal OR NEW.total <> OLD.total
     OR NEW.notes IS DISTINCT FROM OLD.notes OR NEW.customer_snapshot <> OLD.customer_snapshot
     OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'Order data is immutable';
  END IF;
  IF NEW.status <> OLD.status AND coalesce(current_setting('app.order_status_change', true),'') <> 'on' THEN
    RAISE EXCEPTION 'Order status can only change through update_order_status';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_order BEFORE UPDATE OR DELETE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.guard_order_change();

CREATE OR REPLACE FUNCTION public.block_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION '% rows are immutable', TG_TABLE_NAME; END; $$;
CREATE TRIGGER trg_items_immutable BEFORE UPDATE OR DELETE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.block_mutation();
CREATE TRIGGER trg_history_immutable BEFORE UPDATE OR DELETE ON public.order_status_history FOR EACH ROW EXECUTE FUNCTION public.block_mutation();

-- signup: profile + producer role
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, left(NULLIF(NEW.raw_user_meta_data->>'full_name',''), 120))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'producer') ON CONFLICT DO NOTHING;
  RETURN NEW;
END; $$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ===== SETTINGS + RATE LIMIT =====
CREATE OR REPLACE FUNCTION public.get_setting(_key text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT value FROM public.app_settings WHERE key = _key
$$;

CREATE OR REPLACE FUNCTION public.hit_rate_limit(_bucket text, _window_seconds integer, _max integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ws timestamptz; n integer;
BEGIN
  IF _window_seconds IS NULL OR _max IS NULL THEN RETURN; END IF;
  ws := to_timestamp(floor(extract(epoch FROM now()) / _window_seconds) * _window_seconds);
  DELETE FROM public.order_rate_limits WHERE bucket_key = _bucket AND window_start < ws;
  INSERT INTO public.order_rate_limits (bucket_key, window_start, hits) VALUES (_bucket, ws, 1)
  ON CONFLICT (bucket_key, window_start) DO UPDATE SET hits = public.order_rate_limits.hits + 1
  RETURNING hits INTO n;
  IF n > _max THEN RAISE EXCEPTION 'RATE_LIMITED' USING ERRCODE = 'P0429'; END IF;
END; $$;

-- ===== PLACE ORDER (public) =====
CREATE OR REPLACE FUNCTION public.place_order(
  p_idempotency_key uuid, p_property_id uuid, p_customer jsonb, p_items jsonb, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prop public.properties%ROWTYPE;
  v_name text; v_phone text; v_address text; v_notes text;
  v_hash text; v_existing public.orders%ROWTYPE;
  v_max_items integer; v_max_qty integer; v_count integer;
  v_item jsonb; v_pid uuid; v_qty integer; v_prod public.products%ROWTYPE;
  v_subtotal numeric(12,2) := 0;
  v_customer_id uuid; v_order_id uuid; v_code text;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  IF p_idempotency_key IS NULL OR p_property_id IS NULL THEN RAISE EXCEPTION 'INVALID_REQUEST'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'INVALID_ITEMS'; END IF;
  IF p_customer IS NULL OR jsonb_typeof(p_customer) <> 'object' THEN RAISE EXCEPTION 'INVALID_CUSTOMER'; END IF;

  v_name := btrim(coalesce(p_customer->>'name',''));
  v_phone := regexp_replace(coalesce(p_customer->>'phone',''), '\D', '', 'g');
  v_address := NULLIF(btrim(coalesce(p_customer->>'address','')), '');
  v_notes := NULLIF(btrim(coalesce(p_notes,'')), '');
  IF char_length(v_name) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'INVALID_NAME'; END IF;
  IF v_phone !~ '^[0-9]{10,15}$' THEN RAISE EXCEPTION 'INVALID_PHONE'; END IF;
  IF v_address IS NOT NULL AND char_length(v_address) > 500 THEN RAISE EXCEPTION 'INVALID_ADDRESS'; END IF;
  IF v_notes IS NOT NULL AND char_length(v_notes) > 1000 THEN RAISE EXCEPTION 'INVALID_NOTES'; END IF;

  v_hash := md5(jsonb_build_object('p', p_property_id, 'n', v_name, 'ph', v_phone, 'a', v_address,
                 'no', v_notes, 'i', p_items)::text);

  -- idempotency (serialize same key)
  PERFORM pg_advisory_xact_lock(hashtext(p_idempotency_key::text));
  SELECT * INTO v_existing FROM public.orders WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN jsonb_build_object('code', v_existing.code, 'total', v_existing.total,
      'whatsapp', (SELECT whatsapp FROM public.properties WHERE id = v_existing.property_id), 'replayed', true);
  END IF;

  SELECT * INTO v_prop FROM public.properties WHERE id = p_property_id AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPERTY_UNAVAILABLE'; END IF;

  -- rate limits (disabled while settings are empty)
  PERFORM public.hit_rate_limit('phone:' || p_property_id || ':' || v_phone,
    public.get_setting('rate_limit_phone_window_seconds'), public.get_setting('rate_limit_phone_max'));
  PERFORM public.hit_rate_limit('property:' || p_property_id,
    public.get_setting('rate_limit_property_window_seconds'), public.get_setting('rate_limit_property_max'));

  v_count := jsonb_array_length(p_items);
  v_max_items := public.get_setting('max_items_per_order');
  v_max_qty := public.get_setting('max_quantity_per_item');
  IF v_count = 0 OR (v_max_items IS NOT NULL AND v_count > v_max_items) THEN RAISE EXCEPTION 'INVALID_ITEM_COUNT'; END IF;
  IF (SELECT count(DISTINCT e->>'product_id') FROM jsonb_array_elements(p_items) e) <> v_count THEN
    RAISE EXCEPTION 'DUPLICATE_ITEMS';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(v_item) <> 'object' OR jsonb_typeof(v_item->'quantity') <> 'number' THEN RAISE EXCEPTION 'INVALID_ITEM'; END IF;
    BEGIN v_pid := (v_item->>'product_id')::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'INVALID_ITEM'; END;
    IF (v_item->>'quantity')::numeric <> trunc((v_item->>'quantity')::numeric)
       OR (v_item->>'quantity')::numeric < 1 OR (v_item->>'quantity')::numeric > 2147483647 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY';
    END IF;
    v_qty := (v_item->>'quantity')::integer;
    IF v_max_qty IS NOT NULL AND v_qty > v_max_qty THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;

    SELECT * INTO v_prod FROM public.products WHERE id = v_pid AND property_id = p_property_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_UNAVAILABLE'; END IF;

    v_subtotal := v_subtotal + v_prod.price * v_qty;
    v_lines := v_lines || jsonb_build_object('product_id', v_prod.id, 'name', v_prod.name, 'unit', v_prod.unit,
                                             'price', v_prod.price, 'qty', v_qty);
  END LOOP;

  INSERT INTO public.customers (property_id, name, phone, address)
  VALUES (p_property_id, v_name, v_phone, v_address)
  ON CONFLICT (property_id, phone) DO UPDATE
    SET name = EXCLUDED.name, address = coalesce(EXCLUDED.address, public.customers.address)
  RETURNING id INTO v_customer_id;

  LOOP
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.orders WHERE code = v_code);
  END LOOP;

  INSERT INTO public.orders (property_id, customer_id, code, idempotency_key, request_hash, status,
                             subtotal, total, notes, customer_snapshot)
  VALUES (p_property_id, v_customer_id, v_code, p_idempotency_key, v_hash, 'awaiting_contact',
          v_subtotal, v_subtotal, v_notes,
          jsonb_build_object('name', v_name, 'phone', v_phone, 'address', v_address))
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, unit, unit_price, quantity, line_total)
  SELECT v_order_id, (l->>'product_id')::uuid, l->>'name', l->>'unit', (l->>'price')::numeric,
         (l->>'qty')::integer, (l->>'price')::numeric * (l->>'qty')::integer
  FROM jsonb_array_elements(v_lines) l;

  INSERT INTO public.order_status_history (order_id, from_status, to_status, changed_by)
  VALUES (v_order_id, NULL, 'awaiting_contact', NULL);

  RETURN jsonb_build_object('code', v_code, 'total', v_subtotal, 'whatsapp', v_prop.whatsapp, 'replayed', false);
END; $$;

-- ===== UPDATE STATUS (authorized) =====
CREATE OR REPLACE FUNCTION public.update_order_status(p_order_id uuid, p_new_status public.order_status, p_note text DEFAULT NULL)
RETURNS public.order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE; v_ok boolean; v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF p_note IS NOT NULL AND char_length(p_note) > 500 THEN RAISE EXCEPTION 'INVALID_NOTE'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.owns_property(v_uid, v_order.property_id) OR public.has_role(v_uid, 'admin')) THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  v_ok := CASE v_order.status
    WHEN 'awaiting_contact' THEN p_new_status IN ('received','cancelled')
    WHEN 'received' THEN p_new_status IN ('accepted','rejected','cancelled')
    WHEN 'accepted' THEN p_new_status IN ('completed','cancelled')
    ELSE false END;
  IF NOT v_ok THEN RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;

  PERFORM set_config('app.order_status_change', 'on', true);
  UPDATE public.orders SET status = p_new_status WHERE id = p_order_id;
  PERFORM set_config('app.order_status_change', 'off', true);

  INSERT INTO public.order_status_history (order_id, from_status, to_status, changed_by, note)
  VALUES (p_order_id, v_order.status, p_new_status, v_uid, NULLIF(btrim(p_note), ''));
  RETURN p_new_status;
END; $$;

-- ===== FUNCTION PRIVILEGES =====
REVOKE ALL ON FUNCTION public.set_updated_at(), public.guard_property_update(), public.guard_product_update(),
  public.guard_product_image_update(), public.guard_property_image_update(), public.guard_order_change(),
  public.block_mutation(), public.handle_new_user(), public.get_setting(text),
  public.hit_rate_limit(text, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.place_order(uuid, uuid, jsonb, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order(uuid, uuid, jsonb, jsonb, text) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.update_order_status(uuid, public.order_status, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_order_status(uuid, public.order_status, text) TO authenticated;
