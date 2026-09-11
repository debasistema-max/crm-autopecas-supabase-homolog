# Central de Dados e sincronização Excel

## Objetivo

A integração copia somente dados operacionais consolidados para o Supabase. O CRM lê o banco e continua funcionando quando Excel, OneDrive ou o adapter estão indisponíveis. A planilha não é executada pelo navegador e suas fórmulas não são gravadas no banco.

```text
Excel mestre / OneDrive
  -> adapter de origem
  -> normalização Data Sync v1
  -> Edge Function excel-sync
  -> staging, validação, idempotência e auditoria
  -> Supabase
  -> CRM
```

O domínio do CRM não importa Microsoft Graph. Um adapter futuro pode obter o arquivo por Graph, SharePoint, Google Sheets ou SAP e continuar entregando o mesmo DTO.

## Componentes

- `scripts/build_excel_sync_payload.py`: lê valores calculados do XLSX, normaliza cabeçalhos e gera o DTO. Usa `data_only=True` e nunca salva o arquivo.
- `scripts/run_excel_sync_adapter.py`: adapter HTTP autenticado para arquivo local sincronizado pelo OneDrive.
- `supabase/functions/excel-sync`: busca o DTO no adapter, cria o lote, envia staging em blocos de 500, valida e confirma.
- migration `060_excel_data_sync_center.sql`: estende batches/staging/auditoria, adiciona proteção de versão e armazena preço fiscal consolidado por rota.
- `js/data_sync.js`: status, contadores, execução, erros, histórico e auditoria administrativa.

O normalizador verifica o SHA-256 e o horário de modificação novamente após fechar o
workbook. Se o OneDrive substituir o arquivo durante a leitura, a requisição falha
com `EXCEL_ALTERADO_DURANTE_LEITURA` e nenhum lote é criado.

## Contrato Data Sync v1

Metadados do adapter:

```json
{
  "source_name": "Excel Mestre",
  "source_version": "sha256-do-arquivo",
  "source_updated_at": "2026-09-09T13:00:58Z",
  "file_hash": "sha256-do-arquivo",
  "original_filename": "calculos-impostos.xlsx",
  "file_size": 5728037,
  "records": []
}
```

Registro normalizado:

```json
{
  "row_number": 1,
  "area": "STOCK",
  "product_code": "6111032201",
  "branch_code": "PR",
  "fields": { "stock_qty": 5, "general_available_qty": 3 },
  "field_mask": ["stock_qty", "general_available_qty"],
  "clear_fields": [],
  "source_version": "sha256-do-arquivo",
  "source_updated_at": "2026-09-09T13:00:58Z"
}
```

Áreas aceitas:

- `PRODUCT`: cadastro comercial e atributos úteis do Cadastro Item SAP;
- `STOCK`: snapshot por filial, sem misturar PR e SP;
- `BASE_PRICE`: preço-base da filial em `product_branch_prices`;
- `ROUTE_PRICE`: resultado fiscal final em `product_route_prices`.

Campo ausente não entra na `field_mask`. Campo vazio é ignorado. Limpeza exige que o campo esteja em `clear_fields` e somente campos textuais autorizados podem ser limpos. Zero numérico é valor explícito e válido.

## Abas utilizadas

| Aba | Uso |
|---|---|
| `MATRIZ` | cadastro comercial e IPI |
| `Cadastro Item SAP` | cadastro complementar, NCM, CEST, origem e atributos SAP úteis |
| `PORTAL ESTOQUE PR` | snapshot da filial PR |
| `PORTAL ESTOQUE SP` | snapshot da filial SP somente quando houver linhas válidas |
| `LISTA PR-PR`, `LISTA SP-SP`, `LISTA PR-SC` | preço-base e preço final calculado por rota |
| `NCM Produtos` | resultado cadastral fiscal consolidado |
| `Cálculo Fiscal` | memória e status consolidados usados pelas listas |
| `Dados Fiscais`, `dados fiscais sap pr/sp` | suporte ao cálculo no Excel; não são copiadas integralmente |

Não sincronizar abas de amostra, validação SAP, pesquisa, conferência, diagnóstico ou memória auxiliar. Elas permanecem excluídas mesmo quando ocupam grande parte do arquivo.

Em 10/09/2026, o mapeamento foi revalidado na cópia oficial disponível na raiz do OneDrive, `calculos-impostos-PR-SP-SC-corrigido-seguro.xlsx`. Ela contém 18 abas, incluindo `Regras por Grupo`, `Pesquisa Marcas` e as três validações SAP. O adapter aceita tanto `PREÇO FINAL` quanto o cabeçalho legado `TOTAL C/TRIBUTOS` em `Cálculo Fiscal`, mas não sincroniza as abas auxiliares.

Observação importante: a fórmula atual de `LISTA SP-SP` consulta estoque PR. O adapter usa o preço final dessa lista, mas nunca usa suas colunas de estoque/quantidade. Estoque SP vem exclusivamente de `PORTAL ESTOQUE SP`.

## Idempotência, concorrência e alterações parciais

- A chave de idempotência combina versão do contrato, origem, `source_version` e hash do arquivo.
- O mesmo arquivo retorna o lote já existente; não duplica estoque, preço, auditoria ou movimento.
- A validação compara `source_updated_at` com `updated_at` do registro. Evento antigo vira `STALE_SOURCE_EVENT` e não sobrescreve o banco.
- O preview captura `updated_at`/`version`. O commit compara novamente; edição manual entre preview e commit vira `CONCURRENT_MODIFICATION` somente naquela linha.
- Linhas inválidas são registradas e ignoradas. Linhas válidas do mesmo lote são confirmadas.
- `NO_CHANGE` não executa `UPDATE`, não incrementa versão e não cria auditoria.

## Estoque e auditoria

O snapshot altera somente campos presentes. Mudança no estoque físico cria `stock_movements.movement_type = 'SYNC_ERP'`, com saldo anterior, recebido, diferença, batch e chave idempotente. Não é venda, entrada física ou ajuste manual.

`products_import_audit` registra uma linha por campo alterado com produto, antes, depois, filial/rota, origem, versão, lote, usuário/sistema e status.

## Configuração e execução

Instale a dependência do adapter em ambiente Python isolado:

```powershell
python -m pip install -r scripts/requirements-data-sync.txt
```

Configure no host do adapter, sem colocar valores no Git:

```text
EXCEL_MASTER_PATH=<caminho local sincronizado pelo OneDrive>
DATA_SYNC_ADAPTER_TOKEN=<segredo longo>
DATA_SYNC_ADAPTER_HOST=0.0.0.0
DATA_SYNC_ADAPTER_PORT=8788
```

Na Edge Function, configure `DATA_SYNC_ADAPTER_URL`, `DATA_SYNC_ADAPTER_TOKEN`, `DATA_SYNC_ALLOWED_ORIGIN` e, para agenda, `DATA_SYNC_SCHEDULER_SECRET`. A service role fica somente no ambiente do Supabase.

Um ADMIN pode executar “Sincronizar agora”. A agenda chama a mesma Edge Function com `x-sync-secret`. SUPERVISOR só consulta se receber as permissões já previstas; VENDEDOR não executa nem consulta a Central de Dados.

Antes de contatar o adapter, a Edge Function valida a sessão com `auth.getUser()` e consulta `can_manage_data_sync()`. Assim, uma chave pública anônima ou um usuário sem perfil ADMIN não consegue provocar a leitura do Excel.

## Diagnóstico e reprocessamento

1. Abra Central de Dados e confira conexão, último lote e contadores.
2. Em “Visualizar erros”, filtre por lote, data, área, filial, status ou produto.
3. Corrija a origem e salve/recalcule o Excel. O novo hash cria um lote novo.
4. Retry do mesmo hash é idempotente. Para reprocessar uma falha técnica do mesmo lote, corrija adapter/configuração e use uma versão de origem nova; não altere o lote confirmado.
5. Consulte “Visualizar detalhes” para descobrir campo, valor anterior/novo, origem e responsável.

Falha do adapter não apaga dados. O lote fica `failed`/`completed_with_errors`, a fonte fica degradada e o CRM mantém a última versão confirmada.

## Rollback

Rollback automático não foi implementado nesta fase. Uma reversão segura precisa comparar, por campo, a versão atual com `version_after` e impedir que um lote antigo desfaça edição manual ou sincronização posterior. A auditoria criada contém os dados necessários para uma futura RPC de reversão otimista. Nunca apagar lote, staging, auditoria ou movimento para simular rollback.

## Como adicionar nova origem

1. Criar um adapter que entregue o DTO Data Sync v1; não chamar tabelas do CRM diretamente.
2. Cadastrar a origem em `data_sync_sources` e liberar o código na constraint do batch/targets por migration nova.
3. Reusar `create_data_sync_batch`, `stage_data_sync_rows`, `validate_data_sync_batch` e `commit_data_sync_batch`.
4. Adicionar golden tests para normalização, campos ausentes, zero, idempotência, atraso e concorrência.
5. Não alterar migrations aplicadas nem introduzir tabela paralela de estoque ou preço-base.
