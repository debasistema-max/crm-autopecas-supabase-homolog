begin;

-- Preserve fiscal precision in document snapshots. The UI continues to format
-- commercial money with two decimal places, while the database keeps six.
alter table public.order_items
  alter column preco_unitario type numeric(16,6),
  alter column preco_final_unitario type numeric(16,6),
  alter column preco_sem_imposto_unitario type numeric(16,6),
  alter column imposto_unitario type numeric(16,6);

alter table public.quotation_items
  alter column preco_unitario type numeric(16,6),
  alter column preco_final_unitario type numeric(16,6),
  alter column preco_sem_imposto_unitario type numeric(16,6),
  alter column imposto_unitario type numeric(16,6);

alter table public.order_items
  add column if not exists fiscal_rule_version bigint,
  add column if not exists fiscal_calculated_at timestamptz,
  add column if not exists fiscal_origin_state text,
  add column if not exists fiscal_destination_state text;

alter table public.quotation_items
  add column if not exists fiscal_rule_version bigint,
  add column if not exists fiscal_calculated_at timestamptz,
  add column if not exists fiscal_origin_state text,
  add column if not exists fiscal_destination_state text;

create or replace function public.commercial_create_document(document_type text, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles;
  region_value public.order_region;
  billing_uf_value text;
  destination_uf text;
  origin_uf text;
  customer_type_value text := upper(btrim(coalesce(nullif(payload->>'tipo_cliente',''),nullif(payload->>'customer_type',''),'GERAL')));
  item_data jsonb;
  product_row public.products;
  price_calc jsonb;
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
  fiscal_invalid integer := 0;
  transfer_summary jsonb := jsonb_build_object('created',0,'updated',0);
  max_discount numeric := public.max_discount_percent();
begin
  actor:=public.commercial_active_profile();
  if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  if document_type='pedido' and not public.has_module('novo_pedido') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type='cotacao' and not public.has_module('nova_cotacao') then raise exception 'SEM_PERMISSAO'; end if;
  if document_type not in ('pedido','cotacao') then raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if coalesce(btrim(payload->>'cliente'),'')='' then raise exception 'CLIENTE_OBRIGATORIO'; end if;
  if jsonb_typeof(payload->'items')<>'array' or jsonb_array_length(payload->'items')=0 then raise exception 'ITENS_OBRIGATORIOS'; end if;
  billing_uf_value:=nullif(upper(regexp_replace(coalesce(payload->>'cliente_estado',''),'[^A-Za-z]','','g')),'');
  region_value:=public.resolve_billing_region(payload->>'cliente_estado',coalesce(nullif(payload->>'regiao',''),'PR'));
  origin_uf:=region_value::text; destination_uf:=coalesce(billing_uf_value,origin_uf);

  if document_type='pedido' then
    document_number:=lpad(nextval('public.order_commercial_number_seq')::text,6,'0');
    insert into public.orders(numero_pedido,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,
      prazo,transportadora,transportadora_cnpj,transportadora_endereco,observacao,status)
    values(document_number,region_value,destination_uf,actor.id,actor.nome,nullif(btrim(payload->>'codigo_sap_cliente'),''),btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj',''),'\D','','g'),''),nullif(btrim(payload->>'telefone'),''),nullif(btrim(payload->>'endereco'),''),
      nullif(btrim(payload->>'prazo'),''),nullif(btrim(payload->>'transportadora'),''),nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj',''),'\D','','g'),''),
      nullif(btrim(payload->>'transportadora_endereco'),''),nullif(btrim(payload->>'observacao'),''),'NOVO') returning id into new_id;
  else
    document_number:=lpad(nextval('public.quotation_commercial_number_seq')::text,6,'0');
    insert into public.quotations(numero_cotacao,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,
      prazo,transportadora,transportadora_cnpj,transportadora_endereco,observacao,status)
    values(document_number,region_value,destination_uf,actor.id,actor.nome,nullif(btrim(payload->>'codigo_sap_cliente'),''),btrim(payload->>'cliente'),
      nullif(regexp_replace(coalesce(payload->>'cnpj',''),'\D','','g'),''),nullif(btrim(payload->>'telefone'),''),nullif(btrim(payload->>'endereco'),''),
      nullif(btrim(payload->>'prazo'),''),nullif(btrim(payload->>'transportadora'),''),nullif(regexp_replace(coalesce(payload->>'transportadora_cnpj',''),'\D','','g'),''),
      nullif(btrim(payload->>'transportadora_endereco'),''),nullif(btrim(payload->>'observacao'),''),'NOVA') returning id into new_id;
  end if;

  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx:=idx+1;
    select * into product_row from public.products where codigo=btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %',idx; end if;
    qty:=coalesce(nullif(item_data->>'quantidade','')::numeric,0); discount:=coalesce(nullif(item_data->>'desconto_percentual','')::numeric,0);
    if qty<=0 then raise exception 'QUANTIDADE_INVALIDA: item %',idx; end if;
    if discount<0 or discount>max_discount then raise exception 'DESCONTO_INVALIDO: item %',idx; end if;
    price_calc:=public.get_product_commercial_price(product_row.codigo,origin_uf,destination_uf,current_date,customer_type_value);
    tax_status:=coalesce(price_calc->>'status','REGRA_FISCAL_INCOMPLETA');
    if tax_status in ('OK','OK_SEM_ST') then
      unit_price:=(price_calc->>'final_price')::numeric; base_unit:=(price_calc->>'base_price')::numeric;
      tax_unit:=(price_calc->>'total_taxes')::numeric+coalesce((price_calc->>'total_expenses')::numeric,0); fiscal_calculated:=fiscal_calculated+1;
    else
      unit_price:=case when region_value='PR' then product_row.preco_pr else product_row.preco_sp end;
      base_unit:=null; tax_unit:=null; fiscal_invalid:=fiscal_invalid+1;
      if tax_status='NCM_AUSENTE' then fiscal_missing_ncm:=fiscal_missing_ncm+1; end if;
      if tax_status='REGRA_FISCAL_AUSENTE' then fiscal_missing_rule:=fiscal_missing_rule+1; end if;
    end if;
    if unit_price is null or unit_price<0 then raise exception 'PRECO_INVALIDO: item % (%).',idx,tax_status; end if;
    final_unit:=round(unit_price*(1-discount/100),4); subtotal_value:=subtotal_value+unit_price*qty; total_value:=total_value+final_unit*qty;
    if document_type='pedido' then
      insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,
        preco_final_unitario,total_item,branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,
        preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,fiscal_details,fiscal_rule_version,
        fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,unit_price,discount,
        final_unit,round(final_unit*qty,2),null,null,null,null,
        base_unit,tax_unit,nullif(price_calc->>'fiscal_rule_id','')::uuid,tax_status,price_calc,
        nullif(price_calc->>'fiscal_rule_version','')::bigint,coalesce(nullif(price_calc->>'calculated_at','')::timestamptz,now()),origin_uf,destination_uf);
    else
      insert into public.quotation_items(quotation_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,
        preco_final_unitario,total_item,branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,
        preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,fiscal_details,fiscal_rule_version,
        fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(new_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,unit_price,discount,
        final_unit,round(final_unit*qty,2),null,null,null,null,
        base_unit,tax_unit,nullif(price_calc->>'fiscal_rule_id','')::uuid,tax_status,price_calc,
        nullif(price_calc->>'fiscal_rule_version','')::bigint,coalesce(nullif(price_calc->>'calculated_at','')::timestamptz,now()),origin_uf,destination_uf);
    end if;
  end loop;
  if document_type='pedido' then
    update public.orders set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=new_id;
    transfer_summary:=public.create_order_transfer_requests(new_id);
  else update public.quotations set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=new_id; end if;
  update public.customer_timeline_events set amount=round(total_value,2) where entity_id=new_id and event_type in ('PEDIDO_CRIADO','COTACAO_CRIADA');
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos)
  values(actor.id,actor.usuario,case when document_type='pedido' then 'CRIAR_PEDIDO' else 'CRIAR_COTACAO' end,
    case when document_type='pedido' then 'orders' else 'quotations' end,new_id::text,
    jsonb_build_object('numero',document_number,'regiao',region_value,'uf_origem',origin_uf,'uf_destino',destination_uf,'itens',idx,'total',round(total_value,2),
      'transferencias',transfer_summary,'fiscal',jsonb_build_object('calculated',fiscal_calculated,'missing_ncm',fiscal_missing_ncm,'missing_rule',fiscal_missing_rule,'invalid',fiscal_invalid)));
  return jsonb_build_object('id',new_id,case when document_type='pedido' then 'numero_pedido' else 'numero_cotacao' end,document_number,
    'fiscal',jsonb_build_object('calculated',fiscal_calculated,'missing_ncm',fiscal_missing_ncm,'missing_rule',fiscal_missing_rule,'invalid',fiscal_invalid),'transferencias',transfer_summary);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'VALOR_NUMERICO_INVALIDO';
end;
$$;

create or replace function public.commercial_update_document_items(document_type text,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles; owner_id uuid; current_status text; region_value public.order_region; destination_uf text; origin_uf text;
  customer_type_value text:=upper(btrim(coalesce(nullif(payload->>'tipo_cliente',''),nullif(payload->>'customer_type',''),'GERAL')));
  item_data jsonb; product_row public.products; price_calc jsonb; tax_status text; target_id uuid; idx integer:=0;
  qty numeric; discount numeric; unit_price numeric; final_unit numeric; base_unit numeric; tax_unit numeric;
  subtotal_value numeric:=0; total_value numeric:=0; fiscal_calculated integer:=0; fiscal_invalid integer:=0;
  transfer_summary jsonb:=jsonb_build_object('created',0,'updated',0); max_discount numeric:=public.max_discount_percent();
begin
  actor:=public.commercial_active_profile(); if actor.id is null then raise exception 'SEM_PERMISSAO'; end if;
  target_id:=(payload->>'id')::uuid;
  if jsonb_typeof(payload->'items')<>'array' or jsonb_array_length(payload->'items')=0 then raise exception 'ITENS_OBRIGATORIOS'; end if;
  if document_type='pedido' then
    if not(actor.perfil='ADMIN' or public.has_module('pedidos')) then raise exception 'SEM_PERMISSAO'; end if;
    select user_id,status::text,regiao,coalesce(billing_uf,regiao::text) into owner_id,current_status,region_value,destination_uf from public.orders where id=target_id for update;
    if current_status not in ('NOVO','EM_ANALISE') then raise exception 'PEDIDO_NAO_EDITAVEL'; end if;
  elsif document_type='cotacao' then
    if not(actor.perfil='ADMIN' or public.has_module('cotacoes')) then raise exception 'SEM_PERMISSAO'; end if;
    select user_id,status::text,regiao,coalesce(billing_uf,regiao::text) into owner_id,current_status,region_value,destination_uf from public.quotations where id=target_id for update;
    if current_status not in ('NOVA','ENVIADA') then raise exception 'COTACAO_NAO_EDITAVEL'; end if;
  else raise exception 'TIPO_DOCUMENTO_INVALIDO'; end if;
  if owner_id is null then raise exception 'DOCUMENTO_NAO_ENCONTRADO'; end if;
  if actor.perfil<>'ADMIN' and owner_id<>actor.id then raise exception 'SEM_PERMISSAO'; end if;
  origin_uf:=region_value::text; destination_uf:=coalesce(public.normalize_fiscal_uf(destination_uf),origin_uf);
  if document_type='pedido' then delete from public.order_items where order_id=target_id; else delete from public.quotation_items where quotation_id=target_id; end if;
  for item_data in select value from jsonb_array_elements(payload->'items') loop
    idx:=idx+1; select * into product_row from public.products where codigo=btrim(item_data->>'codigo');
    if product_row.codigo is null then raise exception 'PRODUTO_NAO_ENCONTRADO: item %',idx; end if;
    qty:=coalesce(nullif(item_data->>'quantidade','')::numeric,0); discount:=coalesce(nullif(item_data->>'desconto_percentual','')::numeric,0);
    if qty<=0 or discount<0 or discount>max_discount then raise exception 'ITEM_INVALIDO: %',idx; end if;
    price_calc:=public.get_product_commercial_price(product_row.codigo,origin_uf,destination_uf,current_date,customer_type_value); tax_status:=price_calc->>'status';
    if tax_status in ('OK','OK_SEM_ST') then unit_price:=(price_calc->>'final_price')::numeric;base_unit:=(price_calc->>'base_price')::numeric;
      tax_unit:=(price_calc->>'total_taxes')::numeric+coalesce((price_calc->>'total_expenses')::numeric,0);fiscal_calculated:=fiscal_calculated+1;
    else unit_price:=case when region_value='PR' then product_row.preco_pr else product_row.preco_sp end;base_unit:=null;tax_unit:=null;fiscal_invalid:=fiscal_invalid+1;end if;
    if unit_price is null or unit_price<0 then raise exception 'PRECO_INVALIDO: item % (%)',idx,tax_status; end if;
    final_unit:=round(unit_price*(1-discount/100),4);subtotal_value:=subtotal_value+unit_price*qty;total_value:=total_value+final_unit*qty;
    if document_type='pedido' then
      insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
        branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,
        fiscal_details,fiscal_rule_version,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(target_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,unit_price,discount,final_unit,round(final_unit*qty,2),
        null,null,null,null,
        base_unit,tax_unit,nullif(price_calc->>'fiscal_rule_id','')::uuid,tax_status,price_calc,nullif(price_calc->>'fiscal_rule_version','')::bigint,
        coalesce(nullif(price_calc->>'calculated_at','')::timestamptz,now()),origin_uf,destination_uf);
    else
      insert into public.quotation_items(quotation_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
        branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,
        fiscal_details,fiscal_rule_version,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
      values(target_id,idx,product_row.codigo,product_row.descricao,product_row.marca,product_row.aplicacao,qty,unit_price,discount,final_unit,round(final_unit*qty,2),
        null,null,null,null,
        base_unit,tax_unit,nullif(price_calc->>'fiscal_rule_id','')::uuid,tax_status,price_calc,nullif(price_calc->>'fiscal_rule_version','')::bigint,
        coalesce(nullif(price_calc->>'calculated_at','')::timestamptz,now()),origin_uf,destination_uf);
    end if;
  end loop;
  if document_type='pedido' then update public.orders set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=target_id;
    transfer_summary:=public.create_order_transfer_requests(target_id);
  else update public.quotations set subtotal=round(subtotal_value,2),desconto_total=round(subtotal_value-total_value,2),total=round(total_value,2) where id=target_id;end if;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos) values(actor.id,actor.usuario,'ATUALIZAR_ITENS',
    case when document_type='pedido' then 'orders' else 'quotations' end,target_id::text,
    jsonb_build_object('itens',idx,'total',round(total_value,2),'fiscal',jsonb_build_object('calculated',fiscal_calculated,'invalid',fiscal_invalid),'transferencias',transfer_summary));
  return jsonb_build_object('id',target_id,'subtotal',round(subtotal_value,2),'desconto_total',round(subtotal_value-total_value,2),'total',round(total_value,2),
    'fiscal',jsonb_build_object('calculated',fiscal_calculated,'invalid',fiscal_invalid),'transferencias',transfer_summary);
end;
$$;

create or replace function public.convert_quotation_to_order(target_quotation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare actor public.profiles; source public.quotations; new_order_id uuid; new_number text; existing public.quotation_order_conversions; item_count integer;
begin
  actor:=public.commercial_active_profile();
  if actor.id is null or not public.has_module('novo_pedido') or not public.has_module('cotacoes') then raise exception 'SEM_PERMISSAO'; end if;
  select * into source from public.quotations where id=target_quotation_id for update;
  if source.id is null then raise exception 'COTACAO_NAO_ENCONTRADA'; end if;
  if actor.perfil<>'ADMIN' and source.user_id<>actor.id then raise exception 'SEM_PERMISSAO'; end if;
  select * into existing from public.quotation_order_conversions where quotation_id=source.id;
  if existing.quotation_id is not null then return(select jsonb_build_object('id_pedido',o.id,'numero_pedido',o.numero_pedido,'numero_cotacao',source.numero_cotacao,'already_converted',true) from public.orders o where o.id=existing.order_id);end if;
  if source.status<>'APROVADA' then raise exception 'COTACAO_NAO_APROVADA'; end if;
  select count(*) into item_count from public.quotation_items where quotation_id=source.id;if item_count=0 then raise exception 'COTACAO_SEM_ITENS';end if;
  new_number:=lpad(nextval('public.order_commercial_number_seq')::text,6,'0');
  insert into public.orders(numero_pedido,regiao,billing_uf,user_id,vendedor,codigo_sap_cliente,cliente,cnpj,telefone,endereco,prazo,transportadora,
    transportadora_cnpj,transportadora_endereco,observacao,subtotal,desconto_total,total,status)
  values(new_number,source.regiao,source.billing_uf,source.user_id,source.vendedor,source.codigo_sap_cliente,source.cliente,source.cnpj,source.telefone,source.endereco,
    source.prazo,source.transportadora,source.transportadora_cnpj,source.transportadora_endereco,nullif(concat_ws(E'\n',source.observacao,'Convertido da cotacao '||source.numero_cotacao),''),
    source.subtotal,source.desconto_total,source.total,'NOVO') returning id into new_order_id;
  insert into public.order_items(order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
    branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,
    fiscal_details,fiscal_rule_version,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state)
  select new_order_id,item,codigo,descricao,marca,aplicacao,quantidade,preco_unitario,desconto_percentual,preco_final_unitario,total_item,
    branch_price,branch_price_currency,branch_price_version,branch_price_captured_at,preco_sem_imposto_unitario,imposto_unitario,fiscal_tax_rule_id,fiscal_status,
    fiscal_details,fiscal_rule_version,fiscal_calculated_at,fiscal_origin_state,fiscal_destination_state
  from public.quotation_items where quotation_id=source.id order by item;
  insert into public.quotation_order_conversions(quotation_id,order_id,converted_by) values(source.id,new_order_id,actor.id);
  update public.quotations set status='CONVERTIDA' where id=source.id;
  insert into public.logs(user_id,usuario,acao,entidade,id_entidade,dados_novos) values(actor.id,actor.usuario,'CONVERTER_COTACAO_PEDIDO','orders',new_order_id::text,
    jsonb_build_object('quotation_id',source.id,'numero_cotacao',source.numero_cotacao,'fiscal_snapshot_preserved',true));
  return jsonb_build_object('id_pedido',new_order_id,'numero_pedido',new_number,'numero_cotacao',source.numero_cotacao,'already_converted',false);
end;
$$;

grant execute on function public.commercial_create_document(text,jsonb),public.commercial_update_document_items(text,jsonb),
  public.convert_quotation_to_order(uuid) to authenticated;

comment on column public.order_items.fiscal_details is 'Snapshot imutável do cálculo fiscal central no momento do pedido.';
comment on column public.quotation_items.fiscal_details is 'Snapshot do cálculo fiscal central no momento da cotação; copiado ao pedido na conversão.';

commit;
