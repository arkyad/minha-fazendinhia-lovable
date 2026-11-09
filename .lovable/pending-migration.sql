-- Migração complementar: correções da auditoria (aguardando revisão)

-- ===== 1. Schema privado para funções auxiliares (não exposto pela API) =====
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

-- Mover preserva as referências das políticas RLS e do Storage (ligadas pelo identificador interno)
ALTER FUNCTION public.has_role(uuid, public.app_role) SET SCHEMA private;
ALTER FUNCTION public.owns_property(uuid, uuid) SET SCHEMA private;
ALTER FUNCTION public.is_public_property(uuid) SET SCHEMA private;
ALTER FUNCTION public.can_manage_property_folder(uuid, text) SET SCHEMA private;
ALTER FUNCTION public.get_setting(text) SET SCHEMA private;
DROP FUNCTION public.hit_rate_limit(text, integer, integer);

-- ===== 2. Status da propriedade =====
CREATE TYPE public.property_status AS ENUM ('draft', 'published', 'suspended');
ALTER TABLE public.properties ADD COLUMN status public.property_status NOT NULL DEFAULT 'draft';
ALTER TABLE public.properties ALTER COLUMN is_active SET DEFAULT false;
COMMENT ON COLUMN public.properties.is_active IS 'DEPRECATED: replaced by status; kept in sync (status = published) by trigger';
CREATE INDEX properties_status_idx ON public.properties(status);

-- ===== 3. Funções auxiliares (schema privado) =====
CREATE OR REPLACE FUNCTION private.is_public_property(_property_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.properties WHERE id = _property_id AND status = 'published')
$$;

CREATE OR REPLACE FUNCTION private.can_manage_property_folder(_user_id uuid, _folder text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  IF _user_id IS NULL THEN RETURN false; END IF;
  IF private.has_role(_user_id, 'admin') THEN RETURN true; END IF;
  BEGIN pid := _folder::uuid; EXCEPTION WHEN others THEN RETURN false; END;
  RETURN private.owns_property(_user_id, pid);
END; $$;

-- Executa com o papel de quem chama: verdadeiro só para admin ou acesso de serviço
CREATE OR REPLACE FUNCTION private.is_privileged()
RETURNS boolean LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT current_user IN ('postgres', 'service_role', 'supabase_admin')
      OR private.has_role(auth.uid(), 'admin')
$$;

-- Contagem atômica: um único upsert por chave; retorna true se o limite foi excedido.
-- Sem janela configurada não há contagem; sem máximo configurado conta, mas não bloqueia.
CREATE OR REPLACE FUNCTION private.rate_limit_hit(_bucket text, _window_seconds integer, _max integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ws timestamptz; n integer;
BEGIN
  IF _window_seconds IS NULL THEN RETURN false; END IF;
  ws := to_timestamp(floor(extract(epoch FROM now()) / _window_seconds) * _window_seconds);
  DELETE FROM public.order_rate_limits WHERE bucket_key = _bucket AND window_start < ws;
  INSERT INTO public.order_rate_limits AS r (bucket_key, window_start, hits) VALUES (_bucket, ws, 1)
  ON CONFLICT (bucket_key, window_start) DO UPDATE SET hits = r.hits + 1
  RETURNING r.hits INTO n;
  RETURN _max IS NOT NULL AND n > _max;
END; $$;

-- ===== 4. Gatilho de propriedade: dono, status e sincronização de is_active =====
CREATE OR REPLACE FUNCTION public.guard_property_write()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' AND NOT private.is_privileged() THEN
      RAISE EXCEPTION 'A new property must start as draft';
    END IF;
  ELSE
    IF NEW.owner_id <> OLD.owner_id AND NOT private.is_privileged() THEN
      RAISE EXCEPTION 'Only an admin can change the property owner';
    END IF;
    IF NEW.status <> OLD.status AND NOT private.is_privileged() THEN
      RAISE EXCEPTION 'Only an admin can change the property status';
    END IF;
  END IF;
  NEW.is_active := (NEW.status = 'published');
  RETURN NEW;
END; $$;

DROP TRIGGER trg_guard_property ON public.properties;
DROP FUNCTION public.guard_property_update();
CREATE TRIGGER trg_guard_property BEFORE INSERT OR UPDATE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION public.guard_property_write();

ALTER POLICY "read properties" ON public.properties
  USING (status = 'published' OR owner_id = auth.uid() OR private.has_role(auth.uid(), 'admin'));

-- ===== 5. Sem exclusão física =====
DROP POLICY "admin delete property" ON public.properties;
DROP POLICY "admin delete products" ON public.products;

CREATE OR REPLACE FUNCTION public.block_physical_delete()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION '% rows cannot be deleted; deactivate instead', TG_TABLE_NAME; END; $$;

CREATE TRIGGER trg_block_delete BEFORE DELETE ON public.properties FOR EACH ROW EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_delete BEFORE DELETE ON public.products FOR EACH ROW EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.properties FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.products FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.customers FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.orders FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.order_items FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();
CREATE TRIGGER trg_block_truncate BEFORE TRUNCATE ON public.order_status_history FOR EACH STATEMENT EXECUTE FUNCTION public.block_physical_delete();

ALTER TABLE public.property_images
  DROP CONSTRAINT property_images_property_id_fkey,
  ADD CONSTRAINT property_images_property_id_fkey FOREIGN KEY (property_id)
    REFERENCES public.properties(id) ON DELETE RESTRICT;
ALTER TABLE public.product_images
  DROP CONSTRAINT product_images_product_id_fkey,
  ADD CONSTRAINT product_images_product_id_fkey FOREIGN KEY (product_id)
    REFERENCES public.products(id) ON DELETE RESTRICT;

-- ===== 6. update_order_status (referências ao schema privado) =====
CREATE OR REPLACE FUNCTION public.update_order_status(p_order_id uuid, p_new_status public.order_status, p_note text DEFAULT NULL)
RETURNS public.order_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order public.orders%ROWTYPE; v_ok boolean; v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NOT_AUTHENTICATED'; END IF;
  IF p_note IS NOT NULL AND char_length(p_note) > 500 THEN RAISE EXCEPTION 'INVALID_NOTE'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT (private.owns_property(v_uid, v_order.property_id) OR private.has_role(v_uid, 'admin')) THEN
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

-- ===== 7. place_order: contagem antes de tudo, bloco protegido, resposta estruturada =====
CREATE OR REPLACE FUNCTION public.place_order(p_idempotency_key uuid, p_property_id uuid, p_customer jsonb, p_items jsonb, p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_prop public.properties%ROWTYPE;
  v_prop_exists boolean;
  v_is_obj boolean := jsonb_typeof(p_customer) = 'object';
  v_name text; v_phone text; v_address text; v_notes text;
  v_hash text; v_existing public.orders%ROWTYPE;
  v_hit_phone boolean := false; v_hit_prop boolean := false;
  v_max_items integer; v_max_qty integer; v_count integer;
  v_item jsonb; v_pid uuid; v_qty integer; v_prod public.products%ROWTYPE;
  v_subtotal numeric(12,2) := 0;
  v_customer_id uuid; v_order_id uuid; v_code text;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  -- 1. Formato mínimo: sem chave ou propriedade não há como contar
  IF p_idempotency_key IS NULL OR p_property_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_REQUEST');
  END IF;
  v_name    := btrim(coalesce(CASE WHEN v_is_obj THEN p_customer->>'name' END, ''));
  v_phone   := regexp_replace(coalesce(CASE WHEN v_is_obj THEN p_customer->>'phone' END, ''), '\D', '', 'g');
  v_address := NULLIF(btrim(coalesce(CASE WHEN v_is_obj THEN p_customer->>'address' END, '')), '');
  v_notes   := NULLIF(btrim(coalesce(p_notes, '')), '');
  v_hash := md5(jsonb_build_object('p', p_property_id, 'n', v_name, 'ph', v_phone, 'a', v_address,
                                   'no', v_notes, 'i', p_items)::text);

  -- 2. Idempotência: repetição legítima devolve o mesmo pedido e não conta
  PERFORM pg_advisory_xact_lock(hashtext(p_idempotency_key::text));
  SELECT * INTO v_existing FROM public.orders WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL AND v_existing.request_hash = v_hash THEN
    RETURN jsonb_build_object('ok', true, 'code', v_existing.code, 'total', v_existing.total,
      'whatsapp', (SELECT whatsapp FROM public.properties WHERE id = v_existing.property_id), 'replayed', true);
  END IF;

  -- 3. Proteção obrigatória: sem os 4 parâmetros anti-spam, pedidos públicos ficam bloqueados
  IF private.get_setting('rate_limit_phone_window_seconds') IS NULL
     OR private.get_setting('rate_limit_phone_max') IS NULL
     OR private.get_setting('rate_limit_property_window_seconds') IS NULL
     OR private.get_setting('rate_limit_property_max') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ORDERS_DISABLED');
  END IF;

  -- 4. Contagem atômica antes de qualquer outra validação (fica fora do bloco que pode ser desfeito)
  v_prop_exists := EXISTS (SELECT 1 FROM public.properties WHERE id = p_property_id);
  IF v_prop_exists AND v_phone ~ '^[0-9]{10,15}$' THEN
    v_hit_phone := private.rate_limit_hit('phone:' || p_property_id || ':' || v_phone,
      private.get_setting('rate_limit_phone_window_seconds'), private.get_setting('rate_limit_phone_max'));
  END IF;
  v_hit_prop := private.rate_limit_hit(
    CASE WHEN v_prop_exists THEN 'property:' || p_property_id ELSE 'property:unknown' END,
    private.get_setting('rate_limit_property_window_seconds'), private.get_setting('rate_limit_property_max'));

  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'IDEMPOTENCY_CONFLICT');
  END IF;
  IF v_hit_phone OR v_hit_prop THEN
    RETURN jsonb_build_object('ok', false, 'error', 'RATE_LIMITED');
  END IF;

  -- 5. Bloco protegido: qualquer falha desfaz só o pedido; os contadores permanecem
  BEGIN
    IF NOT coalesce(v_is_obj, false) THEN RAISE EXCEPTION 'INVALID_CUSTOMER'; END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'INVALID_ITEMS'; END IF;
    IF char_length(v_name) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'INVALID_NAME'; END IF;
    IF v_phone !~ '^[0-9]{10,15}$' THEN RAISE EXCEPTION 'INVALID_PHONE'; END IF;
    IF v_address IS NOT NULL AND char_length(v_address) > 500 THEN RAISE EXCEPTION 'INVALID_ADDRESS'; END IF;
    IF v_notes IS NOT NULL AND char_length(v_notes) > 1000 THEN RAISE EXCEPTION 'INVALID_NOTES'; END IF;

    SELECT * INTO v_prop FROM public.properties WHERE id = p_property_id AND status = 'published';
    IF NOT FOUND THEN RAISE EXCEPTION 'PROPERTY_UNAVAILABLE'; END IF;

    v_count := jsonb_array_length(p_items);
    v_max_items := private.get_setting('max_items_per_order');
    v_max_qty := private.get_setting('max_quantity_per_item');
    IF v_count = 0 OR (v_max_items IS NOT NULL AND v_count > v_max_items) THEN RAISE EXCEPTION 'INVALID_ITEM_COUNT'; END IF;
    IF (SELECT count(DISTINCT e->>'product_id') FROM jsonb_array_elements(p_items) e) <> v_count THEN
      RAISE EXCEPTION 'DUPLICATE_ITEMS';
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      IF jsonb_typeof(v_item) <> 'object' OR jsonb_typeof(v_item->'quantity') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'INVALID_ITEM';
      END IF;
      BEGIN v_pid := (v_item->>'product_id')::uuid; EXCEPTION WHEN others THEN RAISE EXCEPTION 'INVALID_ITEM'; END;
      IF v_pid IS NULL THEN RAISE EXCEPTION 'INVALID_ITEM'; END IF;
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
  EXCEPTION
    WHEN raise_exception THEN
      RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    WHEN others THEN
      RAISE WARNING 'place_order failed: % (%)', SQLERRM, SQLSTATE;
      RETURN jsonb_build_object('ok', false, 'error', 'INTERNAL_ERROR');
  END;

  RETURN jsonb_build_object('ok', true, 'code', v_code, 'total', v_subtotal,
                            'whatsapp', v_prop.whatsapp, 'replayed', false);
END; $$;

-- ===== 8. Privilégios mínimos =====
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.categories, public.properties, public.property_images,
  public.products, public.product_images TO anon;
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.categories, public.property_images,
  public.product_images, public.app_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.properties, public.products TO authenticated;
GRANT SELECT ON public.customers, public.orders, public.order_items, public.order_status_history TO authenticated;

GRANT EXECUTE ON FUNCTION public.place_order(uuid, uuid, jsonb, jsonb, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_order_status(uuid, public.order_status, text) TO authenticated;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.has_role(uuid, public.app_role),
  private.owns_property(uuid, uuid), private.is_public_property(uuid),
  private.can_manage_property_folder(uuid, text), private.is_privileged()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.get_setting(text), private.rate_limit_hit(text, integer, integer) TO service_role;
