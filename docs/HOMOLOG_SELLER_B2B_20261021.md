# Homologacao: vendedor inspirado no B2B

Data: 2026-10-21
Base: homolog/main em 9f9cab1
Branch: codex/seller-b2b-homolog
Destino exclusivo: debasistema-max/crm-autopecas-supabase-homolog

## Escopo

- Navegacao horizontal para VENDEDOR em celular, tablet e desktop.
- Identidade da empresa no cabecalho, preservando o logout atual.
- Produtos apresentados em linhas, com foto, descricao, estoque, preco e ficha.
- Filial SP e Matriz PR mantem os valores SP/PR das consultas existentes.
- Linha, montadora, tipo de veiculo, OEM, foto e favoritos em "Mais filtros".
- Consultas recentes e mais vendidos recolhiveis, abaixo dos resultados.
- Atalhos para os formularios existentes de pedido/cotacao, conforme permissoes.
- Formularios comerciais continuam no modo focado, sem menu durante a criacao.
- ADMIN e B2B nao recebem o novo layout.

Nenhuma migration, alteracao de RLS, autenticacao, carteira, preco ou estoque.
Nenhum dado de teste foi gravado. Nao foi criado um segundo carrinho ou copiada
a autenticacao do B2B; os formularios comerciais atuais foram preservados.

## Correcao associada

Ao trocar SP/PR depois de gerar a lista geral, a tela podia manter os resultados
da filial anterior quando o campo de busca estava vazio. Agora a troca refaz a
consulta e apresenta o estado de carregamento, sem manter o preco anterior.
O estoque numerico zero permanece visivel, sem virar "nao informado".

## Validacao local

Testes com renderizadores reais e respostas ficticias, sem conexao ao banco:

- Catalogo: 320, 390, 768, 1024 e 1440 pixels; sem overflow horizontal.
- Inicio, relatorio e formulario de pedido: 320 pixels; sem overflow.
- Pesquisa/lista geral, filtros recolhiveis e filtro por linha funcionando.
- Filial PR retorna os precos PR da fixture; SP permanece a consulta inicial.
- Ficha abre via teclado e fecha sem deslocar o catalogo.
- Nova cotacao e Novo pedido abrem os formularios atuais.
- Voltar restaura a lista e a navegacao horizontal.
- Criacao oculta a navegacao; o retorno a reexibe.
- Vendedor com novo_pedido/pedidos/nova_cotacao/cotacoes isolados: navegacao
  e botoes correspondentes; consulta e criacao continuam independentes.
- ADMIN: menu lateral mantido, navegacao de vendedor oculta e gestao de
  produtos inativos preservada.
- Console sem erros JavaScript nos fluxos locais verificados.

Suite automatizada: npm test (usar o Python instalado no PATH da sessao).
Resultado: 109 testes aprovados (59 de UI/contratos, 16 de sessao, 34 Python).
Inclui sintaxe JS, sequencia de migrations somente leitura, contratos de UI,
testes especificos do layout, sessao unica e adaptadores Python.

## Teste conectado apos publicacao

1. Abrir https://debasistema-max.github.io/crm-autopecas-supabase-homolog/.
2. Entrar com uma conta VENDEDOR de homologacao.
3. Conferir Inicio/Produtos/Clientes/Cotacoes/Pedidos conforme permissoes.
4. Pesquisar um item real e conferir SP/PR, foto e ficha.
5. Conferir Mais filtros, inclusive linha e tipo de veiculo.
6. Abrir pedido e cotacao e voltar para os respectivos relatorios.
7. Testar em celular e desktop; conferir conta ADMIN sem mudanca de layout.

Os testes locais nao substituem a validacao autenticada pelo vendedor com sua
carteira real em homologacao. Nenhuma credencial de producao deve ser utilizada.

## Publicacao e reversao

Publicar por PR para main SOMENTE no repositorio de homologacao, apos regressao.
O workflow static.yml publica assets/b2b/cadastro-publico/css/js e as paginas raiz.
Os arquivos de teste e esta documentacao nao fazem parte do artifact do Pages.

Reversao: reverter o commit do PR em homologacao e executar novamente o workflow
de Pages. Nao ha operacao de banco para reverter. Nao usar force push.
