begin;
drop function if exists public.search_product_catalog_pricing(jsonb);
notify pgrst,'reload schema';
commit;
