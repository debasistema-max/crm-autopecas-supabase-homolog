# Listas Comerciais - Selecao Multipla

O seletor Linhas aceita varias caixas de marcacao. A lista combina as linhas
selecionadas, sem duplicar produtos, e mantem rota, marca e grupo como filtros
adicionais. Sem selecao, todas as linhas participam; Lista geral limpa os filtros.

## Origem Das Linhas

Na consulta de producao em 2026-10-13, os produtos ativos estavam sem categoria
e sem metadados de linha. Por isso o seletor baseado somente nesses campos
nao oferecia FAROL, LANTERNA ou RETROVISOR.

A migration 106 cria uma classificacao de exibicao especifica da lista:

1. Categoria SAP preenchida.
2. Linha do catalogo complementar preenchida.
3. Tipo inicial da descricao normalizada, com aliases conservadores para
   abreviacoes como RAD., CX., RESERV., ACAB., TERM. e MOLD.
4. SEM LINHA para descricoes sem um tipo identificavel.

Essa alternativa nao reclassifica nem grava campos no cadastro. Nao substitui
o preenchimento futuro da coluna LINHA na origem SAP. Produtos inativos nao
participam das opcoes nem dos resultados. O filtro de linhas da tela Produtos
e o RPC get_product_filters nao foram alterados nesta etapa.

## Contratos E Seguranca

- RPC get_commercial_list_lines(): somente sessao interna ativa com ADMIN
  ou modulo produtos, mesma permissao da geracao de listas.
- Helper commercial_product_line: privado, sem execucao direta pelos clientes.
- generate_commercial_list mantem a assinatura e aceita filters.lines como array
  de strings, com ate 100 entradas de ate 120 caracteres. Remove repeticoes e
  valores vazios. filters.line antigo continua aceito nas chamadas paginadas.
- filtros sem offset e sem lines preservam o caminho legado da migration 105.
- Precos, estoque, impostos, snapshots e paginacao mantidos.
- Nenhum UPDATE de produtos, clientes, pedidos, cotacoes ou regras fiscais.

## Publicacao Controlada

Testar localmente e no clone antes de aplicar. Fazer novo backup, aplicar 106
primeiro em homologacao e publicar frontend somente depois do banco. Conferir
duas linhas, linha unica, lista geral, CSV/XLSX, inativos e permissao negada.
Producao exige aplicacao controlada separada e novo backup. Nao executar reset.
