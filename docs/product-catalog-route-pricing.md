# Valores do catalogo por origem e destino

## Comportamento

- Filial de origem: SP ou PR; determina estoque e base comercial.
- Estado de destino: UF do cliente; determina rota fiscal. Padrao SP-SP.
- Pesquisa, lista geral, ficha e XLSX usam o mesmo contexto capturado.
- Base sem impostos, impostos e final com impostos aparecem separadamente.
- Final indisponivel e exportado em branco com status fiscal; nao vira zero.
- Imposto zero validado pelo motor continua sendo zero.
- Nao usa preco de outra filial nem preco antigo como substituto do final.

## Backend e compatibilidade

Migration113 cria `search_product_catalog_pricing(jsonb)`; consulta a pagina de
`search_products_v2` e delega precos a `get_product_commercial_price`, com data
comercial do servidor e perfil REVENDA. Nao adiciona aliquotas, formulas, regras
ou rotas aprovadas. Exibir uma UF nao garante que a configuracao fiscal exista.

Busca antiga e seletores de pedidos/cotacoes continuam na RPC anterior. A nova
RPC exige sessao interna atual e modulo produtos ou ADMIN. Nao concede acesso a
anon, service_role ou executor instalado. Mantem limite/paginacao/filtros e
exclusoes da busca existente. Uma requisicao por pagina, sem chamadas por item
no navegador e sem cache de precos.

## Validacao e publicacao

Branch `codex/product-list-state-pricing`, PR30 de homologacao. A migration113
foi aplicada somente em homologacao em22/10/2026, apos backup verificado.
Frontend segue publicacao controlada pela PR. Producao nao foi alterada.

1. Confirmar nomenclatura e separacao de origem/destino com o usuario.
2. Fazer backup do ambiente antes de aplicar113, cujo predecessor e112.
3. Aplicar113 e rodar `113_product_catalog_route_pricing_regression.sql` com
   rollback. O ensaio local ja conferiu oito rotas no banco de homologacao.
4. Publicar app.html, products.js, supabase_store.js, app.css e seller.css juntos.
5. Conferir SP-SP, PR-PR, PR-SC e PR-RJ, mudanca de UF, paginas e XLSX completo.
6. Conferir impostos zero, regra ausente, referencia divergente e sessao invalida.
7. Comparar os valores com as listas comerciais da mesma rota e data.

Para rollback, republicar primeiro o frontend anterior. A reversao SQL remove
somente a nova RPC; nao remove produtos, regras fiscais ou historico.
O smoke HTML usa valores ficticios, nao percentuais tributarios reais.

## Evidencias locais de 22/10/2026

- 145 testes: 88 estaticos, 16 de sessao e 41 Python.
- Ensaio SQL com rollback: SP/PR como origem e SP/PR/SC/RJ como destino,
  comparacao com o motor existente, origem/destino invalidos e sessao ausente.
- Pagina de500 itens: aproximadamente3,34s em SP-SP e2,22s em PR-PR neste
  ensaio, incluindo comunicacao com o banco. Nao e garantia de latencia futura.
- ADMIN e VENDEDOR inspecionados em desktop e375px, sem overflow horizontal.
- Previa visual exclusivamente com dados ficticios; nenhuma importacao real.
- Migration113 aplicada apos ensaios. Produtos, estoques, precos, regras,
  usuarios, logs e documentos permaneceram iguais na comparacao pre/pos.
- Revisao independente encontrou corrida ao reabrir o mesmo codigo em outra
  rota. Corrigida com sequencia da requisicao, identidade do DOM e contexto da
  rota; fechamento invalida respostas. Testes cobrem busca, erro e historico
  atrasados, inclusive depois de reabrir o mesmo produto.
