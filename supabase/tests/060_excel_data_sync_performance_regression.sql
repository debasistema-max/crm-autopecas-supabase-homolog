begin;

select set_config('request.jwt.claim.sub',(
  select id::text from public.profiles where perfil='ADMIN' and ativo order by created_at limit 1
),true);

do $$
declare
  v_batch uuid;
  v_offset integer;
  v_rows jsonb;
  v_started timestamptz:=clock_timestamp();
  v_result jsonb;
begin
  v_batch:=(public.create_data_sync_batch(jsonb_build_object(
    'source','EXCEL_API','source_version','sync-060-performance','source_updated_at',clock_timestamp(),
    'file_hash',repeat('9',64),'original_filename','performance-4000.xlsx'
  ))->>'batch_id')::uuid;
  for v_offset in 0..3 loop
    select jsonb_agg(jsonb_build_object(
      'row_number',v_offset*1000+n,'area','PRODUCT','product_code','PERF060-'||lpad((v_offset*1000+n)::text,5,'0'),
      'fields',jsonb_build_object('description','PRODUTO PERFORMANCE '||(v_offset*1000+n),'brand','IPS'),
      'field_mask',jsonb_build_array('description','brand')
    ) order by n) into v_rows from generate_series(1,1000) n;
    perform public.stage_data_sync_rows(v_batch,v_rows);
  end loop;
  v_result:=public.validate_data_sync_batch(v_batch);
  if (v_result->>'total_rows')::integer<>4000 or (v_result->>'valid_rows')::integer<>4000 then
    raise exception 'VOLUME_4000_NAO_VALIDADO: %',v_result;
  end if;
  if clock_timestamp()-v_started>interval '180 seconds' then raise exception 'VALIDACAO_4000_EXCEDEU_180S'; end if;
  raise notice 'DATA_SYNC_060_PERFORMANCE_OK duration=%',clock_timestamp()-v_started;
end;
$$;

rollback;
