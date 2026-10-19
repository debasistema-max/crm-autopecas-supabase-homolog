# Diagnostico da sincronizacao Excel - 19/10/2026

## Evidencias remotas somente leitura

- Executor privado: debasistema-max/ips-crm-excel-sync-private.
- Runs 39178479116 e 38920626427 falharam com STAGING_INCOMPLETO:29184:29186.
- O run 39178479116 apontou explicitamente para homologacao.
- Ultimo lote homologacao: 8846a27d-e84a-4a5b-b36d-eab006756549, DRAFT, 29184 registros.
- Faltam os numeros de linha 8291 (estoque PR) e 12339 (estoque SP).
- O staging mantem unicidade por batch/normalized_code e por batch/row_number.
- stage_data_sync_rows usa ON CONFLICT DO NOTHING; o adapter enviava estoques
  repetidos sem verificar a chave area/produto/filial/rota antes de gerar o payload.
- Nao foi obtido o conteudo das duas linhas descartadas do arquivo remoto.
  Ainda e necessario verificar se as duplicatas sao identicas ou divergentes.
- A copia local do XLSX tem hash e contagem diferentes da versao do executor:
  nao serve como prova de validacao da planilha remota atual.
- Em producao, o ultimo lote EXCEL_API confirmado e de 15/10/2026, concluido
  com 29186 linhas; connection_status=CONNECTED. Nenhum lote posterior foi
  encontrado. O bloqueio atual do clique em producao ainda exige a mensagem da tela.
- DATA_SYNC_ENABLED=false no executor: agenda esta deliberadamente desativada.
  Run 39295021151 foi schedule/skipped, nao falha de leitura da planilha.
- O workflow remoto fixa o normalizador no commit
  03aafb2c0a3ee56ba5cf35e3df57c4cb06b0ad78. Corrigir apenas o frontend ou
  publicar codigo sem atualizar essa referencia nao altera o executor.

## Correcao local

Correcao inicialmente preparada na branch codex/excel-sync-staging-reliability,
baseada em producao 6684630, e portada para codex/excel-sync-staging-homolog,
baseada na homologacao a42fb95. Publicacao autorizada somente em homologacao.

- Consolida somente registros integralmente identicos com a mesma chave.
- Registra quantidade e avisos de duplicatas identicas no resumo do payload.
- Duplicata divergente interrompe antes de backup, criacao de lote ou envio.
  Erro: REGISTRO_DUPLICADO_DIVERGENTE:AREA:CODIGO:FILIAL:ROTA.
- Nao soma estoque, nao escolhe ultimo valor e nao mescla campos ausentes.
- Filiais, rotas e areas diferentes continuam como registros independentes.
- Numeracao e contagem sao calculadas depois da consolidacao, deterministicamente.
- O bloqueio STAGING_INCOMPLETO continua intacto: falha impede validate/commit.
- Runner mostra erros conhecidos de validacao sem expor traceback ou credenciais.
- Modo --validate-only portado para o runner da homologacao: retorna antes de
  backup, criacao de lote ou qualquer chamada ao Supabase; nao exige segredo
  do agendador nem URL de escrita. Pasta/arquivo e agenda nao foram alterados.
- Nenhuma migration, mudanca de preco, mudanca cadastral ou publicacao executada.

## Validacao

npm test na base de homologacao: 53 contratos estaticos, 16 testes de sessao e
34 testes Python aprovados (103 no total). Sintaxe de 38 arquivos JavaScript
e sequencia de migrations 001-107 aprovadas.
git diff --check aprovado.

Cobertura nova: duplicata identica nao soma estoque, divergencia bloqueia,
campos ausentes nao sobrescrevem dados, filiais/rotas distintas, idempotencia
de normalizacao e numeracao, staging incompleto nao confirma lote e mensagem
segura de erro no runner.

## Aplicacao controlada pendente

1. Obter a mensagem/print da tentativa em producao e verificar o disparo ADMIN.
2. Revisar e publicar a correcao do normalizador apos autorizacao.
3. Atualizar somente a referencia fixa do checkout no workflow privado para o
   commit aprovado. Nao alterar pasta, arquivo, credenciais ou agenda junto.
4. Executar mode=validate, target=homologacao na planilha remota atual.
5. Se houver divergencia, corrigir a origem indicada; nao ignorar nem liberar commit.
6. Conferir contagens e avisos. Somente entao autorizar synchronize em homologacao.
7. Conferir staging, commit, auditoria e precos/estoques antes de producao.
8. Producao exige autorizacao explicita e backup conforme o procedimento existente.

Nao apagar lotes DRAFT, nao executar reset nem remover indices para permitir
duplicatas. Nao ativar a agenda antes de concluir a validacao manual.
