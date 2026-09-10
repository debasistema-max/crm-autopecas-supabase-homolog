# Edge Function `excel-sync`

Esta função é a fronteira segura entre o CRM e o adapter de origem. Ela não conhece Microsoft Graph nem interpreta XLSX.

Variáveis obrigatórias no ambiente da função:

- `DATA_SYNC_ADAPTER_URL`: endpoint HTTPS do adapter;
- `DATA_SYNC_ADAPTER_TOKEN`: token enviado somente pelo backend;
- `DATA_SYNC_SCHEDULER_SECRET`: segredo opcional para execução agendada;
- `DATA_SYNC_ALLOWED_ORIGIN`: origem do frontend administrativo;
- variáveis padrão `SUPABASE_URL`, `SUPABASE_ANON_KEY` e, para agenda, `SUPABASE_SERVICE_ROLE_KEY`.

O adapter deve retornar o contrato documentado em `docs/data-sync.md`. O navegador envia apenas o JWT do usuário autenticado. As RPCs confirmam que o usuário é ADMIN; execuções agendadas usam `service_role` somente dentro da Edge Function.
