# Enriquecimento pelo catalogo IPS instalado

## Escopo e origem

Ambiente autorizado nesta entrega: homologacao, projeto mtwvxyvpnbgwgltelozw.
Nao aplicar em producao sem autorizacao especifica e uma nova previa/backup.

Origem lida em modo somente leitura:

- Aplicativo catalogo_ips, versao 1.5.20.
- `_up_/data/catalog.db` e `_up_/manifest.json` na instalacao local.
- 2.262 produtos; manifesto com 2.657 arquivos de imagem.
- URLs de imagem somente da origem R2 explicitamente indicada no manifesto.
- Nenhum executavel do catalogo foi iniciado ou modificado.

## Regras de mapeamento

- Corresponder SOMENTE por codigo exato, preservando zeros a esquerda.
- Codigos ausentes no CRM ficam no relatorio, sem criar produtos sem preco/SAP.
- Duplicidades, fonte de imagem diferente e banco local sem integridade bloqueiam a previa.
- Nunca alterar descricao SAP, ano, grupo SAP, ativo/inativo, fiscal, preco ou estoque.
- Foto, marca, aplicacao, linha/categoria, montadora, OEM e similares preenchem
  somente campos vazios. As linhas/aplicacoes efetivas do catalogo oficial
  existente tambem sao consideradas preenchidas e preservadas.
- `pgroup` do catalogo instalado representa familia/linha: nao copiar para o
  grupo SAP do CRM. Quando ha linha oficial existente, nao a substituir.
- Manter o texto manual de detalhes e acrescentar um unico bloco identificado
  como `CATALOGO_IPS_INSTALADO`. Uma nova previa substitui somente esse bloco.
- Descricao, marca, OEM, similares, EAN, dimensoes e aplicacoes/anos completos da
  fonte ficam nesse bloco, inclusive quando diferem dos campos principais.
- Nao interpretar dimensoes sem unidade explicita nem converter anos do catalogo
  para o campo `ano` mantido pela sincronizacao SAP.
- A ficha apresenta esse bloco em "Informacoes do catalogo IPS", recolhivel e
  com HTML escapado. As observacoes manuais continuam em "Detalhes consulta".

## Previa sem escrita

O operador deve exportar um snapshot autorizado de `products` com codigo,
campos tecnicos e os fallbacks `product_catalog_metadata.line_name` /
`applications`, sem dados de clientes ou credenciais. O script gera apenas JSON:

```powershell
python scripts/build_installed_ips_catalog.py `
  --database "C:\Users\deivi\AppData\Local\catalogo_ips\_up_\data\catalog.db" `
  --manifest "C:\Users\deivi\AppData\Local\catalogo_ips\_up_\manifest.json" `
  --crm-snapshot "C:\caminho-privado\snapshot.json" `
  --output "C:\caminho-privado\plano-novo.json"
```

Cada imagem candidata e verificada por HEAD: HTTP 200, tipo image/* e tamanho
positivo. Redirecionamentos nao sao seguidos. Nao adivinhar imagens pelo nome
do arquivo ou relacionar produtos por descricao aproximada.

`--verified-plan` permite reutilizar verificacoes por ate uma hora somente se
o hash da origem inteira, URLs e totais continuam identicos. O arquivo de saida
e criado de forma exclusiva para nao sobrescrever evidencia anterior.

## Aplicacao controlada

A aplicacao administrativa nao roda no navegador e nao faz parte do frontend.
Os auxiliares operacionais locais ficam fora do Git, em `.security-backups/`:

1. Validar alvo homologacao e TLS com certificado CA oficial, sem desativar verificacao.
2. Fazer backup pg_dump 17 das tabelas afetadas e conferir tamanho, SHA-256 e TOC.
3. Revisar totais e cada campo do JSON; guardar tambem as imagens/codigos ignorados.
4. Usar transacao unica e stage temporario com chave primaria por codigo.
5. Bloquear as linhas e comparar os valores anteriores com a previa; qualquer
   divergencia interrompe o lote inteiro.
6. Atualizar exclusivamente os oito campos permitidos pelo plano, sem tocar nos
   campos comerciais, sincronizacao ou timestamps de origem SAP.
7. Comparar hashes protegidos de produtos, precos, estoque, pedidos, cotacoes e
   metadados oficiais antes/depois; diferenca inesperada causa rollback.
8. Registrar lote `IPS_INSTALLED_CATALOG` em `catalog_metadata_sync_batches`,
   auditoria por codigo em `product_catalog_metadata_audit` e acao em `logs`.
   As entradas de auditoria indicam `target_table: products`, campos anteriores
   e novos. Os snapshots oficiais de `product_catalog_metadata` nao mudam.
9. Somente depois confirmar o COMMIT. Repeticao identica e idempotente; se os
   campos mudaram depois de uma aplicacao anterior, interromper para revisao.

Esta entrega nao cria migrations, tabelas, policies ou RPCs. Nao usar db reset,
nao excluir produtos e nao executar os auxiliares com credenciais de producao.

## Previa e testes desta entrega

- Correspondencias: 2.254; codigos ausentes: 8.
- Fotos novas validadas: 2.162 produtos; 14 URLs indisponiveis na origem.
- Linha: 555 lacunas; similares: 2.189; OEM: 372; aplicacao: 6; montadora: 2.
- Detalhes completos: 2.254, preservando o texto manual.
- Teste em homologacao com o lote inteiro e rollback obrigatorio: aprovado.
- Verificacao posterior de todos os valores anteriores: aprovada.
- UI local: foto ampliavel e informacoes recolhiveis em desktop e celular.
- Testes automatizados: sintaxe, contratos, sessao unica e leitura/mapeamento
  SQLite. O catalogo instalado e os dados reais nao fazem parte do repositorio.

As URLs externas podem ficar indisponiveis no futuro. Preservar o fallback da
foto oficial existente e nao substituir ausencia de imagem por foto de outro item.
Filtros estaticos do navegador mantem o TTL existente de dez minutos.
