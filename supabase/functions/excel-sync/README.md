# Edge Function `excel-sync`

Esta função é a fronteira segura entre o CRM e o executor de origem. Ela não conhece Microsoft Graph nem interpreta XLSX.

Variáveis obrigatórias no ambiente da função para iniciar a sincronização pelo CRM:

- `DATA_SYNC_GITHUB_TOKEN`: token fine-grained limitado ao repositório do executor e com Actions em leitura/escrita;
- `DATA_SYNC_GITHUB_REPOSITORY`: repositório privado no formato `owner/repo`;
- `DATA_SYNC_GITHUB_WORKFLOW`: arquivo do workflow (padrão: `excel-sync.yml`);
- `DATA_SYNC_GITHUB_REF`: branch do workflow (padrão: `main`);
- `DATA_SYNC_SCHEDULER_SECRET`: segredo opcional para execução agendada;
- `DATA_SYNC_ALLOWED_ORIGIN`: origem do frontend administrativo;
- variáveis padrão `SUPABASE_URL`, `SUPABASE_ANON_KEY` e, para agenda, `SUPABASE_SERVICE_ROLE_KEY`.

O navegador envia apenas o JWT do usuário autenticado. As RPCs confirmam que o usuário é ADMIN antes de a função enfileirar o workflow privado. O token do GitHub nunca é enviado ao navegador. Execuções do runner usam `service_role` somente dentro da Edge Function.

## Executor OneDrive Pessoal

O executor em GitHub Actions usa o mesmo endpoint com `x-sync-secret`, mas envia o
DTO em um protocolo pequeno e idempotente:

1. `operation=create`: metadados e hash; cria o lote ou reconhece duplicidade;
2. `operation=stage`: até 500 registros por chamada;
3. `operation=finalize`: valida e confirma o lote;
4. `operation=fiscal-bases`: publica atomicamente as regras versionadas de
   `Dados Fiscais` e `Regras por Grupo`, usando o mesmo hash do XLSX;
5. `operation=fail`: registra uma falha sanitizada do executor.

Essas operações não aceitam JWT de navegador e exigem o segredo do agendador. O
GitHub nunca recebe `service_role`; ela continua exclusivamente no Supabase.
