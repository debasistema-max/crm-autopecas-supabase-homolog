# Segmentos Comerciais De Veiculos

## Pesquisa E Criterios

Fontes primarias consultadas em 2026-10-13:

- [Senatran, glossario da frota](https://www.gov.br/transportes/pt-br/assuntos/transito/arquivos-senatran/estatisticas/renavam/glossario-da-frota-de-veiculos-estatisticas-denatran/).
- [Toyota Hilux, picape](https://www.toyota.com.br/modelos/hilux-cabine-dupla).
- [Toyota Corolla](https://www.toyota.com.br/modelos/corolla).
- [Toyota Corolla Cross, SUV](https://pressroom.toyota.com/vehicle/2026-toyota-corolla-cross/).
- [Fiat utilitarios](https://www.fiat.com.br/carros.html?q=fiorino).
- [Nissan Versa, sedan](https://www.nissan.com.br/veiculos/modelos/versa/versoes.html).
- [Nissan Frontier, picape](https://www.nissan.com.br/veiculos/dst-home/frontier-my24.html).
- [Ford Pro, picapes, vans e SUV](https://www.fromtheroad.ford.com/br/pt/articles/2026/ford-pro-apresenta-veiculos-modificados-para-aplicacoes-especiai).
- [Mercedes-Benz caminhao Atego](https://www.mercedes-benz-trucks.com.br/caminhoes/atego).

O glossario oficial distingue tipos e pesos. O cadastro de pecas nao informa
PBT, CRLV ou versao de cada aplicacao. Portanto estes filtros sao segmentos
comerciais operacionais, nao classificacao legal/regulatoria.

- LEVE: automoveis reconhecidos, por exemplo Corolla, Versa, Corsa e Civic.
- UTILITARIO: picapes, vans e SUVs reconhecidos, incluindo Hilux, Ranger,
  Frontier, S-10, Fiorino, Transit e Corolla Cross. Variantes podem ter PBTs
  diferentes; nao se assume que todas estejam abaixo de 3500 kg.
- PESADO: modelos reconhecidos de caminhoes, como Atego/Actros, e aplicacoes
  explicitamente descritas como caminhao ou onibus. Nao se usa apenas marca.
- NAO_CLASSIFICADO: aplicacao vazia ou sem modelo conhecido no dicionario.

O reconhecimento e por palavras completas normalizadas; nao usa descricao
da peca, combustivel nem IA. Aplicacoes mistas podem retornar varios segmentos,
sem duplicar a peca. Corolla Cross nao conta como Corolla sedan. Aliases como
S-10/S10 e RAV 4/RAV4 sao tratados. A lista inicial nao e um registro completo
de todos os modelos existentes: novos modelos exigem revisao do dicionario.

## Implementacao

Migration 107 depende de 105 e 106. Helper product_vehicle_types e privado.
RPCs search_products_v2 e generate_commercial_list preservam assinatura,
permissoes, atividade do produto, motor de precos e paginacao. O filtro
vehicle_type e aplicado no banco antes do LIMIT; tipos invalidos sao recusados.
Produtos e lista usam a mesma prioridade de aplicacao: campo do produto,
depois aplicacao do catalogo complementar. Regras nao gravam classificacoes
nem alteram preco, estoque ou pedidos. A revisao de exportacao e invalidada
pela migration para nao misturar paginas calculadas por regras diferentes.

Produtos oferece o seletor e a ficha mostra o(s) segmento(s). Listas comerciais
combina tipo com linhas/rota/marca/grupo; lista geral limpa esses filtros.
CSV de produtos e CSV/XLSX comercial incluem o(s) segmento(s).

## Testes E Publicacao

Testar em clone: leves/utilitarios/pesados/nao classificados, aplicacao mista,
Corolla Cross repetido, marca isolada, aliases, inativos, filtros invalidos e
filtro antes do LIMIT. Repetir regressao 105 e 106. Testar desktop/mobile com
mocks e verificar CSV. Depois de novo backup, aplicar primeiro em homologacao
106 e 107, nessa ordem, e publicar assets com cache-bust. Producao exige
aprovacao e aplicacao controlada separada. Nao executar reset nem normalizar
o historico antigo de migrations nesta etapa.
