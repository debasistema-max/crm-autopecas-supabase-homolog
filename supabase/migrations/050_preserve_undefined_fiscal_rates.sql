begin;

-- Zero is a defined tax rate; NULL means the source did not provide a rate.
-- Legacy percentage columns remain for compatibility but no longer manufacture
-- values for optional taxes or for ST-only inputs on routes without ST.
alter table public.fiscal_tax_rules
  alter column icms_st_percent drop not null,
  alter column icms_st_percent drop default,
  alter column mva_percent drop not null,
  alter column mva_percent drop default,
  alter column ipi_percent drop not null,
  alter column ipi_percent drop default,
  alter column pis_percent drop not null,
  alter column pis_percent drop default,
  alter column cofins_percent drop not null,
  alter column cofins_percent drop default,
  alter column fcp_percent drop not null,
  alter column fcp_percent drop default;

comment on column public.fiscal_tax_rules.pis_rate is 'NULL quando o SAP não informou PIS; zero somente quando explicitamente fornecido.';
comment on column public.fiscal_tax_rules.cofins_rate is 'NULL quando o SAP não informou COFINS; zero somente quando explicitamente fornecido.';
comment on column public.fiscal_tax_rules.fcp_rate is 'NULL quando o SAP não informou FCP; zero somente quando explicitamente fornecido.';

commit;
