begin;

-- A carga deve ser executada somente pelo backend/operador. O navegador B2B
-- continua sem EXECUTE e sem SELECT direto nas tabelas de metadados.
grant execute on function public.sync_yokomitsu_catalog_metadata(jsonb,text)
  to service_role;

commit;
