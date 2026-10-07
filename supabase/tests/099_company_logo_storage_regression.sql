begin;

do $test$
declare
  v_bucket storage.buckets%rowtype;
begin
  select * into v_bucket from storage.buckets where id = 'company-assets';
  if not found or not v_bucket.public then
    raise exception 'Bucket publico company-assets nao foi configurado';
  end if;
  if v_bucket.file_size_limit <> 2097152 then
    raise exception 'Limite do logo diferente de 2 MB';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'company_assets_admin_insert'
      and with_check like '%is_admin()%'
      and with_check like '%identity/%'
  ) then
    raise exception 'Politica administrativa de upload ausente';
  end if;
end;
$test$;

rollback;
