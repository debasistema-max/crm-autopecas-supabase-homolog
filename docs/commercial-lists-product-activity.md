# Listas comerciais e atividade de produtos

## Uso

- Central de Importacoes > Listas comerciais: selecionar rota e linha; marca e
  grupo continuam opcionais. `Gerar lista` respeita os filtros.
- `Lista geral` limpa linha, marca e grupo, mantendo a rota selecionada.
- CSV/XLSX incluem a linha e todos os resultados; a tela mostra ate 500 itens.
- Produtos > ficha do item: somente ADMIN pode salvar `Ativo` ou `Inativo`.
- `Gerenciar inativos`, exclusivo de ADMIN, permite localizar e reativar itens.
  Fora dessa consulta administrativa, os inativos ficam ocultos.

## Contrato de banco

Migration nova: `105_product_activity_and_commercial_lists.sql`.

`products.ativo` e booleano, obrigatorio, com padrao `true`. Nao substitui
`status_cadastro` recebido do SAP. Os produtos existentes continuam ativos;
importacoes nao fornecem nem redefinem esse campo administrativo.

`set_product_active(product_code, is_active, expected_active)` exige ADMIN
interno e sessao ativa. O lock e a comparacao de estado evitam gravacao sobre
um estado diferente do apresentado. Trigger protege tambem alteracoes diretas
e registra usuario, horario, codigo e valores anterior/novo em `logs`.

A politica SELECT adicional e restritiva: nao amplia permissoes existentes nem
remove o controle de sessao. ADMIN pode ler inativos para gerenciamento, mas a
busca normal, listas comerciais, recentes e ranking mostram apenas ativos.
`include_inactive` na busca so funciona para ADMIN. O catalogo B2B tambem exclui
inativos, sem alterar suas permissoes de cliente.

Criacao de novos documentos verifica itens ativos no banco. Pedidos/cotacoes
ja existentes e seus snapshots permanecem armazenados e legiveis; nao ha
exclusao de produtos ou itens historicos.
Na edicao, um codigo inativo ja presente pode continuar no documento; novas
inclusoes de codigos inativos sao bloqueadas antes da reinsercao dos itens.
Conversoes novas tambem verificam atividade, sem bloquear a repeticao de uma
conversao ja realizada.

## Lista Completa e Consistente

`generate_commercial_list(route, filters)` continua retornando JSON com
`route`, `rows` e `count`; agora possui paginas de ate 500 itens (200 no cliente),
`has_more`, `next_offset` e `catalog_revision`. O cliente inclui a revisao da
primeira pagina em `expected_revision` nas seguintes.

Chamadas antigas sem `offset` mantem o contrato anterior, via helper privado
`generate_commercial_list_legacy_105`, agora excluindo inativos. Assim, uma
sessao aberta antes da atualizacao do frontend nao recebe apenas a primeira
pagina. As permissoes do wrapper continuam obrigatorias. O frontend novo sempre
envia `offset`, inclusive zero na primeira chamada.

O banco registra um marcador por transacao que altera catalogo, estoque,
precos, metadados ou regras fiscais. A contagem dos marcadores visiveis e a
data identificam a revisao. Nao ha um lock global de contador entre importacoes.
O instante de inicializacao do PostgreSQL integra a chave para evitar colisao
de IDs de transacao depois de restaurar um dump em outro servidor.

Se os dados mudarem entre paginas, a geracao falha e a exportacao fica
desabilitada. A lista nunca e entregue parcialmente. Os marcadores sao
internos, sem acesso por `anon`/`authenticated`, e nao devem ser apagados sem
planejar outra migration que preserve a revisao das exportacoes.

Na consulta padrao, so a pagina selecionada passa pelo calculo de preco. Os
filtros de API `only_valid_price`/`only_available` precisam calcular os elegiveis
para filtrar e sao limitados a 500 candidatos; acima disso e necessario reduzir
linha, marca ou grupo. A exportacao no navegador tem limite explicito de 50 mil
itens e nao corta silenciosamente os resultados.

## Aplicacao Controlada

1. Fazer backup do ambiente de destino e conferir migrations 001-104.
2. Revisar o diff e executar `npm test`.
3. Aplicar somente a migration 105 em homologacao, com `ON_ERROR_STOP`.
4. Se `CONTRATO_FUNCAO_105_DIVERGENTE` ocorrer, parar. A transacao desfaz todas
   as alteracoes. Comparar a definicao remota com os predecessores do Git;
   nunca remover o guard para forcar a aplicacao.
   O guard de `get_top_selling_products` aceita LF/CRLF apenas entre o JOIN
   revisado e o GROUP BY; alteracoes estruturais ou ocorrencias duplicadas
   continuam bloqueadas. A homologacao conserva CRLF nessa funcao historica.
5. Conferir coluna, triggers, politicas e grants das RPCs. Executar a regressao
   `supabase/tests/105_product_activity_and_commercial_lists_regression.sql`
   em banco descartavel; ela usa identidades ficticias e termina em ROLLBACK.
6. Publicar o frontend de homologacao somente depois do banco. Validar ADMIN
   e VENDEDOR, filtro de linha, lista geral, CSV/XLSX, inativar e reativar.
7. Aplicacao/publicacao em producao exige autorizacao especifica, novo backup
   e repeticao dessa ordem. Nao reutilizar credenciais/config de homologacao.

Antes da migration, o frontend novo nao deve ser publicado: a geracao depende
de `catalog_revision` e a edicao depende de `products.ativo`.

## Validacao Local

Os testes de contratos executam respostas de RPC simuladas e verificam
permissoes visuais, paginacao, resultados parciais, duplicatas, mudanca de revisao
e erros de concorrencia. As paginas de smoke usam apenas dados ficticios.

`tests/ui-operational-smoke.html?module=products` demonstra o cadastro; o usuario
ADMIN do mock pode inativar/reativar sem tocar no Supabase.
`tests/ui-operations-control-smoke.html?tab=lists` demonstra as listas.

A regressao SQL e os testes de concorrencia em clone sao complementares ao
browser: esconder controles nao substitui autorizacao no banco.
