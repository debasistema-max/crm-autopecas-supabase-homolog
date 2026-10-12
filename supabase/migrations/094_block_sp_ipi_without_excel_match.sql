begin;

-- O motor fiscal do CRM permanece autoritativo para SP-SP, mas a liberacao
-- comercial exige que base e IPI coincidam com a referencia Excel.
alter function public.apply_commercial_tax_policy(jsonb,text,text,date)
  rename to apply_commercial_tax_policy_raw_094;

revoke all on function public.apply_commercial_tax_policy_raw_094(jsonb,text,text,date)
  from public,anon,authenticated;

create function public.apply_commercial_tax_policy(
  source_price jsonb,
  target_origin_state text,
  target_destination_state text,
  target_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_result jsonb;
  v_validation_status text;
begin
  v_result:=public.apply_commercial_tax_policy_raw_094(
    source_price,target_origin_state,target_destination_state,target_date
  );

  if coalesce((v_result->>'tax_policy_applied')::boolean,false) is not true then
    return v_result;
  end if;

  v_validation_status:=coalesce(
    nullif(v_result->>'validation_status',''),
    'EXCEL_REFERENCE_MISSING'
  );

  if v_validation_status<>'MATCH' then
    return v_result||jsonb_build_object(
      'status','PRECO_FISCAL_INDISPONIVEL',
      'final_price',null,
      'total_taxes',null,
      'price_source','CRM_FISCAL_ENGINE_BLOCKED',
      'tax_policy_applied',false,
      'tax_policy_validation_blocked',true,
      'warnings',coalesce(v_result->'warnings','[]'::jsonb)
        ||jsonb_build_array('VALIDACAO_FISCAL_PENDENTE')
    );
  end if;

  return v_result||jsonb_build_object(
    'tax_policy_validation_blocked',false
  );
end;
$$;

revoke all on function public.apply_commercial_tax_policy(jsonb,text,text,date)
  from public,anon,authenticated;

comment on function public.apply_commercial_tax_policy(jsonb,text,text,date) is
  'Aplica politica fiscal operacional e bloqueia SP-SP quando a validacao do motor CRM contra a referencia Excel nao for MATCH.';

commit;
