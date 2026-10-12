create or replace function public.check_existing_product_codes(codes jsonb)
returns table (codigo text)
language sql
security definer
set search_path = public
as $$
  select p.codigo
  from public.products p
  join (
    select distinct trim(value #>> '{}') as codigo
    from jsonb_array_elements(coalesce(codes, '[]'::jsonb))
  ) c on c.codigo = p.codigo
  where c.codigo is not null
    and c.codigo <> ''
    and length(c.codigo) <= 80;
$$;

grant execute on function public.check_existing_product_codes(jsonb) to anon;
grant execute on function public.check_existing_product_codes(jsonb) to authenticated;
