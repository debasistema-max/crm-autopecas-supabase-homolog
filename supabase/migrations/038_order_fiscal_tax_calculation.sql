begin;

alter table public.products
  add column if not exists ncm text;

alter table public.products
  drop constraint if exists products_ncm_format_check;

alter table public.products
  add constraint products_ncm_format_check
  check (ncm is null or ncm ~ '^[0-9]{8}$');

alter table public.order_items
  add column if not exists preco_sem_imposto_unitario numeric(14,4),
  add column if not exists imposto_unitario numeric(14,4),
  add column if not exists fiscal_tax_rule_id uuid references public.fiscal_tax_rules(id) on delete set null,
  add column if not exists fiscal_status text,
  add column if not exists fiscal_details jsonb;

alter table public.quotation_items
  add column if not exists preco_sem_imposto_unitario numeric(14,4),
  add column if not exists imposto_unitario numeric(14,4),
  add column if not exists fiscal_tax_rule_id uuid references public.fiscal_tax_rules(id) on delete set null,
  add column if not exists fiscal_status text,
  add column if not exists fiscal_details jsonb;

create or replace function public.normalize_ncm(ncm_text text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(coalesce(ncm_text, ''), '\D', '', 'g'), '')
$$;

create or replace function public.resolve_fiscal_tax_rule(
  target_ncm text,
  source_uf text,
  target_uf text,
  target_customer_type text default 'GERAL',
  target_date date default current_date
)
returns public.fiscal_tax_rules
language sql
stable
security definer
set search_path = public
as $$
  select r
  from public.fiscal_tax_rules r
  where r.active
    and r.ncm = public.normalize_ncm(target_ncm)
    and r.uf_origem = upper(btrim(coalesce(source_uf, '')))
    and r.uf_destino = upper(btrim(coalesce(target_uf, '')))
    and r.customer_type in (upper(btrim(coalesce(target_customer_type, 'GERAL'))), 'GERAL')
    and r.effective_from <= coalesce(target_date, current_date)
    and (r.effective_to is null or r.effective_to >= coalesce(target_date, current_date))
  order by case when r.customer_type = upper(btrim(coalesce(target_customer_type, 'GERAL'))) then 0 else 1 end,
           r.effective_from desc,
           r.created_at desc
  limit 1
$$;

create or replace function public.calculate_taxed_unit_price(base_price numeric, rule_row public.fiscal_tax_rules)
returns jsonb
language plpgsql
immutable
as $$
declare
  base numeric := round(coalesce(base_price, 0), 4);
  icms numeric := 0;
  ipi numeric := 0;
  pis numeric := 0;
  cofins numeric := 0;
  fcp numeric := 0;
  icms_st numeric := 0;
  tax_total numeric := 0;
  final_price numeric := 0;
begin
  if rule_row.id is null or base <= 0 then
    return jsonb_build_object(
      'status', 'NO_RULE',
      'base_price', base,
      'tax_total', 0,
      'final_price', base
    );
  end if;

  icms := round(base * coalesce(rule_row.icms_percent, 0) / 100, 4);
  ipi := round(base * coalesce(rule_row.ipi_percent, 0) / 100, 4);
  pis := round(base * coalesce(rule_row.pis_percent, 0) / 100, 4);
  cofins := round(base * coalesce(rule_row.cofins_percent, 0) / 100, 4);
  fcp := round(base * coalesce(rule_row.fcp_percent, 0) / 100, 4);
  icms_st := round((base * (1 + coalesce(rule_row.mva_percent, 0) / 100)) * coalesce(rule_row.icms_st_percent, 0) / 100, 4);
  tax_total := icms + ipi + pis + cofins + fcp + icms_st;
  final_price := round(base + tax_total, 4);

  return jsonb_build_object(
    'status', 'CALCULATED',
    'rule_id', rule_row.id,
    'base_price', base,
    'tax_total', tax_total,
    'final_price', final_price,
    'icms', icms,
    'ipi', ipi,
    'pis', pis,
    'cofins', cofins,
    'fcp', fcp,
    'icms_st', icms_st,
    'mva_percent', coalesce(rule_row.mva_percent, 0),
    'ncm', rule_row.ncm,
    'uf_origem', rule_row.uf_origem,
    'uf_destino', rule_row.uf_destino,
    'customer_type', rule_row.customer_type
  );
end;
$$;

create or replace function public.commercial_create_document(document_type text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  region_value public.order_region;
  destination_uf text;
  origin_uf text;
  customer_type_value text := upper(btrim(coalesce(nullif(payload->>'tipo_cliente', ''), nullif(payload->>'customer_type', ''), 'GERAL')));
  item_data jsonb;
  product_row public.products;
  tax_rule public.fiscal_tax_rules;
  tax_calc jsonb;
  tax_status text;
  new_id uuid;
  document_number text;
  idx integer := 0;
  qty numeric;
  discount numeric;
  unit_price numeric;
  final_unit numeric;
  base_unit numeric;
  tax_unit numeric;
  subtotal_value numeric := 0;
  total_value numeric := 0;
  fiscal_calculated integer := 0;
  fiscal_missing_ncm integer := 0;
  fiscal_missing_rule integer := 0;
  max_discount numeric := public.max_discount_percent();
begin
  actor := public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'pedido' and not public.has_module('novo_pedido') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type = 'cotacao' and not public.has_module('nova_cotacao') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type not in ('pedido', 'cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if coalesce(btrim(payload->>'cliente'), '') = '' then raise exception 'CLIENTE_OBRIGATORIO'; end if;
  if jsonb_typeof(payload->'items') <> 'array' or jsonb_array_length(payload->'items') = 0 then raise exception 'ITENS_OBRIGATORIOS'; end if;

  destination_uf := nullif(upper(regexp_replace(coalesce(payload->>'cliente_estado', ''), '[^A-Za-z]', '', 'g')), '');
  region_value := public.resolve_billing_region(payload->>'cliente_estado', coalesce(nullif(payload->>'regiao', ''), 'PR'));
  origin_uf := region_value::text;
  destination_uf := coalesce(destination_uf, origin_uf);

  if document_type = 'pedido' then
    document_number := lpad(nextval('public.order_commercial_number_seq')::text, 6, '0');
    insert into public.orders (
      numero_pedido, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVO'
    ) returning id into new_id;
  else
    document_number := lpad(nextval('public.quotation_commercial_number_seq')::text, 6, '0');
    insert into public.quotations (
      numero_cotacao, regiao, user_id, vendedor, codigo_sap_cliente, cliente, cnpj, telefone, endereco,
      prazo, transportadora, transportadora_cnpj, transportadora_endereco, observacao, status
    ) values (
      document_number, region_value, actor.id, actor.nome, nullif(btrim(payload->>'codigo_sap_cliente'), ''), btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj', ''), '\D', '', 'g'), ''), nullif(btrim(payload->>'telefone'), ''),
      nullif(btrim(payload->>'endereco'), ''), nullif(btrim(payload->>'prazo'), ''), nullif(btrim(payload->>'transportadora'), ''),
      nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj', ''), '\D', '', 'g'), ''),
      nullif(btrim(payload->>'transportadora_endereco'), ''), nullif(btrim(payload->>'observacao'), ''), 'NOVA'
    ) returning id into new_id;
  end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx := idx + 1;
    select * into product_row from public.products where codigo = btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %', idx; end if;

    qty := coalesce(nullif(item_data->>'quantidade', '')::numeric, 0);
    discount := coalesce(nullif(item_data->>'desconto_percentual', '')::numeric, 0);
    if qty <= 0 then raise exception 'QUANTIDADE_INVALIDA: item %', idx; end if;
    if discount < 0 or discount > max_discount then raise exception 'DESCONTO_INVALIDO: item %', idx; end if;

    base_unit := null;
    tax_unit := null;
    tax_rule := null;
    tax_calc := null;
    tax_status := 'LEGACY_PRICE';

    if coalesce(product_row.preco_sem_imposto, 0) > 0 then
      if public.normalize_ncm(product_row.ncm) is null then
        fiscal_missing_ncm := fiscal_missing_ncm + 1;
        tax_status := 'MISSING_NCM';
      else
        tax_rule := public.resolve_fiscal_tax_rule(product_row.ncm, origin_uf, destination_uf, customer_type_value, current_date);
        if tax_rule.id is null then
          fiscal_missing_rule := fiscal_missing_rule + 1;
          tax_status := 'MISSING_RULE';
        else
          tax_calc := public.calculate_taxed_unit_price(product_row.preco_sem_imposto, tax_rule);
          unit_price := (tax_calc->>'final_price')::numeric;
          base_unit := (tax_calc->>'base_price')::numeric;
          tax_unit := (tax_calc->>'tax_total')::numeric;
          tax_status := 'CALCULATED';
          fiscal_calculated := fiscal_calculated + 1;
        end if;
      end if;
    end if;

    if tax_status <> 'CALCULATED' then
      unit_price := case when region_value = 'PR' then product_row.preco_pr else product_row.preco_sp end;
    end if;

    if unit_price is null or unit_price < 0 then raise exception 'PRECO_INVALIDO: item %', idx; end if;
    final_unit := round(unit_price * (1 - discount / 100), 4);
    subtotal_value := subtotal_value + unit_price * qty;
    total_value := total_value + final_unit * qty;

    if document_type = 'pedido' then
      insert into public.order_items (
        order_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario,
        desconto_percentual, preco_final_unitario, total_item, preco_sem_imposto_unitario,
        imposto_unitario, fiscal_tax_rule_id, fiscal_status, fiscal_details
      )
      values (
        new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price,
        discount, final_unit, round(final_unit * qty, 2), base_unit,
        tax_unit, case when tax_rule.id is null then null else tax_rule.id end, tax_status, tax_calc
      );
    else
      insert into public.quotation_items (
        quotation_id, item, codigo, descricao, marca, aplicacao, quantidade, preco_unitario,
        desconto_percentual, preco_final_unitario, total_item, preco_sem_imposto_unitario,
        imposto_unitario, fiscal_tax_rule_id, fiscal_status, fiscal_details
      )
      values (
        new_id, idx, product_row.codigo, product_row.descricao, product_row.marca, product_row.aplicacao, qty, unit_price,
        discount, final_unit, round(final_unit * qty, 2), base_unit,
        tax_unit, case when tax_rule.id is null then null else tax_rule.id end, tax_status, tax_calc
      );
    end if;
  end loop;

  if document_type = 'pedido' then
    update public.orders set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  else
    update public.quotations set subtotal = round(subtotal_value, 2), desconto_total = round(subtotal_value - total_value, 2), total = round(total_value, 2) where id = new_id;
  end if;

  update public.customer_timeline_events set amount = round(total_value, 2)
  where entity_id = new_id and event_type in ('PEDIDO_CRIADO', 'COTACAO_CRIADA');

  insert into public.logs (user_id, usuario, acao, entidade, id_entidade, dados_novos)
  values (actor.id, actor.usuario, case when document_type = 'pedido' then 'CRIAR_PEDIDO' else 'CRIAR_COTACAO' end,
          case when document_type = 'pedido' then 'orders' else 'quotations' end, new_id::text,
          jsonb_build_object(
            'numero', document_number,
            'regiao', region_value,
            'uf_origem', origin_uf,
            'uf_destino', destination_uf,
            'uf_faturamento', nullif(payload->>'cliente_estado', ''),
            'itens', idx,
            'total', round(total_value, 2),
            'fiscal', jsonb_build_object(
              'calculated', fiscal_calculated,
              'missing_ncm', fiscal_missing_ncm,
              'missing_rule', fiscal_missing_rule
            )
          ));

  return jsonb_build_object(
    'id', new_id,
    case when document_type = 'pedido' then 'numero_pedido' else 'numero_cotacao' end, document_number,
    'fiscal', jsonb_build_object(
      'calculated', fiscal_calculated,
      'missing_ncm', fiscal_missing_ncm,
      'missing_rule', fiscal_missing_rule
    )
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'VALOR_NUMERICO_INVALIDO';
end;
$$;

revoke all on function public.normalize_ncm(text),
  public.resolve_fiscal_tax_rule(text, text, text, text, date),
  public.calculate_taxed_unit_price(numeric, public.fiscal_tax_rules)
from public, anon;

grant execute on function public.normalize_ncm(text),
  public.resolve_fiscal_tax_rule(text, text, text, text, date),
  public.calculate_taxed_unit_price(numeric, public.fiscal_tax_rules)
to authenticated;

comment on function public.commercial_create_document(text, jsonb)
is 'Cria pedidos/cotacoes. Quando produto tem NCM, preco sem imposto e regra fiscal ativa, calcula preco unitario com impostos; caso contrario usa preco legado SP/PR e retorna resumo fiscal.';

commit;
