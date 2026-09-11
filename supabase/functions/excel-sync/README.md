# Edge Function `excel-sync`

Esta função é a fronteira segura entre o CRM e o adapter de origem. Ela não conhece Microsoft Graph nem interpreta XLSX.

Variáveis obrigatórias no ambiente da função:

- `DATA_SYNC_ADAPTER_URL`: endpoint HTTPS do adapter;
- `DATA_SYNC_ADAPTER_TOKEN`: token enviado somente pelo backend;
- `DATA_SYNC_SCHEDULER_SECRET`: segredo opcional para execução agendada;
- `DATA_SYNC_ALLOWED_ORIGIN`: origem do frontend administrativo;
- variáveis padrão `SUPABASE_URL`, `SUPABASE_ANON_KEY` e, para agenda, `SUPABASE_SERVICE_ROLE_KEY`.

O adapter deve retornar o contrato documentado em `docs/data-sync.md`. O navegador envia apenas o JWT do usuário autenticado. As RPCs confirmam que o usuário é ADMIN; execuções agendadas usam `service_role` somente dentro da Edge Function.

## Executor OneDrive Pessoal

O executor em GitHub Actions usa o mesmo endpoint com `x-sync-secret`, mas envia o
DTO em um protocolo pequeno e idempotente:

1. `operation=create`: metadados e hash; cria o lote ou reconhece duplicidade;
2. `operation=stage`: até 500 registros por chamada;
3. `operation=finalize`: valida e confirma o lote;
4. `operation=fail`: registra uma falha sanitizada do executor.

Essas operações não aceitam JWT de navegador e exigem o segredo do agendador. O
GitHub nunca recebe `service_role`; ela continua exclusivamente no Supabase.
