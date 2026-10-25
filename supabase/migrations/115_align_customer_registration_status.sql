begin;
set local lock_timeout='10s';
set local statement_timeout='110s';

do $$
declare existing text; was_present boolean;
begin
  select pg_get_constraintdef(oid) into existing from pg_constraint
  where conrelid='public.cadastros_clientes'::regclass and conname='cadastros_clientes_status_check';
  was_present:=found;
  if was_present then
    if existing not in (
      'CHECK ((status = ANY (ARRAY[''Novo''::text, ''Em analise''::text, ''Pendente''::text, ''Aprovado''::text, ''Reprovado''::text, ''Finalizado SAP''::text])))',
      'CHECK ((status = ANY (ARRAY[''Novo''::text, ''Em analise''::text, ''Pendente''::text, ''Aprovado''::text, ''Reprovado''::text, ''Finalizado SAP''::text]))) NOT VALID'
    ) then raise exception 'CONTRATO_STATUS_DIVERGENTE'; end if;
  else
    alter table public.cadastros_clientes add constraint cadastros_clientes_status_check
      check (status in ('Novo','Em analise','Pendente','Aprovado','Reprovado','Finalizado SAP')) not valid;
  end if;
  alter table public.cadastros_clientes validate constraint cadastros_clientes_status_check;
  insert into public.logs(acao,entidade,id_entidade,usuario,dados_anteriores,dados_novos)
    values('SECURITY_SCHEMA_ALIGNED','cadastros_clientes','115','MIGRATION',
      jsonb_build_object('status_constraint_present',was_present),
      jsonb_build_object('migration','115','status_constraint_validated',true));
end $$;
commit;
